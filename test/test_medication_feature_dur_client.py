import unittest
from unittest.mock import Mock, patch

import requests

from app.models.schemas import DurAnalyzeRequest
from app.routes import dur_analysis
from app.services import medication_feature_dur_client as remote_dur


class MedicationFeatureDurClientTest(unittest.TestCase):
    selected = {"medicine_code": "100", "product_name": "등록약정"}

    @staticmethod
    def response(payload, *, status_code=200):
        response = Mock()
        response.json.return_value = payload
        response.raise_for_status.return_value = None
        response.status_code = status_code
        return response

    def medicines(self):
        return {
            "medicines": [
                {
                    "medicine_code": "100",
                    "product_name": "등록약정",
                    "status": "active",
                }
            ]
        }

    def call(self):
        return remote_dur.load_remote_combination_context(
            user_id="user-1",
            selected_medicine=self.selected,
        )

    def test_risk_result_uses_medication_service_only(self):
        match = {
            "type": "병용금기",
            "medicine_codes_a": ["100"],
            "medicine_codes_b": ["200"],
            "reason": "1~2 mg 조건에서 주의",
        }
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())) as get,
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "RISK_FOUND",
                        "analysis_complete": True,
                        "incomplete": False,
                        "has_risk": True,
                        "matches": [match],
                        "medicine_names": ["등록약정"],
                    }
                ),
            ) as post,
        ):
            result = self.call()
        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"], [match])
        self.assertNotIn("병용금기", result["zero_result_types"])
        self.assertIn("중복성분", result["zero_result_types"])
        self.assertIn("/api/v1/users/user-1/medicines", get.call_args.args[0])
        self.assertEqual(
            post.call_args.kwargs["json"],
            {
                "user_id": "user-1",
                "medicine_codes": ["100"],
                "medicine_names_by_code": {"100": "등록약정"},
            },
        )

    def test_completed_zero_result_is_current_not_incomplete(self):
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "SAFE",
                        "analysis_complete": True,
                        "incomplete": False,
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": ["등록약정"],
                    }
                ),
            ),
        ):
            result = self.call()
        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"], [])
        self.assertFalse(result["has_risk"])
        self.assertEqual(
            set(result["zero_result_types"]),
            {"병용금기", "중복성분", "효능군중복"},
        )

    def test_unrelated_incomplete_type_does_not_fail_completed_combination_scope(self):
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "INCOMPLETE",
                        "analysis_complete": False,
                        "incomplete": True,
                        "incomplete_types": ["연령금기"],
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": ["등록약정"],
                    }
                ),
            ),
        ):
            result = remote_dur.load_remote_combination_context(
                user_id="user-1",
                selected_medicine=None,
                requested_types={"병용금기", "중복성분", "효능군중복"},
            )

        self.assertEqual(result["status"], "current")
        self.assertFalse(result["has_risk"])

    def test_relevant_incomplete_type_remains_incomplete(self):
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "INCOMPLETE",
                        "analysis_complete": False,
                        "incomplete": True,
                        "incomplete_types": ["병용금기"],
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": ["등록약정"],
                    }
                ),
            ),
        ):
            result = remote_dur.load_remote_combination_context(
                user_id="user-1",
                selected_medicine=None,
                requested_types={"병용금기"},
            )

        self.assertEqual(result["status"], "incomplete")
        self.assertIsNone(result["has_risk"])

    def test_incomplete_is_never_safe(self):
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "INCOMPLETE",
                        "analysis_complete": False,
                        "incomplete": True,
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": ["등록약정"],
                    }
                ),
            ),
        ):
            result = self.call()
        self.assertEqual(result["status"], "incomplete")
        self.assertIsNone(result["has_risk"])

    def test_incomplete_flag_is_never_safe_even_if_other_fields_say_complete(self):
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "SAFE",
                        "analysis_complete": True,
                        "incomplete": True,
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": ["등록약정"],
                    }
                ),
            ),
        ):
            result = self.call()
        self.assertEqual(result["status"], "incomplete")
        self.assertIsNone(result["has_risk"])

    def test_found_risk_with_incomplete_assessment_is_not_reported_as_complete(self):
        match = {
            "type": "병용금기",
            "medicine_codes_a": ["100"],
            "medicine_codes_b": ["200"],
            "reason": "확인된 주의 조합",
        }
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "RISK_FOUND",
                        "analysis_complete": False,
                        "incomplete": True,
                        "has_risk": True,
                        "matches": [match],
                        "medicine_names": ["등록약정"],
                    }
                ),
            ),
        ):
            result = self.call()

        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["items"], [])
        self.assertIsNone(result["has_risk"])

    def test_timeout_http_and_malformed_are_not_safe(self):
        failures = [
            requests.Timeout("timeout"),
            requests.HTTPError("503"),
        ]
        for failure in failures:
            with (
                self.subTest(failure=type(failure).__name__),
                patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
                patch.object(remote_dur.requests, "get", side_effect=failure),
            ):
                result = self.call()
                self.assertNotEqual(result["status"], "current")
                self.assertIsNone(result["has_risk"])

        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
            patch.object(remote_dur.requests, "post", return_value=self.response({"assessment_status": "SAFE"})),
        ):
            result = self.call()
        self.assertEqual(result["status"], "malformed")
        self.assertIsNone(result["has_risk"])

    def test_dur_analysis_timeout_is_not_zero_result(self):
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
            patch.object(remote_dur.requests, "post", side_effect=requests.Timeout("timeout")),
        ):
            result = self.call()

        self.assertEqual(result["status"], "missing")
        self.assertEqual(result["reason"], "dur_service_unavailable")
        self.assertIsNone(result["has_risk"])

    def test_missing_or_mismatched_selected_identity_stops_before_analysis(self):
        for selected in (
            {"medicine_code": "", "product_name": "등록약정"},
            {"medicine_code": "999", "product_name": "등록약정"},
            {"medicine_code": "100", "product_name": "다른약정"},
        ):
            with (
                self.subTest(selected=selected),
                patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
                patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
                patch.object(remote_dur.requests, "post") as post,
            ):
                result = remote_dur.load_remote_combination_context(
                    user_id="user-1",
                    selected_medicine=selected,
                )
                self.assertEqual(result["status"], "missing")
                post.assert_not_called()

    def test_all_medicines_uses_active_ocr_and_manual_rows_for_one_dur_analysis(self):
        medicines = {
            "medicines": [
                {"medicine_code": "100", "official_product_name": "OCR등록약정", "status": "active"},
                {"medicine_code": "200", "product_name": "손입력약정", "status": "active"},
                {"medicine_code": "300", "product_name": "지난약정", "status": "inactive"},
            ]
        }
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(medicines)),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "SAFE",
                        "analysis_complete": True,
                        "incomplete": False,
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": ["OCR등록약정", "손입력약정"],
                    }
                ),
            ) as post,
        ):
            result = remote_dur.load_remote_combination_context(
                user_id="user-1",
                selected_medicine=None,
            )
        self.assertEqual(result["status"], "current")
        self.assertFalse(result["has_risk"])
        post.assert_called_once()
        self.assertEqual(
            post.call_args.kwargs["json"],
            {
                "user_id": "user-1",
                "medicine_codes": ["100", "200"],
                "medicine_names_by_code": {
                    "100": "OCR등록약정",
                    "200": "손입력약정",
                },
            },
        )

    def test_explicit_only_scope_skips_registered_medicine_lookup(self):
        explicit = [
            {"medicine_code": "101", "product_name": "첫째약정"},
            {"medicine_code": "202", "product_name": "둘째약정"},
        ]
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get") as get,
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "SAFE",
                        "analysis_complete": True,
                        "incomplete": False,
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": ["첫째약정", "둘째약정"],
                    }
                ),
            ) as post,
        ):
            result = remote_dur.load_remote_combination_context(
                user_id="user-1",
                selected_medicine=None,
                additional_medicines=explicit,
                include_current_medicines=False,
            )

        get.assert_not_called()
        self.assertEqual(result["status"], "current")
        self.assertFalse(result["has_risk"])
        self.assertEqual(
            post.call_args.kwargs["json"],
            {
                "user_id": "user-1",
                "medicine_codes": ["101", "202"],
                "medicine_names_by_code": {
                    "101": "첫째약정",
                    "202": "둘째약정",
                },
            },
        )

    def test_explicit_ai_scope_runs_live_reference_lookup(self):
        request = DurAnalyzeRequest(
            user_id="user-1",
            medicine_codes=["100", "200"],
        )
        with patch.object(dur_analysis, "analyze_dur", return_value={}) as analyze:
            dur_analysis.analyze(request)

        analyze.assert_called_once_with(request, refresh=True)

    def test_registered_medicine_screen_keeps_stored_reference_path(self):
        request = DurAnalyzeRequest(user_id="user-1")
        with patch.object(dur_analysis, "analyze_dur", return_value={}) as analyze:
            dur_analysis.analyze(request)

        analyze.assert_called_once_with(request, refresh=False)

    def test_temporary_medicine_is_combined_with_registered_scope(self):
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(
                remote_dur.requests,
                "get",
                return_value=self.response(self.medicines()),
            ),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "SAFE",
                        "analysis_complete": True,
                        "incomplete": False,
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": ["등록약정", "화면임시약정"],
                    }
                ),
            ) as post,
        ):
            result = remote_dur.load_remote_combination_context(
                user_id="user-1",
                selected_medicine=None,
                additional_medicines=[
                    {"medicine_code": "200", "product_name": "화면임시약정"}
                ],
            )

        self.assertEqual(result["status"], "current")
        self.assertEqual(
            post.call_args.kwargs["json"],
            {
                "user_id": "user-1",
                "medicine_codes": ["100", "200"],
                "medicine_names_by_code": {
                    "100": "등록약정",
                    "200": "화면임시약정",
                },
            },
        )

    def test_missing_temporary_medicine_from_dur_scope_is_incomplete(self):
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(
                remote_dur.requests,
                "get",
                return_value=self.response(self.medicines()),
            ),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "SAFE",
                        "analysis_complete": True,
                        "incomplete": False,
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": ["등록약정"],
                    }
                ),
            ),
        ):
            result = remote_dur.load_remote_combination_context(
                user_id="user-1",
                selected_medicine=None,
                additional_medicines=[
                    {"medicine_code": "200", "product_name": "화면임시약정"}
                ],
            )

        self.assertEqual(result["status"], "incomplete")
        self.assertIsNone(result["has_risk"])
        self.assertEqual(result["reason"], "medicine_analysis_scope_incomplete")

    def test_missing_registered_medicine_from_dur_scope_is_incomplete(self):
        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", return_value=self.response(self.medicines())),
            patch.object(
                remote_dur.requests,
                "post",
                return_value=self.response(
                    {
                        "assessment_status": "SAFE",
                        "analysis_complete": True,
                        "incomplete": False,
                        "has_risk": False,
                        "matches": [],
                        "medicine_names": [],
                    }
                ),
            ),
        ):
            result = self.call()

        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["reason"], "medicine_analysis_scope_incomplete")
        self.assertIsNone(result["has_risk"])

    def test_all_medicines_distinguishes_empty_failure_and_incomplete_identity(self):
        cases = (
            ({"medicines": []}, "empty"),
            ({"medicines": [{"medicine_code": "100", "status": "active"}]}, "incomplete"),
            (
                {
                    "medicines": [
                        {"medicine_code": "100", "product_name": "첫이름", "status": "active"},
                        {"medicine_code": "100", "product_name": "다른이름", "status": "active"},
                    ]
                },
                "incomplete",
            ),
        )
        for payload, expected_status in cases:
            with (
                self.subTest(expected_status=expected_status),
                patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
                patch.object(remote_dur.requests, "get", return_value=self.response(payload)),
                patch.object(remote_dur.requests, "post") as post,
            ):
                result = remote_dur.load_remote_combination_context(
                    user_id="user-1",
                    selected_medicine=None,
                )
                self.assertEqual(result["status"], expected_status)
                self.assertIsNone(result["has_risk"])
                post.assert_not_called()

        with (
            patch.object(remote_dur, "MEDICATION_FEATURE_BASE_URL", "https://med.example"),
            patch.object(remote_dur.requests, "get", side_effect=requests.Timeout("timeout")),
        ):
            result = remote_dur.load_remote_combination_context(
                user_id="user-1",
                selected_medicine=None,
            )
        self.assertEqual(result["status"], "missing")
        self.assertEqual(result["reason"], "medication_service_unavailable")


if __name__ == "__main__":
    unittest.main()
