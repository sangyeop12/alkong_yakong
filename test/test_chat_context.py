import json
import os
import sqlite3
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.models.schemas import DrugExplainChatRequest
from app.routes.drug_explain import router as drug_explain_router
from app.services import chat_context_service, gemini_service
from app.services.mfds_drug_permission import client as permission_client
from app.services.mfds_drug_permission import db as permission_db
from app.services.chat_context_service import (
    AMBIGUOUS_QUESTION_REPLY,
    MEDICINE_SELECTION_REQUIRED_REPLY,
    UNRELATED_QUESTION_REPLY,
    build_grounded_chat_prompt,
    classify_question,
    classify_question_scope,
    general_conversation_reply,
    is_safety_question,
    load_latest_dur_context,
    resolve_question_intents,
    select_official_context,
)


def _database(*, current, analyzed=None, matches=None, include_result=True):
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript(
        """
        CREATE TABLE medicines (medicine_code TEXT PRIMARY KEY, ingredient TEXT);
        CREATE TABLE user_medicines (id INTEGER PRIMARY KEY, user_id TEXT, medicine_code TEXT, is_active INTEGER);
        CREATE TABLE risk_results (id INTEGER PRIMARY KEY, user_id TEXT, analyzed_ingredients TEXT, matches_json TEXT, created_at TEXT);
        CREATE TABLE dur_taboo (id INTEGER PRIMARY KEY, external_id TEXT, min_age INTEGER, max_age INTEGER, pregnancy_grade TEXT, notification_date TEXT, raw_json TEXT, updated_at TEXT);
        """
    )
    for index, ingredient in enumerate(current, 1):
        code = f"M{index}"
        conn.execute("INSERT INTO medicines VALUES (?, ?)", (code, ingredient))
        conn.execute("INSERT INTO user_medicines VALUES (?, 'U1', ?, 1)", (index, code))
    if include_result:
        conn.execute(
            "INSERT INTO risk_results VALUES (1, 'U1', ?, ?, '2026-01-01')",
            (
                json.dumps(analyzed if analyzed is not None else current, ensure_ascii=False),
                json.dumps(matches or [], ensure_ascii=False),
            ),
        )
    conn.commit()
    return conn


def _chat_response(text, *, finish_reason="STOP", candidates=True):
    candidate_list = []
    if candidates:
        candidate_list = [
            SimpleNamespace(
                finish_reason=finish_reason,
                content=SimpleNamespace(parts=[SimpleNamespace(text=text)]),
            )
        ]
    return SimpleNamespace(
        text=text,
        candidates=candidate_list,
        usage_metadata=None,
    )


class ChatContextTest(unittest.TestCase):
    def test_unselected_question_scope_distinguishes_general_specific_and_unrelated(self):
        self.assertEqual(
            classify_question_scope("약 복용을 깜빡하면 어떻게 하나요?"),
            "general_medication",
        )
        self.assertEqual(
            classify_question_scope("비 오는 날 약 보관은 어떻게 하나요?"),
            "general_medication",
        )
        self.assertEqual(classify_question_scope("부작용은 무엇인가요?"), "needs_medicine")
        self.assertEqual(
            classify_question_scope("아스피린 부작용은 무엇인가요?"),
            "medicine_specific",
        )
        self.assertEqual(classify_question_scope("오늘 날씨 어때?"), "unrelated")
        self.assertEqual(classify_question_scope("오늘 뭐하지?"), "ambiguous")
        self.assertEqual(
            classify_question_scope("환인아캄프로세이트정"),
            "medicine_specific",
        )
        self.assertEqual(
            classify_question_scope("환인아캄프로세이트정과 커피를 같이 마셔도 괜찮아?"),
            "medicine_specific",
        )
        self.assertEqual(
            classify_question_scope("약 먹고 커피랑 마셔도 괜찮아?"),
            "general_medication",
        )
        self.assertIn(
            "precautions",
            classify_question("환인아캄프로세이트정과 커피를 같이 마셔도 괜찮아?"),
        )

    def test_unselected_coffee_questions_give_general_guidance_before_requesting_name(self):
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        reply = (
            "커피는 약에 따라 효과나 부작용에 영향을 줄 수 있어요. "
            "정확한 확인을 위해 드시는 약 이름을 알려주세요."
        )
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch.object(
                gemini_service,
                "_generate_complete_chat_reply",
                return_value=reply,
            ) as generate,
            patch(
                "app.services.external_api_service.search_drug_info_by_name"
            ) as official_search,
        ):
            for question in (
                "커피랑 약이랑 같이 먹어도 괜찮아?",
                "약 먹고 커피랑 마셔도 괜찮아?",
            ):
                with self.subTest(question=question):
                    self.assertEqual(
                        gemini_service.generate_chat_response(
                            question,
                            user_id="synthetic-user",
                        ),
                        reply,
                    )

        self.assertEqual(generate.call_count, 2)
        for call in generate.call_args_list:
            prompt = call.kwargs["prompt"]
            self.assertIn("짧은 일반 안내를 먼저 제공", prompt)
            self.assertIn("답변 전체를 약 이름 요청 한 문장만으로 대체하지 마세요", prompt)
        official_search.assert_not_called()

    def test_named_coffee_question_uses_exact_official_product_context(self):
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=SimpleNamespace(
                    parsed={"drug_names": ["환인아캄프로세이트정"]}
                ),
            ),
            patch(
                "app.services.external_api_service.search_drug_info_by_name",
                return_value={
                    "match_type": "exact",
                    "items": [
                        {
                            "medicine_code": "101",
                            "product_name": "환인아캄프로세이트정",
                            "cautions": "공식 주의사항",
                            "source": "식약처",
                        }
                    ],
                },
            ) as official_search,
            patch.object(
                gemini_service,
                "_generate_complete_chat_reply",
                return_value="공식 주의사항을 기준으로 확인한 답변이에요.",
            ) as generate,
        ):
            reply = gemini_service.generate_chat_response(
                "환인아캄프로세이트정과 커피를 마셔도 돼?",
                user_id="synthetic-user",
            )

        self.assertIn("공식 주의사항", reply)
        official_search.assert_called_once_with("환인아캄프로세이트정")
        grounded_prompt = generate.call_args.kwargs["prompt"]
        self.assertIn("환인아캄프로세이트정", grounded_prompt)
        self.assertIn("공식 주의사항", grounded_prompt)

    def test_named_coffee_question_distinguishes_not_found_from_lookup_failure(self):
        extracted = SimpleNamespace(parsed={"drug_names": ["없는제품정"]})
        for search_result, expected in (
            ({"match_type": "none", "items": []}, "제품명을 식약처 공식정보에서 확인하지 못했어요"),
            (RuntimeError("lookup failed"), "공식정보를 조회하는 중 문제가 생겼어요"),
        ):
            with (
                self.subTest(expected=expected),
                patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
                patch("google.genai.Client"),
                patch.object(
                    gemini_service,
                    "_generate_content_with_retry",
                    return_value=extracted,
                ),
                patch(
                    "app.services.external_api_service.search_drug_info_by_name",
                    side_effect=(
                        search_result
                        if isinstance(search_result, Exception)
                        else None
                    ),
                    return_value=(
                        None if isinstance(search_result, Exception) else search_result
                    ),
                ),
            ):
                reply = gemini_service.generate_chat_response(
                    "없는제품정과 커피를 마셔도 돼?",
                    user_id="synthetic-user",
                )
            self.assertIn(expected, reply)
            self.assertNotIn("안전", reply)

    def test_named_coffee_question_does_not_hide_partial_lookup_failure_as_not_found(self):
        extracted = SimpleNamespace(
            parsed={"drug_names": ["없는제품정", "조회오류정"]}
        )

        def search(name):
            if name == "조회오류정":
                raise RuntimeError("lookup failed")
            return {"match_type": "none", "items": []}

        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client"),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=extracted,
            ),
            patch(
                "app.services.external_api_service.search_drug_info_by_name",
                side_effect=search,
            ),
        ):
            reply = gemini_service.generate_chat_response(
                "없는제품정과 조회오류정을 커피와 마셔도 돼?",
                user_id="synthetic-user",
            )

        self.assertIn("공식정보를 조회하는 중 문제가 생겼어요", reply)
        self.assertNotIn("제품명을 식약처 공식정보에서 확인하지 못했어요", reply)
        self.assertNotIn("안전", reply)

    def test_two_exact_free_text_medicines_are_the_explicit_dur_scope(self):
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        extracted = _chat_response(
            '{"drug_names":["환인아캄프로세이트정","유한메토트렉세이트정"]}'
        )

        def official_result(name):
            code = "101" if name.startswith("환인") else "202"
            return {
                "match_type": "exact",
                "items": [
                    {
                        "medicine_code": code,
                        "product_name": name,
                        "ingredient": f"성분-{code}",
                    }
                ],
            }

        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=extracted,
            ),
            patch(
                "app.services.external_api_service.search_drug_info_by_name",
                side_effect=official_result,
            ),
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": [],
                    "has_risk": False,
                    "reason": None,
                    "checked_types": ["병용금기", "중복성분", "효능군중복"],
                    "zero_result_types": ["병용금기", "중복성분", "효능군중복"],
                },
            ) as remote_dur,
        ):
            reply = gemini_service.generate_chat_response(
                "환인아캄프로세이트정과 유한메토트렉세이트정을 같이 먹어도 괜찮아?",
                user_id="synthetic-user",
            )

        self.assertIn("함께 먹으면 안 되는 조합은 확인되지 않았어요", reply)
        self.assertIsNone(remote_dur.call_args.kwargs["selected_medicine"])
        self.assertFalse(remote_dur.call_args.kwargs["include_current_medicines"])
        self.assertEqual(
            remote_dur.call_args.kwargs["additional_medicines"],
            [
                {"medicine_code": "101", "product_name": "환인아캄프로세이트정"},
                {"medicine_code": "202", "product_name": "유한메토트렉세이트정"},
            ],
        )

    def test_unselected_non_medicine_and_missing_medicine_return_before_lookup(self):
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch(
                "app.services.external_api_service.search_drug_info_by_name"
            ) as official_search,
            patch(
                "app.services.medication_feature_dur_client.load_remote_current_medicines"
            ) as current_medicines,
        ):
            weather = gemini_service.generate_chat_response(
                "오늘 날씨 어때?", user_id="synthetic-user"
            )
            missing = gemini_service.generate_chat_response(
                "부작용은 무엇인가요?", user_id="synthetic-user"
            )
            ambiguous = gemini_service.generate_chat_response(
                "오늘 뭐하지?", user_id="synthetic-user"
            )

        self.assertEqual(weather, UNRELATED_QUESTION_REPLY)
        self.assertEqual(missing, MEDICINE_SELECTION_REQUIRED_REPLY)
        self.assertEqual(ambiguous, AMBIGUOUS_QUESTION_REPLY)
        official_search.assert_not_called()
        current_medicines.assert_not_called()

    def test_unselected_general_medicine_question_uses_short_general_prompt_only(self):
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        short_reply = (
            "약 복용을 잊었다면 임의로 두 배를 먹지 마세요. "
            "약마다 대처가 다르므로 약 이름을 알려주거나 약사에게 확인하세요."
        )
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch.object(
                gemini_service,
                "_generate_complete_chat_reply",
                return_value=short_reply,
            ) as generate,
            patch(
                "app.services.external_api_service.search_drug_info_by_name"
            ) as official_search,
            patch(
                "app.services.medication_feature_dur_client.load_remote_current_medicines"
            ) as current_medicines,
        ):
            reply = gemini_service.generate_chat_response(
                "약 복용을 깜빡하면 어떻게 하나요?",
                user_id="synthetic-user",
            )

        self.assertEqual(reply, short_reply)
        prompt = generate.call_args.kwargs["prompt"]
        self.assertIn("보통 2~3문장", prompt)
        self.assertIn("개인 복용량", prompt)
        official_search.assert_not_called()
        current_medicines.assert_not_called()

    def test_explicit_single_question_without_identity_is_not_treated_as_all_medicines(self):
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", None),
            patch(
                "app.services.medication_feature_dur_client.load_remote_current_medicines"
            ) as current_medicines,
        ):
            reply = gemini_service.generate_chat_response(
                "이 약은 어디에 쓰는 약인가요?",
                user_id="synthetic-user",
                intent="efficacy",
            )

        self.assertIn("식약처 공식정보", reply)
        current_medicines.assert_not_called()

    def test_chat_request_contract_accepts_overview_and_existing_intents(self):
        existing = (
            "efficacy",
            "dosage",
            "precautions",
            "side_effects",
            "combination",
            "age",
            "pregnancy",
            "duplicate",
        )
        for intent in ("overview", *existing):
            with self.subTest(intent=intent):
                request = DrugExplainChatRequest(
                    user_id="synthetic-user",
                    message="합성 질문",
                    selected_medicine={
                        "medicine_code": "202400001",
                        "product_name": "공식허가약정",
                    },
                    intent=intent,
                )
                self.assertEqual(request.intent, intent)
                self.assertEqual(request.user_id, "synthetic-user")
                self.assertEqual(request.message, "합성 질문")
                self.assertEqual(request.selected_medicine.medicine_code, "202400001")
                self.assertEqual(request.selected_medicine.product_name, "공식허가약정")

        with self.assertRaises(ValidationError):
            DrugExplainChatRequest(
                user_id="synthetic-user",
                message="합성 질문",
                intent="unknown-intent",
            )

        legacy = DrugExplainChatRequest(
            user_id="legacy-user",
            message="기존 앱 질문",
        )
        self.assertIsNone(legacy.selected_medicine)
        self.assertEqual(legacy.selected_medicines, [])
        self.assertEqual(legacy.temporary_medicines, [])
        self.assertIsNone(legacy.intent)
        self.assertEqual(
            set(DrugExplainChatRequest.model_fields),
            {
                "user_id",
                "message",
                "selected_medicine",
                "selected_medicines",
                "temporary_medicines",
                "intent",
            },
        )

    def test_chat_endpoint_accepts_overview_and_rejects_unknown_intent(self):
        app = FastAPI()
        app.include_router(drug_explain_router)
        client = TestClient(app)
        payload = {
            "user_id": "synthetic-user",
            "message": "이 약은 무슨 약이에요?",
            "selected_medicine": {
                "medicine_code": "202400001",
                "product_name": "공식허가약정",
            },
            "selected_medicines": [
                {
                    "medicine_code": "202400001",
                    "product_name": "공식허가약정",
                },
                {
                    "medicine_code": "202400002",
                    "product_name": "화면선택약정",
                },
            ],
            "temporary_medicines": [
                {
                    "medicine_code": "202400002",
                    "product_name": "화면임시약정",
                }
            ],
            "intent": "overview",
        }
        with patch.object(
            gemini_service,
            "generate_chat_response",
            return_value="공식정보에 근거한 개요예요.",
        ) as generate:
            response = client.post("/api/v1/drug-explain/chat", json=payload)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"reply": "공식정보에 근거한 개요예요."})
        self.assertEqual(
            generate.call_args.kwargs["selected_medicines"],
            [
                {"medicine_code": "202400001", "product_name": "공식허가약정"},
                {"medicine_code": "202400002", "product_name": "화면선택약정"},
            ],
        )
        self.assertEqual(
            generate.call_args.kwargs["temporary_medicines"],
            [{"medicine_code": "202400002", "product_name": "화면임시약정"}],
        )

        payload["intent"] = "unknown-intent"
        response = client.post("/api/v1/drug-explain/chat", json=payload)
        self.assertEqual(response.status_code, 422)

    def test_overview_and_efficacy_keep_distinct_official_contexts(self):
        official = {
            "medicine_code": "1",
            "product_name": "공식약정",
            "ingredient": "공식성분",
            "manufacturer": "공식제조사",
            "efficacy": "공식 사용 목적",
            "cautions": "공식 핵심 주의",
        }
        overview = select_official_context(official, {"overview"})
        efficacy = select_official_context(official, {"efficacy"})
        self.assertEqual(resolve_question_intents("무슨 약이에요?", "overview"), {"overview"})
        self.assertEqual(resolve_question_intents("어디에 쓰나요?", "efficacy"), {"efficacy"})
        self.assertIn("manufacturer", overview)
        self.assertIn("cautions", overview)
        self.assertNotIn("manufacturer", efficacy)
        self.assertNotIn("cautions", efficacy)

    def _run_permission_general(
        self,
        *,
        intent,
        permission_fields,
        e_drug_result=None,
        e_drug_error=None,
        permission_verified=True,
    ):
        selected = {"medicine_code": "202400001", "product_name": "공식허가약정"}
        permission = {
            **selected,
            "source": "식약처 의약품 제품 허가정보",
            "_permission_identity_verified": permission_verified,
            **permission_fields,
        }
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        fetch_effect = e_drug_error if e_drug_error is not None else None
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch(
                "app.services.external_api_service.fetch_e_drug_info",
                return_value=e_drug_result,
                side_effect=fetch_effect,
            ),
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                return_value=permission,
            ) as enrich,
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=[
                    SimpleNamespace(parsed={"drug_names": []}),
                    SimpleNamespace(text="공식 허가정보만 근거로 작성한 충분한 설명입니다."),
                ],
            ) as generate,
        ):
            reply = gemini_service.generate_chat_response(
                "빠른 질문", user_id="U1", selected_medicine=selected, intent=intent
            )
        return reply, enrich, generate

    def _run_permission_only_safety(self, *, intent, e_drug_result=None, e_drug_error=None):
        selected = {
            "medicine_code": "202400001",
            "product_name": "공식허가약정",
        }
        permission_detail = {
            "ITEM_SEQ": "202400001",
            "ITEM_NAME": "공식허가약정",
            "MAIN_ITEM_INGR": "공식성분 100mg",
        }
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        fetch_effect = e_drug_error if e_drug_error is not None else None
        type_by_intent = {
            "combination": ["병용금기", "중복성분", "효능군중복"],
            "duplicate": ["중복성분", "효능군중복"],
            "age": ["연령금기"],
            "pregnancy": ["임부금기"],
        }
        checked_types = type_by_intent[intent]
        completed_zero = {
            "status": "current",
            "items": [],
            "checked_types": checked_types,
            "zero_result_types": checked_types,
            "user_context": {
                "age_known": intent == "age",
                "pregnancy_known": intent == "pregnancy",
                "pregnancy_status": (
                    "pregnant" if intent == "pregnancy" else "unknown"
                ),
            },
        }
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=SimpleNamespace(parsed={"drug_names": []}),
            ),
            patch(
                "app.services.external_api_service.fetch_e_drug_info",
                return_value=e_drug_result,
                side_effect=fetch_effect,
            ),
            patch(
                "app.services.mfds_drug_permission.db.find_permission_product_by_item_seq",
                return_value=None,
            ),
            patch(
                "app.services.mfds_drug_permission.client.fetch_permission_detail",
                return_value=permission_detail,
            ),
            patch(
                "app.services.dur_service.analyze_dur_consultation",
                return_value=completed_zero,
            ) as analyze,
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": [],
                    "has_risk": False,
                    "reason": None,
                    "checked_types": ["병용금기", "중복성분", "효능군중복"],
                    "zero_result_types": ["병용금기", "중복성분", "효능군중복"],
                },
            ) as remote,
        ):
            reply = gemini_service.generate_chat_response(
                "빠른 질문",
                user_id="U1",
                selected_medicine=selected,
                intent=intent,
            )
        return reply, remote if intent == "combination" else analyze

    def test_permission_db_item_seq_lookup_is_exact(self):
        handle = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        db_path = handle.name
        handle.close()
        try:
            with patch.object(permission_db, "DB_PATH", db_path):
                permission_db.initialize_permission_db()
                conn = permission_db.get_permission_connection()
                try:
                    conn.execute(
                        """
                        INSERT INTO products (
                            item_seq, item_name, name_compact,
                            main_item_ingr, item_ingr_name
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                        (
                            "198700430",
                            "알마겔정(알마게이트)(수출명:유한가스트라겔정)",
                            "알마겔정(알마게이트)(수출명:유한가스트라겔정)",
                            "알마게이트 500mg",
                            "알마게이트",
                        ),
                    )
                    conn.commit()
                finally:
                    conn.close()

                row = permission_db.find_permission_product_by_item_seq(
                    "198700430"
                )
                missing = permission_db.find_permission_product_by_item_seq(
                    "198700431"
                )

            self.assertEqual(row["main_item_ingr"], "알마게이트 500mg")
            self.assertIsNone(missing)
        finally:
            os.unlink(db_path)

    def test_permission_detail_filters_name_results_by_exact_item_seq(self):
        response = MagicMock()
        response.json.return_value = {
            "body": {
                "items": [
                    {"ITEM_SEQ": "OTHER", "ITEM_NAME": "동명이품목"},
                    {"ITEM_SEQ": "198700430", "ITEM_NAME": "알마겔정"},
                ]
            }
        }
        with (
            patch.object(permission_client, "MFDS_DRUG_PERMISSION_API_KEY", "key"),
            patch.object(permission_client.requests, "get", return_value=response) as get,
        ):
            item = permission_client.fetch_permission_detail(
                "알마겔정",
                item_seq="198700430",
            )

        response.raise_for_status.assert_called_once_with()
        self.assertEqual(item["ITEM_SEQ"], "198700430")
        params = get.call_args.kwargs["params"]
        self.assertEqual(params["item_name"], "알마겔정")
        self.assertNotIn("item_seq", params)
        self.assertEqual(params["numOfRows"], 100)

    def test_selected_medicine_ingredient_uses_exact_permission_item_seq(self):
        official = {
            "medicine_code": "198700430",
            "product_name": "알마겔정(알마게이트)(수출명:유한가스트라겔정)",
            "ingredient": None,
            "efficacy": "공식 효능",
            "source": "e약은요",
        }
        permission_row = {
            "item_seq": "198700430",
            "item_name": "알마겔정(알마게이트)(수출명:유한가스트라겔정)",
            "main_item_ingr": "알마게이트 500mg",
            "item_ingr_name": "알마게이트",
        }
        with (
            patch(
                "app.services.mfds_drug_permission.db.find_permission_product_by_item_seq",
                return_value=permission_row,
            ) as find_by_seq,
            patch(
                "app.services.mfds_drug_permission.client.fetch_permission_detail"
            ) as fetch_detail,
        ):
            enriched = gemini_service._with_official_permission_ingredient(official)

        find_by_seq.assert_called_once_with("198700430")
        fetch_detail.assert_not_called()
        self.assertEqual(enriched["ingredient"], "알마게이트 500mg")
        self.assertEqual(enriched["efficacy"], "공식 효능")
        self.assertEqual(enriched["source"], "e약은요")

    def test_permission_api_fallback_requires_exact_code_and_name(self):
        official = {
            "medicine_code": "198700430",
            "product_name": "알마겔정(알마게이트)(수출명:유한가스트라겔정)",
            "ingredient": None,
        }
        api_detail = {
            "ITEM_SEQ": "198700430",
            "ITEM_NAME": "알마겔정(알마게이트)(수출명:유한가스트라겔정)",
            "MAIN_ITEM_INGR": "알마게이트 500mg",
            "ITEM_INGR_NAME": "알마게이트",
        }
        with (
            patch(
                "app.services.mfds_drug_permission.db.find_permission_product_by_item_seq",
                return_value=None,
            ),
            patch(
                "app.services.mfds_drug_permission.client.fetch_permission_detail",
                return_value=api_detail,
            ) as fetch_detail,
        ):
            enriched = gemini_service._with_official_permission_ingredient(official)

        fetch_detail.assert_called_once_with(
            "알마겔정(알마게이트)(수출명:유한가스트라겔정)",
            item_seq="198700430",
        )
        self.assertEqual(enriched["ingredient"], "알마게이트 500mg")

    def test_permission_api_fallback_rejects_item_seq_mismatch(self):
        selected = {
            "medicine_code": "202400001",
            "product_name": "공식허가약정",
            "ingredient": None,
        }
        detail = {
            "ITEM_SEQ": "DIFFERENT",
            "ITEM_NAME": "공식허가약정",
            "MAIN_ITEM_INGR": "공식성분 100mg",
        }
        with (
            patch(
                "app.services.mfds_drug_permission.db.find_permission_product_by_item_seq",
                return_value=None,
            ),
            patch(
                "app.services.mfds_drug_permission.client.fetch_permission_detail",
                return_value=detail,
            ),
        ):
            result = gemini_service._with_official_permission_ingredient(selected)
        self.assertIsNone(result["ingredient"])

    def test_permission_api_fallback_rejects_product_name_mismatch(self):
        selected = {
            "medicine_code": "202400001",
            "product_name": "공식허가약정",
            "ingredient": None,
        }
        detail = {
            "ITEM_SEQ": "202400001",
            "ITEM_NAME": "다른공식제품정",
            "MAIN_ITEM_INGR": "공식성분 100mg",
        }
        with (
            patch(
                "app.services.mfds_drug_permission.db.find_permission_product_by_item_seq",
                return_value=None,
            ),
            patch(
                "app.services.mfds_drug_permission.client.fetch_permission_detail",
                return_value=detail,
            ),
        ):
            result = gemini_service._with_official_permission_ingredient(selected)
        self.assertIsNone(result["ingredient"])

    def test_permission_name_mismatch_retries_mfds_even_when_local_has_ingredient(self):
        selected = {
            "medicine_code": "202400001",
            "product_name": "공식허가약정(정확한명칭)",
            "ingredient": None,
        }
        local_row = {
            "item_seq": "202400001",
            "item_name": "다른표기약정",
            "main_item_ingr": "오래된성분 100mg",
        }
        detail = {
            "ITEM_SEQ": "202400001",
            "ITEM_NAME": "공식허가약정(정확한명칭)",
            "MAIN_ITEM_INGR": "확인된성분 100mg",
        }
        with (
            patch(
                "app.services.mfds_drug_permission.db.find_permission_product_by_item_seq",
                return_value=local_row,
            ),
            patch(
                "app.services.mfds_drug_permission.client.fetch_permission_detail",
                return_value=detail,
            ) as fetch_detail,
        ):
            result = gemini_service._with_official_permission_ingredient(selected)

        fetch_detail.assert_called_once_with(
            "공식허가약정(정확한명칭)",
            item_seq="202400001",
        )
        self.assertEqual(result["ingredient"], "확인된성분 100mg")

    def test_permission_name_mismatch_fallback_is_not_accepted(self):
        selected = {
            "medicine_code": "202400001",
            "product_name": "공식허가약정(정확한명칭)",
            "ingredient": None,
        }
        local_row = {
            "item_seq": "202400001",
            "item_name": "다른표기약정",
            "main_item_ingr": "오래된성분 100mg",
        }
        detail = {
            "ITEM_SEQ": "202400001",
            "ITEM_NAME": "또다른공식제품정",
            "MAIN_ITEM_INGR": "추측하면안되는성분 100mg",
        }
        with (
            patch(
                "app.services.mfds_drug_permission.db.find_permission_product_by_item_seq",
                return_value=local_row,
            ),
            patch(
                "app.services.mfds_drug_permission.client.fetch_permission_detail",
                return_value=detail,
            ) as fetch_detail,
        ):
            result = gemini_service._with_official_permission_ingredient(selected)

        fetch_detail.assert_called_once()
        self.assertIsNone(result["ingredient"])

    def test_permission_only_selected_medicine_reaches_combination_consultation(self):
        reply, analyze = self._run_permission_only_safety(
            intent="combination",
            e_drug_result=None,
        )
        self.assertIn(
            "선택한 약과 지금 드시는 약 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요.",
            reply,
        )
        self.assertEqual(
            analyze.call_args.kwargs["selected_medicine"]["ingredient"],
            "공식성분 100mg",
        )

    def test_e_drug_error_uses_exact_permission_fallback(self):
        reply, analyze = self._run_permission_only_safety(
            intent="combination",
            e_drug_error=RuntimeError("upstream unavailable"),
        )
        self.assertIn(
            "선택한 약과 지금 드시는 약 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요.",
            reply,
        )
        analyze.assert_called_once()

    def test_permission_only_selected_medicine_reaches_duplicate_consultation(self):
        reply, analyze = self._run_permission_only_safety(
            intent="duplicate",
            e_drug_result=None,
        )
        self.assertIn("성분이나 비슷한 효과가 겹친다는 정보를 확인한 공식 자료에서는 찾지 못했어요", reply)
        self.assertIn("더 궁금하시면 의사나 약사와 상담해 주세요.", reply)
        self.assertNotIn("모든 위험이 없다는 뜻은 아니에요", reply)
        self.assertEqual(
            analyze.call_args.kwargs["risk_types"],
            {"중복성분", "효능군중복"},
        )

    def test_duplicate_positive_match_keeps_gemini_explanation_flow(self):
        selected = {"medicine_code": "202400001", "product_name": "공식허가약정"}
        verified = {
            **selected,
            "ingredient": "공식성분 100mg",
            "_permission_identity_verified": True,
        }
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch("app.services.external_api_service.fetch_e_drug_info", return_value=None),
            patch.object(gemini_service, "_with_official_permission_ingredient", return_value=verified),
            patch(
                "app.services.dur_service.analyze_dur_consultation",
                return_value={
                    "status": "current",
                    "items": [{"type": "중복성분", "reason": "공식 중복 근거"}],
                    "reason": None,
                },
            ),
            patch("app.services.chat_context_service.enrich_dur_matches", side_effect=lambda items: items),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=[
                    SimpleNamespace(parsed={"drug_names": []}),
                    SimpleNamespace(text="공식 중복 결과를 이해하기 쉽게 설명한 답변입니다."),
                ],
            ) as generate,
        ):
            reply = gemini_service.generate_chat_response(
                "빠른 질문", user_id="U1", selected_medicine=selected, intent="duplicate"
            )
        self.assertIn("공식 중복 결과", reply)
        self.assertNotIn("확인한 공식 자료에서는 찾지 못했어요", reply)
        self.assertEqual(generate.call_count, 2)

    def test_combination_consults_all_three_types_in_one_analysis(self):
        selected = {"medicine_code": "202400001", "product_name": "공식허가약정"}
        verified = {**selected, "ingredient": "공식성분 100mg"}
        matches = [
            {"type": "병용금기", "reason": "공식 함께 사용 주의"},
            {"type": "중복성분", "reason": "공식 성분 중복"},
            {"type": "효능군중복", "reason": "공식 효과 중복"},
        ]
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch("app.services.external_api_service.fetch_e_drug_info", return_value=None),
            patch.object(gemini_service, "_with_official_permission_ingredient", return_value=verified),
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": matches,
                    "has_risk": True,
                    "reason": None,
                    "checked_types": ["병용금기", "중복성분", "효능군중복"],
                    "zero_result_types": [],
                },
            ) as analyze,
            patch("app.services.dur_service.analyze_dur_consultation") as local_analyze,
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=[
                    SimpleNamespace(parsed={"drug_names": []}),
                    SimpleNamespace(text="공식 확인 결과를 쉬운 말로 설명한 답변입니다."),
                ],
            ) as generate,
        ):
            reply = gemini_service.generate_chat_response(
                "다른 약과 같이 먹기", user_id="U1", selected_medicine=selected,
                intent="combination",
            )
        self.assertIn("공식 확인 결과", reply)
        self.assertNotIn("함께 먹으면 안 되는 조합은 확인되지 않았어요", reply)
        analyze.assert_called_once()
        local_analyze.assert_not_called()
        prompt = generate.call_args_list[1].kwargs["contents"]
        for reason in ("공식 함께 사용 주의", "공식 성분 중복", "공식 효과 중복"):
            self.assertIn(reason, prompt)

    def test_all_medicines_combination_uses_remote_list_and_remote_dur(self):
        medicines = {
            "status": "current",
            "items": [
                {"medicine_code": "100", "product_name": "OCR등록약정"},
                {"medicine_code": "200", "product_name": "손입력약정"},
            ],
            "reason": None,
        }
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False

        def official(*, medicine_code):
            return {
                "medicine_code": medicine_code,
                "product_name": "OCR등록약정" if medicine_code == "100" else "손입력약정",
                "ingredient": "공식성분",
            }

        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch(
                "app.services.medication_feature_dur_client.load_remote_current_medicines",
                return_value=medicines,
            ) as load_medicines,
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": [],
                    "has_risk": False,
                    "reason": None,
                    "checked_types": ["병용금기", "중복성분", "효능군중복"],
                    "zero_result_types": ["병용금기", "중복성분", "효능군중복"],
                },
            ) as remote_dur,
            patch("app.services.external_api_service.fetch_e_drug_info", side_effect=official),
            patch("app.services.dur_service.analyze_dur_consultation") as local_dur,
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=SimpleNamespace(parsed={"drug_names": []}),
            ),
        ):
            reply = gemini_service.generate_chat_response(
                "제가 현재 먹는 약 전체를 같이 먹을 때 주의할 점이 있는지 확인해 주세요.",
                user_id="U1",
                selected_medicine=None,
                intent="combination",
            )
        self.assertIn(
            "확인한 약들 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요.",
            reply,
        )
        self.assertIn("더 궁금한 점이 있으면 의사나 약사와 상담해 주세요.", reply)
        self.assertNotIn("안전하다고 단정", reply)
        load_medicines.assert_called_once_with(user_id="U1")
        remote_dur.assert_called_once_with(
            user_id="U1",
            selected_medicine=None,
            additional_medicines=[],
            requested_types={"병용금기", "중복성분", "효능군중복"},
        )
        local_dur.assert_not_called()

    def test_all_medicine_overview_reports_each_verified_and_unverified_medicine(self):
        medicines = {
            "status": "current",
            "items": [
                {"medicine_code": "100", "product_name": "코다론정"},
                {"medicine_code": "200", "product_name": "유한메토트렉세이트정"},
            ],
            "reason": None,
        }
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False

        def official(*, medicine_code):
            if medicine_code == "100":
                return {
                    "medicine_code": "100",
                    "product_name": "코다론정",
                    "efficacy": "공식 효능",
                }
            return None

        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch(
                "app.services.medication_feature_dur_client.load_remote_current_medicines",
                return_value=medicines,
            ),
            patch("app.services.external_api_service.fetch_e_drug_info", side_effect=official),
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                side_effect=lambda medicine, **_: medicine,
            ),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=[
                    SimpleNamespace(parsed={"drug_names": []}),
                    _chat_response(
                        "현재 복용약 확인 범위: 코다론정은 확인했고 "
                        "유한메토트렉세이트정은 확인하지 못했어요."
                    ),
                    _chat_response(
                        "코다론정은 공식 효능을 확인했어요."
                    ),
                ],
            ) as generate,
        ):
            reply = gemini_service.generate_chat_response(
                "제가 현재 먹는 약 전체를 쉬운 말로 알려주세요.",
                user_id="U1",
                selected_medicine=None,
                intent="overview",
            )

        self.assertEqual(generate.call_count, 3)
        self.assertIn("일부 약은 공식정보를 확인하지 못해 답변에서 제외했어요.", reply)
        self.assertIn("코다론정은 공식 효능", reply)
        self.assertNotIn("현재 복용약 확인 범위", reply)
        self.assertNotIn("유한메토트렉세이트정", reply)

    def test_all_medicine_overview_merges_ai_screen_temporary_medicine(self):
        registered = {
            "status": "current",
            "items": [{"medicine_code": "100", "product_name": "코다론정"}],
            "reason": None,
        }

        def official(*, medicine_code):
            names = {"100": "코다론정", "200": "유한메토트렉세이트정"}
            return {
                "medicine_code": medicine_code,
                "product_name": names[medicine_code],
                "efficacy": f"{names[medicine_code]} 공식 효능",
            }

        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch(
                "app.services.medication_feature_dur_client.load_remote_current_medicines",
                return_value=registered,
            ),
            patch(
                "app.services.external_api_service.fetch_e_drug_info",
                side_effect=official,
            ),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=[
                    SimpleNamespace(parsed={"drug_names": []}),
                    _chat_response("코다론정과 유한메토트렉세이트정의 공식 효능을 알려드려요."),
                ],
            ),
        ):
            reply = gemini_service.generate_chat_response(
                "제가 현재 먹는 약 전체를 쉬운 말로 알려주세요.",
                user_id="U1",
                selected_medicine=None,
                temporary_medicines=[
                    {"medicine_code": "200", "product_name": "유한메토트렉세이트정"}
                ],
                intent="overview",
            )

        self.assertIn("코다론정", reply)
        self.assertIn("유한메토트렉세이트정", reply)

    def test_all_medicine_precautions_retries_missing_product_with_larger_budget(self):
        medicines = {
            "status": "current",
            "items": [
                {"medicine_code": "100", "product_name": "코다론정"},
                {"medicine_code": "200", "product_name": "유한메토트렉세이트정"},
            ],
            "reason": None,
        }
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False

        def official(*, medicine_code):
            name = "코다론정" if medicine_code == "100" else "유한메토트렉세이트정"
            return {
                "medicine_code": medicine_code,
                "product_name": name,
                "cautions": "만 12세 미만은 사용하면 안 되며 1일 2회 조건을 확인해야 해요.",
            }

        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch(
                "app.services.medication_feature_dur_client.load_remote_current_medicines",
                return_value=medicines,
            ),
            patch("app.services.external_api_service.fetch_e_drug_info", side_effect=official),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=[
                    SimpleNamespace(parsed={"drug_names": []}),
                    _chat_response("코다론정은 1일 2회 조건을 확인해야 해요."),
                    _chat_response(
                        "코다론정은 1일 2회 조건을 확인해야 해요. "
                        "유한메토트렉세이트정은 만 12세 미만은 사용하면 안 돼요."
                    ),
                ],
            ) as generate,
        ):
            reply = gemini_service.generate_chat_response(
                "제가 현재 먹는 약마다 공식 자료에서 확인되는 주의할 점을 알려주세요.",
                user_id="U1",
                selected_medicine=None,
                intent="precautions",
            )

        self.assertEqual(generate.call_count, 3)
        self.assertEqual(
            generate.call_args_list[1].kwargs["config"]["max_output_tokens"],
            1024,
        )
        self.assertEqual(
            generate.call_args_list[2].kwargs["config"]["max_output_tokens"],
            1024,
        )
        all_medicine_prompt = generate.call_args_list[1].kwargs["contents"]
        self.assertIn("약마다 핵심 1~2문장", all_medicine_prompt)
        self.assertIn("공통 안내는 한 번만", all_medicine_prompt)
        self.assertIn("특정 약을 누락하지 마세요", all_medicine_prompt)
        for expected in ("코다론정", "유한메토트렉세이트정", "1일 2회", "만 12세 미만", "사용하면 안"):
            self.assertIn(expected, reply)

    def test_all_medicine_combination_retries_single_medicine_wording(self):
        first = _chat_response("선택한 약은 다른 약과 함께 확인해야 해요.")
        second = _chat_response("현재 복용약 전체에서 확인된 주의 조합을 알려드려요.")
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[first, second],
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="현재 복용약 전체의 함께 사용 주의를 설명하세요.",
                forbidden_phrases=("선택한 약",),
            )
        self.assertEqual(generate.call_count, 2)
        self.assertNotIn("선택한 약", reply)
        self.assertIn("현재 복용약 전체", reply)

    def test_all_medicine_missing_after_one_retry_returns_safe_fallback(self):
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[
                _chat_response("코다론정의 공식정보를 확인했어요."),
                _chat_response("코다론정만 다시 설명했어요."),
            ],
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="현재 복용약 두 가지를 빠짐없이 설명하세요.",
                required_medicine_names=("코다론정", "유한메토트렉세이트정"),
            )
        self.assertEqual(generate.call_count, 2)
        self.assertEqual(reply, gemini_service.INCOMPLETE_CHAT_REPLY)
        self.assertNotIn("공식정보를 확인했어요", reply)

    def test_complete_all_medicine_precautions_pass_without_unnecessary_retry(self):
        complete = (
            "코다론정은 1일 2회 조건을 확인해야 해요. "
            "유한메토트렉세이트정은 만 12세 미만은 사용하면 안 돼요."
        )
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            return_value=_chat_response(complete),
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="공식 주의 조건을 설명하세요.",
                max_output_tokens=1024,
                required_medicine_names=("코다론정", "유한메토트렉세이트정"),
            )
        self.assertEqual(generate.call_count, 1)
        self.assertEqual(reply, complete)
        self.assertEqual(generate.call_args.kwargs["config"]["max_output_tokens"], 1024)
        for expected in ("1일 2회", "만 12세 미만", "사용하면 안"):
            self.assertIn(expected, reply)

    def test_single_medicine_selected_wording_keeps_existing_quality_behavior(self):
        reply_text = "선택한 약은 공식정보를 기준으로 확인했어요."
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            return_value=_chat_response(reply_text),
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="선택한 약을 설명하세요.",
            )
        self.assertEqual(generate.call_count, 1)
        self.assertEqual(reply, reply_text)

    def test_all_medicine_duplicate_reanalyzes_current_list_without_local_stale_result(self):
        medicines = {
            "status": "current",
            "items": [
                {"medicine_code": "100", "product_name": "코다론정"},
                {"medicine_code": "200", "product_name": "유한메토트렉세이트정"},
            ],
            "reason": None,
        }
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch(
                "app.services.medication_feature_dur_client.load_remote_current_medicines",
                return_value=medicines,
            ),
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": [],
                    "has_risk": False,
                    "reason": None,
                    "checked_types": ["병용금기", "중복성분", "효능군중복"],
                    "zero_result_types": ["병용금기", "중복성분", "효능군중복"],
                },
            ) as remote_dur,
            patch("app.services.external_api_service.fetch_e_drug_info") as fetch,
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                side_effect=lambda medicine, **_: {**medicine, "ingredient": "공식성분"},
            ),
            patch(
                "app.services.chat_context_service.load_latest_dur_context",
            ) as local_latest,
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=SimpleNamespace(parsed={"drug_names": []}),
            ),
        ):
            fetch.return_value = None
            reply = gemini_service.generate_chat_response(
                "제가 현재 먹는 약 전체에서 같은 성분의 약이 있나요?",
                user_id="U1",
                selected_medicine=None,
                intent="duplicate",
            )

        remote_dur.assert_called_once_with(
            user_id="U1",
            selected_medicine=None,
            additional_medicines=[],
            requested_types={"중복성분"},
        )
        local_latest.assert_not_called()
        self.assertNotIn("복용 중인 약이 바뀌어", reply)
        self.assertIn(
            "확인한 약들 사이에서 같은 성분의 중복은 확인되지 않았어요.",
            reply,
        )
        self.assertIn("더 궁금한 점이 있으면 의사나 약사와 상담해 주세요.", reply)

    def test_selected_medicines_combination_uses_exact_selected_scope(self):
        selected = [
            {"medicine_code": "100", "product_name": "코다론정"},
            {"medicine_code": "200", "product_name": "유한메토트렉세이트정"},
        ]
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False

        def official(*, medicine_code):
            name = "코다론정" if medicine_code == "100" else "유한메토트렉세이트정"
            return {
                "medicine_code": medicine_code,
                "product_name": name,
                "ingredient": f"{name} 공식성분",
            }

        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch(
                "app.services.external_api_service.fetch_e_drug_info",
                side_effect=official,
            ) as fetch,
            patch(
                "app.services.external_api_service.search_drug_info_by_name",
            ) as name_search,
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": [],
                    "has_risk": False,
                    "reason": None,
                    "checked_types": ["병용금기", "중복성분", "효능군중복"],
                    "zero_result_types": ["병용금기", "중복성분", "효능군중복"],
                },
            ) as remote_dur,
        ):
            reply = gemini_service.generate_chat_response(
                "코다론정, 유한메토트렉세이트정을 함께 사용할 때 주의할 점이 있나요?",
                user_id="U1",
                selected_medicines=selected,
                intent="combination",
            )

        self.assertEqual(
            [call.kwargs["medicine_code"] for call in fetch.call_args_list],
            ["100", "200"],
        )
        name_search.assert_not_called()
        remote_dur.assert_called_once_with(
            user_id="U1",
            selected_medicine=None,
            additional_medicines=selected,
            requested_types={"병용금기", "중복성분", "효능군중복"},
            include_current_medicines=False,
        )
        self.assertIn(
            "확인한 약들 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요.",
            reply,
        )

    def test_selected_medicines_duplicate_preserves_found_warning(self):
        selected = [
            {"medicine_code": "100", "product_name": "첫번째약정"},
            {"medicine_code": "200", "product_name": "두번째약정"},
        ]
        warning = "두 약에 같은 공식성분이 있어 중복 복용을 확인해야 해요."
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False

        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch(
                "app.services.external_api_service.fetch_e_drug_info",
                side_effect=lambda *, medicine_code: {
                    "medicine_code": medicine_code,
                    "product_name": "첫번째약정" if medicine_code == "100" else "두번째약정",
                    "ingredient": "같은 공식성분",
                },
            ),
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": [{"type": "중복성분", "reason": warning}],
                    "has_risk": True,
                    "reason": None,
                    "checked_types": ["중복성분"],
                    "zero_result_types": [],
                },
            ) as remote_dur,
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=_chat_response(warning),
            ),
        ):
            reply = gemini_service.generate_chat_response(
                "선택한 두 약에 같은 성분이 있나요?",
                user_id="U1",
                selected_medicines=selected,
                intent="duplicate",
            )

        remote_dur.assert_called_once_with(
            user_id="U1",
            selected_medicine=None,
            additional_medicines=selected,
            requested_types={"중복성분"},
            include_current_medicines=False,
        )
        self.assertIn(warning, reply)

    def test_selected_medicines_with_missing_identity_stays_incomplete(self):
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
            ) as remote_dur,
        ):
            reply = gemini_service.generate_chat_response(
                "선택한 두 약을 같이 먹어도 되나요?",
                user_id="U1",
                selected_medicines=[
                    {"medicine_code": "100", "product_name": "확인약정"},
                    {"medicine_code": "", "product_name": "코드없는약"},
                ],
                intent="combination",
            )

        remote_dur.assert_not_called()
        self.assertIn("공식 제품명과 코드를 확인하지 못한 약", reply)
        self.assertNotIn("확인한 약들 사이에서", reply)

    def test_combination_zero_does_not_hide_duplicate_warning(self):
        selected = {"medicine_code": "202400001", "product_name": "공식허가약정"}
        verified = {**selected, "ingredient": "공식성분 100mg"}
        duplicate_reason = "같은 성분이 겹쳐 있어 확인이 필요해요."
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch("app.services.external_api_service.fetch_e_drug_info", return_value=None),
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                return_value=verified,
            ),
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": [{"type": "중복성분", "reason": duplicate_reason}],
                    "has_risk": True,
                    "reason": None,
                    "checked_types": ["병용금기", "중복성분", "효능군중복"],
                    "zero_result_types": ["병용금기", "효능군중복"],
                },
            ),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=[
                    SimpleNamespace(parsed={"drug_names": []}),
                    SimpleNamespace(text=f"선생님, {duplicate_reason}"),
                ],
            ) as generate,
        ):
            reply = gemini_service.generate_chat_response(
                "같이 먹어도 괜찮나요?",
                user_id="U1",
                selected_medicine=selected,
                intent="combination",
            )
        self.assertIn(
            "선택한 약과 지금 드시는 약 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요.",
            reply,
        )
        self.assertIn(duplicate_reason, reply)
        prompt = generate.call_args_list[1].kwargs["contents"]
        self.assertIn(duplicate_reason, prompt)
        self.assertIn("정상 완료된 0건 안내", prompt)

    def test_all_medicines_empty_and_lookup_failure_are_distinct(self):
        for context, expected in (
            (
                {"status": "empty", "items": [], "reason": "no_active_medicines"},
                "등록되어 복용 중인 약이 없어요",
            ),
            (
                {"status": "missing", "items": [], "reason": "medication_service_unavailable"},
                "복용약 목록을 불러오지 못했어요",
            ),
        ):
            with self.subTest(status=context["status"]):
                with (
                    patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
                    patch(
                        "app.services.medication_feature_dur_client.load_remote_current_medicines",
                        return_value=context,
                    ),
                    patch("google.genai.Client") as client,
                ):
                    reply = gemini_service.generate_chat_response(
                        "제가 현재 먹는 약 전체를 쉬운 말로 알려주세요.",
                        user_id="U1",
                        selected_medicine=None,
                        intent="overview",
                    )
                self.assertIn(expected, reply)
                client.assert_not_called()

    def test_direct_all_medicine_combination_uses_remote_completed_zero(self):
        medicines = {
            "status": "current",
            "items": [{"medicine_code": "100", "product_name": "등록약정"}],
            "reason": None,
        }
        official = {
            "medicine_code": "100",
            "product_name": "등록약정",
            "ingredient": "공식성분",
        }
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch(
                "app.services.medication_feature_dur_client.load_remote_current_medicines",
                return_value=medicines,
            ) as load_medicines,
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": [],
                    "has_risk": False,
                    "reason": None,
                    "checked_types": ["병용금기", "중복성분", "효능군중복"],
                    "zero_result_types": ["병용금기", "중복성분", "효능군중복"],
                },
            ) as remote_dur,
            patch(
                "app.services.external_api_service.fetch_e_drug_info",
                return_value=official,
            ),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=SimpleNamespace(parsed={"drug_names": []}),
            ),
        ):
            reply = gemini_service.generate_chat_response(
                "제가 현재 먹는 약 전체를 같이 먹을 때 확인해 주세요.",
                user_id="U1",
                selected_medicine=None,
                intent="combination",
            )
        self.assertIn(
            "확인한 약들 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요.",
            reply,
        )
        load_medicines.assert_called_once_with(user_id="U1")
        remote_dur.assert_called_once_with(
            user_id="U1",
            selected_medicine=None,
            additional_medicines=[],
            requested_types={"병용금기", "중복성분", "효능군중복"},
        )

    def test_combination_incomplete_or_unknown_risk_is_not_zero_match(self):
        selected = {"medicine_code": "202400001", "product_name": "공식허가약정"}
        verified = {**selected, "ingredient": "공식성분 100mg"}
        for result in (
            {"status": "incomplete", "items": [], "reason": "partial"},
            {"status": "malformed", "items": [], "reason": "invalid_response"},
            {"status": "current", "items": [], "has_risk": None},
        ):
            with self.subTest(result=result):
                with (
                    patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
                    patch("google.genai.Client"),
                    patch("app.services.external_api_service.fetch_e_drug_info", return_value=None),
                    patch.object(gemini_service, "_with_official_permission_ingredient", return_value=verified),
                    patch.object(
                        gemini_service, "_generate_content_with_retry",
                        return_value=SimpleNamespace(parsed={"drug_names": []}),
                    ),
                    patch(
                        "app.services.medication_feature_dur_client.load_remote_combination_context",
                        return_value=result,
                    ),
                ):
                    reply = gemini_service.generate_chat_response(
                        "다른 약과 같이 먹기", user_id="U1",
                        selected_medicine=selected, intent="combination",
                    )
                self.assertIn("모두 확인하지 못했어요", reply)
                self.assertNotIn("정보를 찾지 못했어요. 이것만으로", reply)

    def test_duplicate_dur_failure_is_not_reported_as_zero_match(self):
        selected = {"medicine_code": "202400001", "product_name": "공식허가약정"}
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client"),
            patch("app.services.external_api_service.fetch_e_drug_info", return_value=None),
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                return_value={**selected, "ingredient": "공식성분 100mg"},
            ),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=SimpleNamespace(parsed={"drug_names": []}),
            ),
            patch(
                "app.services.dur_service.analyze_dur_consultation",
                return_value={
                    "status": "missing",
                    "items": [],
                    "reason": "dur_data_unavailable",
                },
            ),
        ):
            reply = gemini_service.generate_chat_response(
                "빠른 질문", user_id="U1", selected_medicine=selected, intent="duplicate"
            )
        self.assertIn("지금은 약을 함께 사용할 때 주의할 공식 정보를 확인하지 못했어요", reply)
        self.assertNotIn("확인한 공식 자료에서는 찾지 못했어요", reply)

    def test_duplicate_missing_ingredient_is_not_reported_as_zero_match(self):
        selected = {"medicine_code": "202400001", "product_name": "공식허가약정"}
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("app.services.external_api_service.fetch_e_drug_info", return_value=None),
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                return_value={**selected, "ingredient": None},
            ),
        ):
            reply = gemini_service.generate_chat_response(
                "빠른 질문", user_id="U1", selected_medicine=selected, intent="duplicate"
            )
        self.assertIn("선택한 약의 성분을 공식 자료에서 확인하지 못했어요", reply)
        self.assertNotIn("확인한 공식 자료에서는 찾지 못했어요", reply)

    def test_duplicate_zero_match_message_does_not_apply_to_other_safety_intents(self):
        for intent in ("combination", "age", "pregnancy"):
            with self.subTest(intent=intent):
                reply, _ = self._run_permission_only_safety(intent=intent)
                self.assertNotIn("성분이나 비슷한 효과가 겹친다는 정보", reply)

    def test_unverified_selected_medicine_keeps_missing_fallback(self):
        selected = {
            "medicine_code": "202400001",
            "product_name": "검증실패약정",
        }
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch(
                "app.services.external_api_service.fetch_e_drug_info",
                return_value=None,
            ),
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                return_value={**selected, "ingredient": None},
            ),
            patch("app.services.dur_service.analyze_dur_consultation") as analyze,
        ):
            reply = gemini_service.generate_chat_response(
                "빠른 질문",
                user_id="U1",
                selected_medicine=selected,
                intent="combination",
            )
        self.assertIn("모두 확인하지 못했으니 다시 확인이 필요해요", reply)
        analyze.assert_not_called()

    def test_permission_only_efficacy_uses_exact_official_document(self):
        selected = {
            "medicine_code": "202400001",
            "product_name": "공식허가약정",
        }
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch(
                "app.services.external_api_service.fetch_e_drug_info",
                return_value=None,
            ),
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                return_value={
                    **selected,
                    "ingredient": "공식성분 100mg",
                    "efficacy": "공식 허가 효능",
                    "source": "식약처 의약품 제품 허가정보",
                    "_permission_identity_verified": True,
                },
            ),
            patch("google.genai.Client") as client,
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=[
                    SimpleNamespace(parsed={"drug_names": []}),
                    SimpleNamespace(text="공식 허가정보만 근거로 작성한 충분한 설명입니다."),
                ],
            ) as generate,
        ):
            reply = gemini_service.generate_chat_response(
                "효능을 알려줘",
                user_id="U1",
                selected_medicine=selected,
                intent="efficacy",
            )
        self.assertEqual(reply, "공식 허가정보만 근거로 작성한 충분한 설명입니다.")
        self.assertEqual(generate.call_count, 2)
        self.assertIn("공식 허가 효능", generate.call_args.kwargs["contents"])

    def test_e_drug_efficacy_has_priority_without_permission_fallback(self):
        e_drug = {
            "medicine_code": "202400001",
            "product_name": "공식허가약정",
            "efficacy": "e약은요 공식 효능",
            "source": "e약은요",
        }
        reply, enrich, generate = self._run_permission_general(
            intent="efficacy",
            permission_fields={"efficacy": "허가정보 효능"},
            e_drug_result=e_drug,
        )
        self.assertIn("충분한 설명", reply)
        enrich.assert_not_called()
        self.assertIn("e약은요 공식 효능", generate.call_args.kwargs["contents"])
        self.assertNotIn("허가정보 효능", generate.call_args.kwargs["contents"])

    def test_e_drug_timeout_uses_permission_efficacy(self):
        reply, enrich, generate = self._run_permission_general(
            intent="efficacy",
            permission_fields={"efficacy": "허가정보 공식 효능"},
            e_drug_error=TimeoutError("timeout"),
        )
        self.assertIn("충분한 설명", reply)
        enrich.assert_called_once()
        self.assertIn("허가정보 공식 효능", generate.call_args.kwargs["contents"])

    def test_e_drug_empty_uses_permission_dosage(self):
        reply, _, generate = self._run_permission_general(
            intent="dosage",
            permission_fields={"usage": "허가정보 공식 용법용량"},
        )
        self.assertIn("충분한 설명", reply)
        self.assertIn("허가정보 공식 용법용량", generate.call_args.kwargs["contents"])

    def test_e_drug_empty_uses_permission_precautions(self):
        reply, _, generate = self._run_permission_general(
            intent="precautions",
            permission_fields={"cautions": "허가정보 공식 주의사항"},
        )
        self.assertIn("충분한 설명", reply)
        self.assertIn("허가정보 공식 주의사항", generate.call_args.kwargs["contents"])

    def test_e_drug_empty_uses_explicit_permission_side_effects(self):
        reply, _, generate = self._run_permission_general(
            intent="side_effects",
            permission_fields={"side_effects": "공식 이상반응 절"},
        )
        self.assertIn("충분한 설명", reply)
        self.assertIn("공식 이상반응 절", generate.call_args.kwargs["contents"])

    def test_permission_exact_validation_failure_keeps_general_fallback(self):
        reply, _, generate = self._run_permission_general(
            intent="efficacy",
            permission_fields={"efficacy": "다른 제품 효능"},
            permission_verified=False,
        )
        self.assertIn("식약처 공식정보를 확인할 수 없어", reply)
        generate.assert_not_called()

    def test_permission_identity_only_without_requested_field_keeps_fallback(self):
        selected = {"medicine_code": "202400001", "product_name": "공식허가약정"}
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("app.services.external_api_service.fetch_e_drug_info", return_value=None),
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                return_value={
                    **selected,
                    "ingredient": "공식성분 100mg",
                    "_permission_identity_verified": True,
                },
            ),
            patch.object(gemini_service, "_generate_content_with_retry") as generate,
        ):
            reply = gemini_service.generate_chat_response(
                "효능을 알려줘", user_id="U1", selected_medicine=selected, intent="efficacy"
            )
        self.assertIn("식약처 공식정보를 확인할 수 없어", reply)
        generate.assert_not_called()

    def test_permission_diagnostic_log_excludes_sensitive_content(self):
        official = {
            "medicine_code": "198700430",
            "product_name": "민감한 질문에 포함된 제품명",
            "ingredient": None,
        }
        with (
            patch(
                "app.services.mfds_drug_permission.db.find_permission_product_by_item_seq",
                return_value=None,
            ),
            patch(
                "app.services.mfds_drug_permission.client.fetch_permission_detail",
                side_effect=RuntimeError("SECRET_KEY full response body"),
            ),
            self.assertLogs(gemini_service.logger, level="WARNING") as captured,
        ):
            result = gemini_service._with_official_permission_ingredient(official)

        output = "\n".join(captured.output)
        self.assertIsNone(result["ingredient"])
        self.assertIn("permission_api_failed", output)
        self.assertIn("exception_type=RuntimeError", output)
        self.assertIn("final_ingredient_usable=false", output.casefold())
        self.assertNotIn("SECRET_KEY", output)
        self.assertNotIn("full response body", output)
        self.assertNotIn("민감한 질문", output)

    def test_selected_permission_ingredient_reaches_dur_consultation(self):
        selected = {
            "medicine_code": "198700430",
            "product_name": "알마겔정(알마게이트)(수출명:유한가스트라겔정)",
        }
        e_drug = {**selected, "ingredient": None, "source": "e약은요"}
        enriched = {**e_drug, "ingredient": "알마게이트 500mg"}
        fake_client = MagicMock()
        fake_client.__enter__.return_value = fake_client
        fake_client.__exit__.return_value = False
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client", return_value=fake_client),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                return_value=SimpleNamespace(parsed={"drug_names": []}),
            ),
            patch(
                "app.services.external_api_service.fetch_e_drug_info",
                return_value=e_drug,
            ),
            patch.object(
                gemini_service,
                "_with_official_permission_ingredient",
                return_value=enriched,
            ),
            patch(
                "app.services.medication_feature_dur_client.load_remote_combination_context",
                return_value={
                    "status": "current",
                    "items": [],
                    "has_risk": False,
                    "reason": None,
                    "checked_types": ["병용금기", "중복성분", "효능군중복"],
                    "zero_result_types": ["병용금기", "중복성분", "효능군중복"],
                },
            ) as analyze,
            patch("app.services.dur_service.analyze_dur_consultation") as local_analyze,
        ):
            reply = gemini_service.generate_chat_response(
                "같이 먹어도 돼?",
                user_id="U1",
                selected_medicine=selected,
                intent="combination",
            )

        self.assertIn(
            "선택한 약과 지금 드시는 약 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요.",
            reply,
        )
        self.assertEqual(
            analyze.call_args.kwargs["selected_medicine"]["ingredient"],
            "알마게이트 500mg",
        )
        local_analyze.assert_not_called()

    def test_question_intents_and_minimal_official_fields(self):
        self.assertIn("combination", classify_question("A약과 B약 같이 먹어도 돼?"))
        self.assertTrue(is_safety_question(classify_question("임신 중 먹어도 돼?")))
        selected = select_official_context(
            {"medicine_code": "1", "product_name": "약", "ingredient": "성분", "efficacy": "효능", "usage": "용법", "side_effects": "부작용", "source": "e약은요"},
            {"usage"},
        )
        self.assertEqual(selected, {"medicine_code": "1", "product_name": "약", "usage": "용법", "source": "e약은요"})

    def test_explicit_quick_intents_override_natural_language_classification(self):
        cases = {
            "combination": {"병용금기", "중복성분", "효능군중복"},
            "age": {"연령금기"},
            "pregnancy": {"임부금기"},
            "duplicate": {"중복성분", "효능군중복"},
        }
        for explicit_intent, expected_risk_types in cases.items():
            with self.subTest(explicit_intent=explicit_intent):
                intents = resolve_question_intents(
                    "이 약 같이 먹어도 돼? 안전한가요?",
                    explicit_intent,
                )
                self.assertEqual(intents, {explicit_intent})
                self.assertEqual(
                    set().union(
                        *(
                            chat_context_service.DUR_TYPES_BY_INTENT.get(
                                intent,
                                set(),
                            )
                            for intent in intents
                        )
                    ),
                    expected_risk_types,
                )

    def test_free_text_keeps_existing_question_classification(self):
        self.assertEqual(
            resolve_question_intents("이 약 같이 먹어도 돼?"),
            classify_question("이 약 같이 먹어도 돼?"),
        )

    def test_explicit_edrug_intents_select_only_requested_fields(self):
        official = {
            "medicine_code": "1",
            "product_name": "약",
            "efficacy": "효능",
            "usage": "용법",
            "cautions": "주의",
            "side_effects": "부작용",
            "source": "e약은요",
        }
        expected_fields = {
            "efficacy": "efficacy",
            "dosage": "usage",
            "precautions": "cautions",
            "side_effects": "side_effects",
        }
        for intent, field in expected_fields.items():
            with self.subTest(intent=intent):
                selected = select_official_context(official, {intent})
                self.assertIn(field, selected)
                self.assertFalse(is_safety_question({intent}))

    def test_current_accepts_reordered_multiset(self):
        conn = _database(current=["성분A", "성분B", "성분A"], analyzed=["성분A", " 성분a ", "성분B"])
        with patch.object(chat_context_service, "get_connection", return_value=conn):
            result = load_latest_dur_context("U1", {"combination"})
        self.assertEqual(result["status"], "current")

    def test_changed_medicines_are_stale_and_matches_are_blocked(self):
        matches = [{"type": "병용금기", "ingredient_a": "과거A", "ingredient_b": "과거B", "reason": "과거 결과"}]
        conn = _database(current=["현재성분"], analyzed=["과거A", "과거B"], matches=matches)
        with patch.object(chat_context_service, "get_connection", return_value=conn):
            result = load_latest_dur_context("U1", {"combination"})
        self.assertEqual(result, {"status": "stale", "items": []})

    def test_missing_and_not_required(self):
        conn = _database(current=["성분A"], include_result=False)
        with patch.object(chat_context_service, "get_connection", return_value=conn):
            missing = load_latest_dur_context("U1", {"combination"})
        self.assertEqual(missing, {"status": "missing", "items": []})
        self.assertEqual(load_latest_dur_context("U1", {"efficacy"}), {"status": "not_required", "items": []})
        self.assertEqual(load_latest_dur_context("", {"combination"}), {"status": "missing", "items": []})

    def test_prompt_keeps_safety_rules_and_excludes_raw_json(self):
        prompt_text = build_grounded_chat_prompt(message="같이 먹어도 돼?", intents={"combination"}, official_contexts=[], dur_result={"status": "stale", "items": []})
        self.assertIn("DUR 위험 여부를 새로 추론하거나 판정하지 마세요", prompt_text)
        self.assertIn("서버가 전달한 DUR 분석 결과만 설명하세요", prompt_text)
        self.assertIn("핵심 답을 첫 문장에", prompt_text)
        self.assertIn("근거가 있는 경우에만", prompt_text)
        self.assertIn("stale", prompt_text)
        self.assertNotIn("raw_json", prompt_text)

    def test_prompt_requires_plain_language_without_dropping_exact_medicine_terms(self):
        prompt_text = build_grounded_chat_prompt(
            message="이 약이 어떤 약인지 알려줘",
            intents={"efficacy"},
            official_contexts=[],
            dur_result={"status": "not_required", "items": []},
        )
        examples = {
            "융모": "장의 구조를 뜻하는 문맥에서만",
            "상피": "몸 표면이나 장기를 덮는 얇은 층",
            "수용체": "약 성분이 작용하는 몸속 부분",
            "대사": "약을 처리하는 문맥에서만",
            "흡수": "약 성분이 몸 안으로 들어오는 과정",
            "배설": "몸 밖으로 내보내는 과정",
            "분비": "몸에서 특정 물질을 만들어 내보내는 과정",
            "효소": "몸속에서 화학 작용을 돕는 물질",
        }
        for term, explanation in examples.items():
            with self.subTest(term=term):
                self.assertIn(term, prompt_text)
                self.assertIn(explanation, prompt_text)
        self.assertIn('처음 등장할 때만 "전문용어(짧고 쉬운 뜻)"', prompt_text)
        self.assertIn("같은 답변에서 반복 설명하지 마세요", prompt_text)
        self.assertIn('직접 호칭을 붙일 때는 "선생님"만 사용', prompt_text)
        self.assertIn("고초열처럼 낯선 공식 질환명", prompt_text)
        self.assertIn("주성분, 복용량, 공식 의약품명·제품명·성분명은 원래 표현을 유지", prompt_text)
        self.assertIn("추측하지 말고", prompt_text)
        self.assertIn("의료적 판단을 단정하지 마세요", prompt_text)

    def test_prompt_preserves_source_conditions_and_personal_prescription_boundary(self):
        fixtures = {
            "efficacy": {"efficacy": "합성 증상 완화"},
            "dosage": {"dosage": "18세 이상, 1회 2mg, 하루 1회, 3일간 주사"},
            "precautions": {"precautions": "12세 미만은 사용하면 안 됨. 예외: 공식 조건 충족 시"},
            "side_effects": {"side_effects": "심각한 증상이 나타날 수 있음"},
            "general": {},
        }
        rules = (
            "목록에 없는 어려운 말에도 같은 원칙",
            "단순 단어 치환은 하지 마세요",
            "용량, 단위, 횟수, 기간, 연령 조건과 적용 대상, 금지·주의·예외 조건의 강도를 그대로 유지",
            '"사용하면 안 됨"을 "주의가 필요함"으로 완화하지 마세요',
            '심각한 위험이나 증상을 단순한 "불편함"으로 축소하지 마세요',
            "투여를 모든 경우에 복용으로 바꾸지 마세요",
            "먹는 약·주사·바르는 약 등 공식 자료에 나온 사용 방식을 유지",
            "설명이 어렵다는 이유로 공식 자료가 없다고 답하지 마세요",
            "공식 자료의 일반 사용법은 일반 안내임을 분명히",
            "실제 등록 처방 정보가 제공된 경우에만",
            "개인 처방 정보 없이 개인 복용량을 새로 정하지 말고",
            "일반 사용법을 개인 처방처럼 표현하지 마세요",
            "공식정보에 없는 내용을 사실처럼 만들지 마세요",
            "복용 시작, 중단, 용량 변경을 지시하지 마세요",
            "핵심 답을 첫 문장에",
        )
        for intent, source in fixtures.items():
            with self.subTest(intent=intent):
                prompt = build_grounded_chat_prompt(
                    message="합성 질문", intents={intent},
                    official_contexts=[source] if source else [],
                    dur_result={"status": "not_required", "items": []},
                )
                for rule in rules:
                    self.assertIn(rule, prompt)
                for value in source.values():
                    self.assertIn(value, prompt)

    def test_prompt_requires_short_plain_text_without_losing_official_meaning(self):
        prompt = build_grounded_chat_prompt(
            message="어디에 쓰나요?",
            intents={"efficacy"},
            official_contexts=[{"efficacy": "공식 자료의 합성 효능"}],
            dur_result={"status": "not_required", "items": []},
        )
        for rule in (
            "핵심 답을 첫 문장에",
            "한 문장에는 한 가지 내용",
            "일반 질문은 보통 2~3문장",
            "precautions·side_effects는 가장 중요한 내용부터 핵심 3~4문장",
            "약 전체 질문은 확인된 약마다 핵심 1문장",
            "글자 수에 맞춰 문장을 기계적으로 자르지 마세요",
            "일반적인 인사, 질문과 관련 없는 공식정보, 긴 맺음말",
            "일반 텍스트로만",
            "Markdown 제목(#)",
            "HTML 태그를 쓰지 마세요",
            "공식 조건·금지·심각한 위험",
            "공식 효능 자료에 확인된 의미 안에서",
            "개인 처방 정보 없이 개인 복용량을 새로 정하지 말고",
            "정상적으로 확인한 0건과 자료 부족·조회 실패·미완료를 혼동하지 마세요",
            "더 궁금하시면 의사나 약사와 상담해 주세요.",
            "복용 전 의사나 약사와 상담해 주세요.",
        ):
            self.assertIn(rule, prompt)
        self.assertNotIn("DUR 안내, 다음 안내", prompt)

    def test_prompt_sets_target_length_without_dropping_safety(self):
        prompt = build_grounded_chat_prompt(
            message="현재 약마다 주의할 점을 알려주세요.",
            intents={"precautions"},
            official_contexts=[
                {"product_name": "약가정", "cautions": "만 12세 미만은 사용하면 안 됨"},
                {"product_name": "약나정", "cautions": "1일 2회 조건을 확인해야 함"},
            ],
            dur_result={"status": "not_required", "items": []},
        )
        self.assertIn("숫자·용량·단위·횟수·기간·연령·금지·예외 조건", prompt)
        self.assertIn("확인하지 못한 약·검사 범위는 분량 목표보다 우선", prompt)
        self.assertIn("이를 빼거나 의미를 약하게 만들어", prompt)

    def test_plain_chat_reply_removes_only_markup_and_is_idempotent(self):
        raw = (
            "# 쉽게 말하면\n"
            "**제품_AB-12정**의 주성분은 __성분_X__예요.\n"
            "> [공식 설명](https://example.test/drug)을 확인했어요.\n"
            "1. 만 65세 이상은 주의해 주세요.\n"
            "2) 성분-Z 10 mg은 그대로예요.\n"
            "- 1~2 mg, 0.5 mg, 1일 2회, 5% 이하·10% 초과\n"
            "*꼭 확인할 점*은 다음과 같아요.\n"
            "* `-0.5 mg`은 음수 표기예요.\n\n\n"
            "---\n`공식 제품명`은 그대로 둬요.\n```0.5 mg```도 유지해요."
        )
        expected = (
            "쉽게 말하면\n"
            "제품_AB-12정의 주성분은 성분_X예요.\n"
            "공식 설명을 확인했어요.\n"
            "• 만 65세 이상은 주의해 주세요.\n"
            "• 성분-Z 10 mg은 그대로예요.\n"
            "• 1~2 mg, 0.5 mg, 1일 2회, 5% 이하·10% 초과\n"
            "꼭 확인할 점은 다음과 같아요.\n"
            "• -0.5 mg은 음수 표기예요.\n\n"
            "공식 제품명은 그대로 둬요.\n0.5 mg도 유지해요."
        )
        cleaned = gemini_service._plain_chat_reply(raw)
        self.assertEqual(cleaned, expected)
        self.assertEqual(gemini_service._plain_chat_reply(cleaned), cleaned)

    def test_generated_reply_is_plain_text_without_changing_reply_contract(self):
        response = _chat_response(
            "## 쉽게 말하면\n**공식 근거를 확인했어요.** 1일 2회예요."
        )
        self.assertEqual(
            gemini_service._finalize_chat_response(response),
            "쉽게 말하면\n공식 근거를 확인했어요. 1일 2회예요.",
        )

    def test_long_but_truncated_reply_is_rejected(self):
        response = _chat_response(
            "공식 자료를 확인했어요. 만 65세 이상은 특히",
            finish_reason="STOP",
        )
        self.assertEqual(
            gemini_service._finalize_chat_response(response),
            gemini_service.INCOMPLETE_CHAT_REPLY,
        )

    def test_short_complete_reply_is_allowed(self):
        response = _chat_response("확인이 필요해요.")
        self.assertEqual(
            gemini_service._finalize_chat_response(response),
            "확인이 필요해요.",
        )

    def test_max_tokens_retries_once_and_uses_complete_retry(self):
        first = _chat_response(
            "1~2 mg을 사용하지만",
            finish_reason="MAX_TOKENS",
        )
        second = _chat_response(
            "공식 사용량은 1~2 mg이며, 실제 처방 지시를 먼저 따라야 해요."
        )
        client = MagicMock()
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[first, second],
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                client,
                prompt="공식 용량과 조건을 설명하세요.",
            )
        self.assertEqual(
            reply,
            "공식 사용량은 1~2 mg이며, 실제 처방 지시를 먼저 따라야 해요.",
        )
        self.assertEqual(generate.call_count, 2)
        retry_prompt = generate.call_args_list[1].kwargs["contents"]
        self.assertIn("처음부터 다시 작성", retry_prompt)
        self.assertIn("일반 질문은 보통 2~3문장", retry_prompt)
        self.assertIn("주의사항·부작용은 핵심 3~4문장", retry_prompt)
        self.assertIn("약 전체는 확인된 약마다 핵심 1문장", retry_prompt)
        self.assertIn("기계적으로 자르지 마세요", retry_prompt)
        self.assertIn("숫자, 용량, 단위, 횟수, 기간, 연령", retry_prompt)
        self.assertIn("확인하지 못한 약과 실제 검사 범위", retry_prompt)
        self.assertNotIn("1~2 mg을 사용하지만", retry_prompt)
        self.assertEqual(
            generate.call_args_list[0].kwargs["config"]["max_output_tokens"],
            512,
        )
        self.assertEqual(
            generate.call_args_list[1].kwargs["config"]["max_output_tokens"],
            1024,
        )

    def test_max_tokens_retry_can_expand_from_1024_to_2048(self):
        first = _chat_response(
            "공식 주의사항을 설명하지만",
            finish_reason="MAX_TOKENS",
        )
        second = _chat_response(
            "공식 주의사항을 확인했으며, 처방받은 사용 방법을 따라야 해요."
        )
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[first, second],
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="공식 주의사항을 설명하세요.",
                max_output_tokens=1024,
            )

        self.assertEqual(reply, second.text)
        self.assertEqual(
            generate.call_args_list[0].kwargs["config"]["max_output_tokens"],
            1024,
        )
        self.assertEqual(
            generate.call_args_list[1].kwargs["config"]["max_output_tokens"],
            2048,
        )

    def test_second_incomplete_reply_returns_fallback_without_joining(self):
        first = _chat_response("첫 번째 잘린 답변은", finish_reason="MAX_TOKENS")
        second = _chat_response("두 번째 답변도 하지만", finish_reason="STOP")
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[first, second],
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="처음 질문",
            )
        self.assertEqual(generate.call_count, 2)
        self.assertEqual(reply, gemini_service.INCOMPLETE_CHAT_REPLY)
        self.assertNotIn("첫 번째", reply)
        self.assertNotIn("두 번째", reply)

    def test_unbalanced_or_unexplained_jargon_is_rejected(self):
        for text in (
            "공식 조건(만 65세 이상을 확인해야 해요.",
            "QT 연장이 나타날 수 있어요.",
            "이 약은 DUR 결과를 확인했어요.",
        ):
            with self.subTest(text=text):
                self.assertEqual(
                    gemini_service._finalize_chat_response(_chat_response(text)),
                    gemini_service.INCOMPLETE_CHAT_REPLY,
                )

        explained = _chat_response(
            "QT 연장, 즉 심장이 다음 박동을 준비하는 시간이 길어지는 상태를 확인해야 해요."
        )
        self.assertEqual(
            gemini_service._finalize_chat_response(explained),
            "QT 연장, 즉 심장이 다음 박동을 준비하는 시간이 길어지는 상태를 확인해야 해요.",
        )

    def test_jargon_with_adjacent_plain_explanation_passes_without_retry(self):
        replies = (
            "QT 연장(심장이 다음 박동을 준비하는 시간이 길어지는 상태)을 확인해야 해요.",
            "심장이 다음 박동을 준비하는 시간이 길어지는 상태를 QT 연장이라고 해요.",
            "심장이 다음 박동을 준비하는 시간이 길어지는 상태예요. 이를 QT 연장이라고 해요.",
            "QT 연장을 확인해야 해요. 이는 다음 박동을 준비하는 시간이 길어지는 상태예요.",
        )
        for reply in replies:
            with self.subTest(reply=reply):
                client = MagicMock()
                with patch.object(
                    gemini_service,
                    "_generate_content_with_retry",
                    return_value=_chat_response(reply),
                ) as generate:
                    actual = gemini_service._generate_complete_chat_reply(
                        client,
                        prompt="주의사항을 설명하세요.",
                    )
                self.assertEqual(actual, reply)
                self.assertEqual(generate.call_count, 1)

    def test_jargon_is_explained_on_first_occurrence_only(self):
        reply = (
            "고초열(꽃가루 때문에 생기는 알레르기 증상)에 사용할 수 있어요. "
            "고초열에 관한 공식 사용 조건도 함께 확인해 주세요."
        )
        self.assertEqual(
            gemini_service._finalize_chat_response(_chat_response(reply)),
            reply,
        )

    def test_unexplained_hay_fever_retries_once(self):
        first = _chat_response("고초열에 사용할 수 있어요.")
        second = _chat_response(
            "고초열(꽃가루 때문에 생기는 알레르기 증상)에 사용할 수 있어요."
        )
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[first, second],
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="공식 효능을 설명하세요.",
            )
        self.assertEqual(generate.call_count, 2)
        self.assertEqual(reply, second.text)

    def test_unexplained_jargon_retries_once_and_accepts_explained_retry(self):
        first = _chat_response("QT 연장이 나타날 수 있어요.")
        second = _chat_response(
            "QT 연장, 즉 심장이 다음 박동을 준비하는 시간이 길어지는 상태가 나타날 수 있어요."
        )
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[first, second],
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="주의사항을 설명하세요.",
            )
        self.assertEqual(generate.call_count, 2)
        self.assertEqual(reply, second.text)

    def test_still_unexplained_retry_returns_complete_answer(self):
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[
                _chat_response("QT 연장이 나타날 수 있어요."),
                _chat_response("QT 연장을 확인해야 해요."),
            ],
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="주의사항을 설명하세요.",
            )
        self.assertEqual(generate.call_count, 2)
        self.assertEqual(reply, "QT 연장을 확인해야 해요.")

    def test_methotrexate_villus_term_does_not_discard_complete_retry(self):
        first = _chat_response(
            "유한메토트렉세이트정은 융모성 질환 치료에 사용하는 약입니다."
        )
        second = _chat_response(
            "유한메토트렉세이트정은 융모성 질환 치료에 사용하는 약이에요. "
            "치료 중에는 의료진의 검사를 따라야 해요."
        )
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[first, second],
        ) as generate:
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="공식 효능을 설명하세요.",
                required_medicine_names=("유한메토트렉세이트정",),
            )
        self.assertEqual(generate.call_count, 2)
        self.assertEqual(reply, second.text)

    def test_jargon_does_not_override_other_retry_safety_failures(self):
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[
                _chat_response("QT 연장이 나타날 수 있어요."),
                _chat_response("QT 연장은", finish_reason="MAX_TOKENS"),
            ],
        ):
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="주의사항을 설명하세요.",
            )
        self.assertEqual(reply, gemini_service.INCOMPLETE_CHAT_REPLY)

    def test_official_names_are_not_rejected_as_unexplained_jargon(self):
        reply = "아디팜정의 성분은 히드록시진염산염이며 부정맥 병력은 의료진에게 알려 주세요."
        self.assertEqual(
            gemini_service._finalize_chat_response(_chat_response(reply)),
            reply,
        )

    def test_empty_or_repeated_parenthetical_is_not_an_explanation(self):
        for reply in (
            "QT 연장(QT 연장)이 나타날 수 있어요.",
            "QT 연장(주의)이 나타날 수 있어요.",
        ):
            with self.subTest(reply=reply):
                self.assertEqual(
                    gemini_service._finalize_chat_response(_chat_response(reply)),
                    gemini_service.INCOMPLETE_CHAT_REPLY,
                )

    def test_jargon_retry_still_preserves_dose_and_prohibition_conditions(self):
        first = _chat_response("QT 연장은")
        second_text = (
            "QT 연장, 즉 심장이 다음 박동을 준비하는 시간이 길어지는 상태를 확인해야 해요. "
            "만 12세 미만은 사용하면 안 되며, 1~2 mg을 1일 2회 사용한다는 공식 조건은 그대로 확인하세요."
        )
        with patch.object(
            gemini_service,
            "_generate_content_with_retry",
            side_effect=[first, _chat_response(second_text)],
        ):
            reply = gemini_service._generate_complete_chat_reply(
                MagicMock(),
                prompt="공식 조건을 설명하세요.",
            )
        for expected in ("만 12세 미만", "사용하면 안", "1~2 mg", "1일 2회"):
            self.assertIn(expected, reply)

    def test_general_replies_use_plain_explanations(self):
        greeting = general_conversation_reply("안녕하세요")
        capability = general_conversation_reply("무슨 기능이 있어?")
        for reply in (greeting, capability):
            self.assertNotIn("DUR", reply)
            self.assertNotIn("상호작용", reply)
        self.assertIn("약끼리 서로 영향을 주는 경우", greeting)
        self.assertIn("약을 함께 사용할 때의 주의 정보", capability)

    def test_fixed_replies_preserve_missing_stale_and_zero_result_meanings(self):
        zero_type_by_intent = {
            "combination": ["병용금기", "중복성분", "효능군중복"],
            "age": ["연령금기"],
            "pregnancy": ["임부금기"],
            "duplicate": ["중복성분", "효능군중복"],
        }
        for intent in ("combination", "age", "pregnancy", "duplicate"):
            with self.subTest(intent=intent):
                missing = gemini_service._dur_context_unavailable_reply({intent}, "missing")
                stale = gemini_service._dur_context_unavailable_reply({intent}, "stale")
                zero = gemini_service._dur_no_match_reply(
                    {intent},
                    {
                        "status": "current",
                        "items": [],
                        "zero_result_types": zero_type_by_intent[intent],
                        "user_context": {
                            "age_known": intent == "age",
                            "pregnancy_known": intent == "pregnancy",
                            "pregnancy_status": (
                                "pregnant" if intent == "pregnancy" else "unknown"
                            ),
                        },
                    },
                )
                self.assertIn("확인한 결과를 찾지 못했어요", missing)
                self.assertNotIn("복용 중인 약이 바뀌어", missing)
                self.assertIn("복용 중인 약이 바뀌어", stale)
                self.assertIn("이전 결과를 그대로 사용하기 어려워요", stale)
                self.assertTrue(
                    "확인되지 않았어요" in zero or "찾지 못했어요" in zero
                )
                self.assertNotIn("다시 시도", zero)
                self.assertNotIn("안전하다고", zero)
                expected_consultation = (
                    "더 궁금한 점이 있으면 의사나 약사와 상담해 주세요."
                    if intent in {"combination", "duplicate"}
                    else "더 궁금하시면 의사나 약사와 상담해 주세요."
                )
                self.assertIn(expected_consultation, zero)
                for reply in (missing, stale, zero):
                    for jargon in ("DUR", "병용금기", "연령금기", "임부금기", "효능군중복"):
                        self.assertNotIn(jargon, reply)
                    self.assertNotIn("안전합니다", reply)
                    self.assertNotIn("복용해도 됩니다", reply)

    def test_duplicate_incomplete_and_malformed_are_not_described_as_changed(self):
        incomplete = gemini_service._dur_context_unavailable_reply(
            {"duplicate"}, "incomplete"
        )
        malformed = gemini_service._dur_context_unavailable_reply(
            {"duplicate"}, "malformed"
        )

        self.assertIn("끝까지 완료하지 못했어요", incomplete)
        self.assertIn("결과를 확인하지 못했어요", malformed)
        self.assertNotIn("복용 중인 약이 바뀌어", incomplete)
        self.assertNotIn("복용 중인 약이 바뀌어", malformed)
        self.assertNotIn("겹치는 약이 없다고", malformed)

    def test_all_medicine_combination_failure_avoids_single_medicine_wording(self):
        all_medicines = gemini_service._dur_context_unavailable_reply(
            {"combination"},
            "incomplete",
            all_medicines=True,
        )
        selected_medicine = gemini_service._dur_context_unavailable_reply(
            {"combination"},
            "incomplete",
        )

        self.assertIn("현재 복용약 전체", all_medicines)
        self.assertIn("복용 전 의사나 약사와 상담해 주세요.", all_medicines)
        self.assertNotIn("안전하다고 판단할 수 없어요", all_medicines)
        self.assertNotIn("선택한 약", all_medicines)
        self.assertIn("선택한 약", selected_medicine)

    def test_completed_zero_messages_are_specific_to_checked_type_and_scope(self):
        all_combination = gemini_service._dur_no_match_reply(
            {"combination"},
            {
                "status": "current",
                "items": [],
                "zero_result_types": ["병용금기", "중복성분", "효능군중복"],
            },
        )
        selected_combination = gemini_service._dur_no_match_reply(
            {"combination"},
            {
                "status": "current",
                "items": [],
                "zero_result_types": ["병용금기", "중복성분", "효능군중복"],
            },
            selected_medicine={
                "medicine_code": "100",
                "product_name": "등록약정",
            },
        )
        age = gemini_service._dur_no_match_reply(
            {"age"},
            {
                "status": "current",
                "items": [],
                "zero_result_types": ["연령금기"],
                "user_context": {"age_known": True, "pregnancy_known": False},
            },
        )
        pregnancy = gemini_service._dur_no_match_reply(
            {"pregnancy"},
            {
                "status": "current",
                "items": [],
                "zero_result_types": ["임부금기"],
                "user_context": {
                    "age_known": False,
                    "pregnancy_known": True,
                    "pregnancy_status": "pregnant",
                },
            },
        )
        self.assertIn(
            "확인한 약들 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요.",
            all_combination,
        )
        self.assertIn(
            "선택한 약과 지금 드시는 약 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요.",
            selected_combination,
        )
        self.assertIn(
            "확인된 나이를 기준으로, 사용하면 안 되는 약은 확인되지 않았어요.",
            age,
        )
        self.assertIn(
            "임신 중 사용하면 안 되는 약은 확인되지 않았어요.",
            pregnancy,
        )

    def test_missing_age_or_pregnancy_context_is_not_reported_as_zero(self):
        age = gemini_service._dur_no_match_reply(
            {"age"},
            {"status": "current", "items": [], "zero_result_types": []},
        )
        pregnancy = gemini_service._dur_no_match_reply(
            {"pregnancy"},
            {"status": "current", "items": [], "zero_result_types": []},
        )
        self.assertIn("생년월일을 확인할 수 없어", age)
        self.assertNotIn("확인된 나이를 기준으로", age)
        self.assertIn("임신 여부를 확인할 수 없어", pregnancy)
        self.assertNotIn("임신 중 사용하면 안 되는 약은 확인되지 않았어요", pregnancy)
        self.assertIn("복용 전 의사나 약사와 상담해 주세요.", age)
        self.assertIn("복용 전 의사나 약사와 상담해 주세요.", pregnancy)

    def test_not_pregnant_user_does_not_receive_personal_pregnancy_zero_result(self):
        result = {
            "status": "current",
            "items": [],
            "zero_result_types": ["임부금기"],
            "user_context": {
                "pregnancy_known": True,
                "pregnancy_status": "not_pregnant",
            },
        }
        messages = gemini_service._confirmed_zero_messages(
            {"pregnancy"}, result, selected_medicine=None
        )
        reply = gemini_service._dur_no_match_reply({"pregnancy"}, result)
        self.assertEqual(messages, [])
        self.assertIn("현재 임신 중이 아닌 것으로 확인되어", reply)
        self.assertNotIn("임신 중 사용하면 안 되는 약은 확인되지 않았어요", reply)

    def test_incomplete_or_positive_type_never_gets_zero_message(self):
        incomplete = gemini_service._confirmed_zero_messages(
            {"combination"},
            {
                "status": "incomplete",
                "items": [],
                "zero_result_types": [],
            },
            selected_medicine=None,
        )
        positive = gemini_service._confirmed_zero_messages(
            {"combination"},
            {
                "status": "current",
                "items": [{"type": "병용금기"}],
                "zero_result_types": ["중복성분", "효능군중복"],
            },
            selected_medicine=None,
        )
        self.assertEqual(incomplete, [])
        self.assertEqual(positive, [])

    def test_general_conversation_rules_do_not_match_drug_questions(self):
        self.assertIn("안녕하세요", general_conversation_reply("안녕하세요"))
        self.assertIn("도움이 되어", general_conversation_reply("고마워"))
        self.assertIn("식약처 공식정보", general_conversation_reply("무슨 기능이 있어?"))
        self.assertIsNone(general_conversation_reply("이 약 같이 먹어도 돼?"))

    def test_general_rules_and_unselected_safety_question_bypass_gemini(self):
        with patch.object(gemini_service, "GEMINI_API_KEY", None):
            greeting = gemini_service.generate_chat_response("안녕", user_id="U1")
            safety = gemini_service.generate_chat_response("같이 먹어도 돼?", user_id="U1")
        self.assertIn("안녕하세요", greeting)
        self.assertEqual(safety, MEDICINE_SELECTION_REQUIRED_REPLY)
        self.assertNotIn("타이레놀", safety)

        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch.object(gemini_service, "_generate_content_with_retry") as generate,
        ):
            reply = gemini_service.generate_chat_response("감사합니다", user_id="U1")
        self.assertIn("도움이 되어", reply)
        generate.assert_not_called()

    def test_chat_http_exception_is_not_converted_to_generic_reply(self):
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client"),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=HTTPException(status_code=404, detail="사용자가 없습니다."),
            ),
        ):
            with self.assertRaises(HTTPException) as raised:
                gemini_service.generate_chat_response("약 질문", user_id="missing")
        self.assertEqual(raised.exception.status_code, 404)

    def test_chat_general_exception_keeps_generic_fallback(self):
        with (
            patch.object(gemini_service, "GEMINI_API_KEY", "configured"),
            patch("google.genai.Client"),
            patch.object(
                gemini_service,
                "_generate_content_with_retry",
                side_effect=RuntimeError("temporary failure"),
            ),
        ):
            reply = gemini_service.generate_chat_response("약 질문", user_id="U1")
        self.assertIn("지금은 답변을 불러오지 못했어요", reply)
        self.assertIn("사용 방법을 임의로 바꾸지는 마세요", reply)


if __name__ == "__main__":
    unittest.main()
