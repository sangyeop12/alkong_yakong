import unittest
from unittest.mock import patch

import requests
from fastapi import HTTPException

from app.routes.dashboard import lookup_medicines
from app.routes.drug_explain import search_official_drugs
from app.services import external_api_service
from app.services.mfds_drug_permission import client as permission_client


def _item(name: str, manufacturer: str, sequence: str | None) -> dict:
    return {"itemName": name, "entpName": manufacturer, "itemSeq": sequence}


def _permission_item(name: str, manufacturer: str, sequence: str) -> dict:
    return {"ITEM_NAME": name, "ENTP_NAME": manufacturer, "ITEM_SEQ": sequence}


class DrugCandidateSearchTest(unittest.TestCase):
    def setUp(self):
        external_api_service._drug_search_cache.clear()

    def search(
        self,
        query: str,
        items: list[dict],
        permission_items: list[dict] | None = None,
    ) -> dict:
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                return_value=items,
            ) as request_items,
            patch.object(
                external_api_service.permission_client,
                "search_permission_products",
                return_value=permission_items or [],
            ) as permission_search,
        ):
            result = external_api_service.search_drug_candidates(query)
        request_items.assert_called_once_with(
            query,
            page_no=1,
            num_of_rows=16,
            timeout=external_api_service.DRUG_SEARCH_TIMEOUT_SECONDS,
        )
        if items:
            permission_search.assert_not_called()
        else:
            permission_search.assert_called_once_with(
                query,
                limit=16,
                timeout=external_api_service.DRUG_SEARCH_TIMEOUT_SECONDS,
            )
        return result

    def test_gevourin_returns_multiple_official_candidates(self):
        result = self.search(
            "게보",
            [
                _item("게보린릴랙스연질캡슐", "제조사B", "2"),
                _item("게보린정", "삼진제약(주)", "1"),
                _item("게보린소프트연질캡슐", "제조사C", "3"),
            ],
        )
        self.assertEqual(result["count"], 3)
        self.assertEqual(
            [item["item_name"] for item in result["items"]],
            ["게보린정", "게보린릴랙스연질캡슐", "게보린소프트연질캡슐"],
        )

    def test_acamprosate_returns_multiple_official_candidates(self):
        result = self.search(
            "아캄",
            [
                _item("환인아캄프로세이트정", "환인제약", "10"),
                _item("명인아캄프로세이트정333mg", "명인제약", "11"),
            ],
        )
        self.assertEqual(result["count"], 2)
        self.assertEqual(
            {item["item_name"] for item in result["items"]},
            {"환인아캄프로세이트정", "명인아캄프로세이트정333mg"},
        )

    def test_one_character_is_rejected_before_external_request(self):
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(external_api_service, "_request_drug_items") as request_items,
            self.assertRaises(HTTPException) as raised,
        ):
            external_api_service.search_drug_candidates("게")
        self.assertEqual(raised.exception.status_code, 422)
        request_items.assert_not_called()

    def test_blank_query_is_rejected(self):
        with self.assertRaises(HTTPException) as raised:
            search_official_drugs("  ")
        self.assertEqual(raised.exception.status_code, 422)

    def test_no_official_result_returns_empty_items(self):
        result = self.search("없는약", [])
        self.assertEqual(result, {"query": "없는약", "count": 0, "items": []})

    def test_official_database_error_returns_retryable_service_error(self):
        with patch(
            "app.services.mfds_drug_permission.db.search_permission_names",
            side_effect=RuntimeError("permission database unavailable"),
        ):
            with self.assertRaises(HTTPException) as raised:
                lookup_medicines("아디팜")
        self.assertEqual(raised.exception.status_code, 503)
        self.assertIn("다시 시도", raised.exception.detail)

    def test_candidate_results_are_limited_to_eight(self):
        result = self.search(
            "테스트",
            [
                _item(f"테스트약{i}정", f"제조사{i}", str(i))
                for i in range(10)
            ],
        )
        self.assertEqual(result["count"], 8)
        self.assertEqual(len(result["items"]), 8)

    def test_timeout_is_mapped_to_safe_gateway_timeout(self):
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                side_effect=requests.Timeout,
            ),
            patch.object(
                external_api_service.permission_client,
                "search_permission_products",
                side_effect=RuntimeError,
            ),
            self.assertRaises(HTTPException) as raised,
        ):
            external_api_service.search_drug_candidates("게보")
        self.assertEqual(raised.exception.status_code, 504)

    def test_successful_result_is_served_from_cache(self):
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                return_value=[_item("게보린정", "삼진제약", "1")],
            ) as request_items,
        ):
            first = external_api_service.search_drug_candidates(" 게보 ")
            second = external_api_service.search_drug_candidates("게보")

        self.assertEqual(first, second)
        request_items.assert_called_once()

    def test_expired_cache_calls_external_api_again(self):
        clock = iter((100.0, 100.0, 100.0, 146.0, 146.0, 146.0))
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(external_api_service.time, "monotonic", side_effect=clock),
            patch.object(
                external_api_service,
                "_request_drug_items",
                return_value=[_item("게보린정", "삼진제약", "1")],
            ) as request_items,
        ):
            external_api_service.search_drug_candidates("게보")
            external_api_service.search_drug_candidates("게보")

        self.assertEqual(request_items.call_count, 2)

    def test_timeout_is_not_cached(self):
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                side_effect=[requests.Timeout, [_item("게보린정", "삼진제약", "1")]],
            ) as request_items,
            patch.object(
                external_api_service.permission_client,
                "search_permission_products",
                side_effect=RuntimeError,
            ),
        ):
            with self.assertRaises(HTTPException):
                external_api_service.search_drug_candidates("게보")
            result = external_api_service.search_drug_candidates("게보")

        self.assertEqual(result["count"], 1)
        self.assertEqual(request_items.call_count, 2)

    def test_successful_empty_result_keeps_empty_response_semantics(self):
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(external_api_service, "_request_drug_items", return_value=[]),
            patch.object(
                external_api_service.permission_client,
                "search_permission_products",
                return_value=[],
            ),
        ):
            result = external_api_service.search_drug_candidates("없는약")

        self.assertEqual(result, {"query": "없는약", "count": 0, "items": []})

    def test_permission_result_supplements_empty_e_drug_result(self):
        result = self.search(
            "메토트렉세이트",
            [],
            [_permission_item("유한메토트렉세이트정", "유한양행", "100")],
        )
        self.assertEqual(
            result["items"],
            [
                {
                    "item_name": "유한메토트렉세이트정",
                    "manufacturer": "유한양행",
                    "item_seq": "100",
                }
            ],
        )

    def test_duplicate_e_drug_item_without_sequence_is_deduplicated(self):
        result = self.search(
            "아스피린",
            [
                _item("아스피린정", "e약 제조사", None),
                _item("아스피린정", "e약 제조사", None),
            ],
        )
        self.assertEqual(result["count"], 1)

    def test_duplicate_e_drug_item_with_blank_sequence_is_deduplicated(self):
        result = self.search(
            "아스피린",
            [
                _item("아스피린정", "e약 제조사", ""),
                _item("아스피린정", "e약 제조사", ""),
            ],
        )
        self.assertEqual(result["count"], 1)

    def test_different_item_sequences_are_not_deduplicated_by_name(self):
        result = self.search(
            "아스피린",
            [
                _item("아스피린정", "제조사A", "200"),
                _item("아스피린정", "제조사B", "201"),
            ],
        )
        self.assertEqual(result["count"], 2)
        self.assertEqual(
            {item["item_seq"] for item in result["items"]},
            {"200", "201"},
        )

    def test_permission_failure_keeps_e_drug_results(self):
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                return_value=[_item("게보린정", "삼진제약", "1")],
            ),
            patch.object(
                external_api_service.permission_client,
                "search_permission_products",
                side_effect=requests.Timeout,
            ) as permission_search,
        ):
            result = external_api_service.search_drug_candidates("게보")
        permission_search.assert_not_called()
        self.assertEqual(result["count"], 1)
        self.assertEqual(result["items"][0]["item_seq"], "1")

    def test_e_drug_failure_returns_permission_results(self):
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                side_effect=requests.Timeout,
            ),
            patch.object(
                external_api_service.permission_client,
                "search_permission_products",
                return_value=[_permission_item("알프람정", "환인제약", "300")],
            ),
        ):
            result = external_api_service.search_drug_candidates("알프람")
        self.assertEqual(result["count"], 1)
        self.assertEqual(result["items"][0]["item_name"], "알프람정")

    def test_permission_search_uses_official_product_name_parameter(self):
        payload = {
            "body": {
                "items": [
                    _permission_item("알프람정", "환인제약", "300"),
                ]
            }
        }
        with patch.object(
            permission_client,
            "fetch_permission_list_page",
            return_value=payload,
        ) as fetch_page:
            result = permission_client.search_permission_products(
                "알프람",
                limit=16,
                timeout=10,
            )

        fetch_page.assert_called_once_with(
            page_no=1,
            num_of_rows=16,
            item_name="알프람",
            timeout=10,
        )
        self.assertEqual(result[0]["ITEM_SEQ"], "300")

    def test_permission_fallback_still_respects_eight_item_limit(self):
        result = self.search(
            "테스트",
            [],
            [
                _permission_item(f"테스트보완{i}정", "보완", str(i + 10))
                for i in range(10)
            ],
        )
        self.assertEqual(result["count"], 8)
        self.assertEqual(len(result["items"]), 8)

    def test_unrelated_permission_result_is_excluded(self):
        result = self.search(
            "알프람",
            [],
            [
                _permission_item("알프람정", "환인제약", "1"),
                _permission_item("무관한정", "다른제약", "2"),
            ],
        )
        self.assertEqual(result["count"], 1)
        self.assertEqual(result["items"][0]["item_name"], "알프람정")

    def test_existing_e_drug_searches_remain_available(self):
        for query, product_name, item_seq in (
            ("게보", "게보린정", "1"),
            ("알마겔", "알마겔정", "2"),
            ("아스피린", "아스피린정", "3"),
        ):
            with self.subTest(query=query):
                result = self.search(
                    query,
                    [_item(product_name, "기존 제조사", item_seq)],
                )
                self.assertEqual(result["count"], 1)
                self.assertEqual(result["items"][0]["item_name"], product_name)

    def test_exact_product_name_wins_over_similar_products(self):
        items = [
            _item("게보린릴랙스연질캡슐", "제조사B", "2"),
            _item("게보린정", "삼진제약(주)", "1"),
        ]
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                return_value=items,
            ),
        ):
            result = external_api_service.search_drug_info_by_name("게보린정")

        self.assertEqual(result["match_type"], "exact")
        self.assertEqual(
            [item["product_name"] for item in result["items"]],
            ["게보린정"],
        )

    def test_main_product_name_only_contract_is_preserved(self):
        items = [
            _item("게보린정", "삼진제약(주)", "1"),
            _item("게보린릴랙스연질캡슐", "제조사B", "2"),
        ]
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                return_value=items,
            ) as request_items,
        ):
            result = external_api_service.search_drug_info_by_name(
                "게보린",
                product_name_only=True,
            )

        request_items.assert_called_once_with("게보린", page_no=1, num_of_rows=10)
        self.assertEqual(result["match_type"], "product_name")
        self.assertEqual(result["count"], 2)

    def test_unique_best_rank_is_selected_over_lower_rank_candidates(self):
        items = [
            _item("게보린정", "삼진제약(주)", "1"),
            _item("게보린릴랙스연질캡슐", "제조사B", "2"),
            _item("게보린소프트연질캡슐", "제조사C", "3"),
        ]
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                return_value=items,
            ),
        ):
            result = external_api_service.search_drug_info_by_name("게보린")

        self.assertEqual(result["match_type"], "partial")
        self.assertEqual(
            [item["product_name"] for item in result["items"]],
            ["게보린정"],
        )

    def test_equal_best_rank_candidates_are_ambiguous(self):
        items = [
            _item("환인아캄프로세이트정", "환인제약", "10"),
            _item("명인아캄프로세이트정333mg", "명인제약", "11"),
        ]
        with (
            patch.object(external_api_service, "E_DRUG_API_KEY", "test-key"),
            patch.object(
                external_api_service,
                "_request_drug_items",
                side_effect=[[], items],
            ),
        ):
            result = external_api_service.search_drug_info_by_name(
                "아캄프로세이트정"
            )

        self.assertEqual(result["match_type"], "ambiguous")
        self.assertEqual(result["count"], 2)


if __name__ == "__main__":
    unittest.main()
