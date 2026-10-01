import json
import os
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.routes import dur_analysis
from app.services import dur_service


class DurLatestCompatibilityTest(unittest.TestCase):
    def setUp(self):
        handle = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.db_path = handle.name
        handle.close()
        conn = self._connect()
        conn.execute(
            """
            CREATE TABLE risk_results (
                id INTEGER,
                user_id TEXT,
                risk_level TEXT,
                taboo_id INTEGER,
                ingredient_a TEXT,
                ingredient_b TEXT,
                description TEXT,
                analyzed_ingredients TEXT,
                analysis_id TEXT,
                risk_type TEXT,
                total_matches,
                matches_json TEXT,
                created_at TEXT
            )
            """
        )
        conn.commit()
        conn.close()
        self.app = FastAPI()
        self.app.include_router(dur_analysis.router)
        self.client = TestClient(self.app)

    def tearDown(self):
        self.client.close()
        os.unlink(self.db_path)

    def _connect(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _set_row(
        self,
        *,
        ingredients='["성분A"]',
        matches='[{"type":"병용금기","reason":"공식 근거"}]',
        total_matches=1,
        created_at="2026-09-08 12:00:00",
    ):
        conn = self._connect()
        conn.execute("DELETE FROM risk_results")
        conn.execute(
            """
            INSERT INTO risk_results (
                id, user_id, risk_level, analyzed_ingredients, analysis_id,
                risk_type, total_matches, matches_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                1,
                "U1",
                "HIGH",
                ingredients,
                "analysis-1",
                "병용금기",
                total_matches,
                matches,
                created_at,
            ),
        )
        conn.commit()
        conn.close()

    def _get(self):
        with patch.object(dur_service, "get_connection", side_effect=self._connect):
            return self.client.get("/api/v1/users/U1/dur/latest")

    def _assert_degraded(self, response):
        self.assertEqual(200, response.status_code)
        body = response.json()
        self.assertEqual("malformed", body["data_status"])
        self.assertTrue(body["incomplete"])
        self.assertNotIn("특별한 함께먹기 주의는 없어요", body["message"])
        return body

    def test_normal_row_preserves_response_contract(self):
        self._set_row()
        response = self._get()
        self.assertEqual(200, response.status_code)
        body = response.json()
        self.assertEqual(["성분A"], body["analyzed_ingredients"])
        self.assertEqual("병용금기", body["matches"][0]["type"])
        self.assertEqual(1, body["total_matches"])
        self.assertTrue(body["has_risk"])
        self.assertEqual(1, body["by_type"]["병용금기"]["count"])
        self.assertNotIn("incomplete", body)

    def test_normal_zero_matches_is_distinct_from_malformed(self):
        self._set_row(matches="[]", total_matches=0)
        response = self._get()
        self.assertEqual(200, response.status_code)
        body = response.json()
        self.assertFalse(body["has_risk"])
        self.assertEqual(0, body["total_matches"])
        self.assertNotIn("data_status", body)
        self.assertNotIn("incomplete", body)
        self.assertIn("특별한 함께먹기 주의는 없어요", body["message"])

    def test_non_list_matches_are_not_reported_as_safe(self):
        for value in (
            '{"type":"병용금기"}',
            '"병용금기"',
            '{broken-json',
        ):
            with self.subTest(value=value):
                self._set_row(matches=value)
                body = self._assert_degraded(self._get())
                self.assertIsNone(body["has_risk"])
                self.assertEqual([], body["matches"])

    def test_invalid_match_items_are_filtered_and_marked_incomplete(self):
        cases = (
            '["병용금기"]',
            "[null]",
            '[{"reason":"근거"}]',
            '[{"type":null}]',
            '[{"type":""}]',
        )
        for value in cases:
            with self.subTest(value=value):
                self._set_row(matches=value)
                body = self._assert_degraded(self._get())
                self.assertIsNone(body["has_risk"])

    def test_mixed_match_list_retains_only_valid_risk(self):
        value = json.dumps(
            [{"type": "임부금기", "reason": "근거"}, None, {"type": ""}],
            ensure_ascii=False,
        )
        self._set_row(matches=value, total_matches=3)
        body = self._assert_degraded(self._get())
        self.assertTrue(body["has_risk"])
        self.assertEqual(["임부금기"], [item["type"] for item in body["matches"]])

    def test_non_list_ingredients_are_marked_incomplete(self):
        cases = (
            ('{"name":"성분A"}', []),
            ('"성분A"', []),
            ('["성분A", null]', ["성분A"]),
        )
        for value, expected in cases:
            with self.subTest(value=value):
                self._set_row(ingredients=value)
                body = self._assert_degraded(self._get())
                self.assertEqual(expected, body["analyzed_ingredients"])

    def test_invalid_total_matches_is_degraded_without_500(self):
        self._set_row(total_matches="not-a-number")
        body = self._assert_degraded(self._get())
        self.assertEqual(1, body["total_matches"])
        self.assertTrue(body["has_risk"])

    def test_null_created_at_returns_controlled_503(self):
        self._set_row(created_at=None)
        response = self._get()
        self.assertEqual(503, response.status_code)
        self.assertNotEqual(500, response.status_code)

    def test_openapi_documents_latest_runtime_contract(self):
        schema = self.app.openapi()["components"]["schemas"]
        latest = schema["DurLatestResponse"]["properties"]
        for field in (
            "data_status",
            "incomplete",
            "incomplete_reasons",
            "has_risk",
            "message",
            "total_count",
            "by_type",
        ):
            self.assertIn(field, latest)

        has_risk_types = {item.get("type") for item in latest["has_risk"]["anyOf"]}
        self.assertEqual({"boolean", "null"}, has_risk_types)

        reasons_variants = latest["incomplete_reasons"]["anyOf"]
        reasons_array = next(item for item in reasons_variants if item.get("type") == "array")
        self.assertEqual("string", reasons_array["items"]["type"])
        self.assertIn("null", {item.get("type") for item in reasons_variants})

        by_type_variants = latest["by_type"]["anyOf"]
        by_type_object = next(item for item in by_type_variants if item.get("type") == "object")
        self.assertEqual(
            "#/components/schemas/DurTypeGroupResponse",
            by_type_object["additionalProperties"]["$ref"],
        )
        group = schema["DurTypeGroupResponse"]["properties"]
        self.assertEqual("integer", group["count"]["type"])
        self.assertEqual("array", group["items"]["type"])
        self.assertEqual(
            "#/components/schemas/DurMatchResponse",
            group["items"]["items"]["$ref"],
        )


if __name__ == "__main__":
    unittest.main()
