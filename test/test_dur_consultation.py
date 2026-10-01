import os
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from app.services import dur_service


class DurConsultationTest(unittest.TestCase):
    def setUp(self):
        handle = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.db_path = handle.name
        handle.close()
        conn = self._connect()
        conn.executescript(
            """
            CREATE TABLE users (
                id TEXT PRIMARY KEY,
                birth_date TEXT,
                gender TEXT,
                is_pregnant INTEGER
            );
            CREATE TABLE medicines (
                medicine_code TEXT PRIMARY KEY,
                product_name TEXT,
                ingredient TEXT
            );
            CREATE TABLE user_medicines (
                id INTEGER PRIMARY KEY,
                user_id TEXT,
                medicine_code TEXT,
                is_active INTEGER
            );
            CREATE TABLE risk_results (
                id INTEGER PRIMARY KEY,
                user_id TEXT,
                risk_level TEXT,
                description TEXT,
                analyzed_ingredients TEXT,
                analysis_id TEXT,
                risk_type TEXT,
                total_matches INTEGER,
                matches_json TEXT,
                assessment_status TEXT,
                incomplete_reasons_json TEXT,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            );
            CREATE TABLE dur_taboo (
                id INTEGER PRIMARY KEY,
                ingredient_a TEXT NOT NULL,
                ingredient_b TEXT,
                taboo_type TEXT NOT NULL,
                severity TEXT NOT NULL,
                description TEXT NOT NULL,
                source TEXT,
                external_id TEXT,
                ingredient_a_code TEXT,
                ingredient_b_code TEXT,
                min_age INTEGER,
                max_age INTEGER,
                pregnancy_grade TEXT,
                notification_date TEXT,
                raw_json TEXT,
                updated_at TEXT,
                created_at TEXT
            );
            INSERT INTO users VALUES ('U1', '1950-01-01', 'F', 1);
            INSERT INTO medicines VALUES ('A', 'Drug A', 'ingredienta');
            INSERT INTO medicines VALUES ('B', 'Drug B', 'ingredientb');
            INSERT INTO user_medicines VALUES (1, 'U1', 'A', 1);
            INSERT INTO user_medicines VALUES (2, 'U1', 'B', 1);
            INSERT INTO risk_results (id, user_id, risk_level, description)
            VALUES (1, 'U1', 'LOW', 'existing');
            """
        )
        conn.commit()
        conn.close()

    def tearDown(self):
        os.unlink(self.db_path)

    def _connect(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _analyze(self, selected, risk_types, *, sync_result=None, user_id="U1"):
        sync_result = sync_result or {"status": "ok", "fetched": 0, "upserted": 0}
        with (
            patch.object(dur_service, "get_connection", side_effect=self._connect),
            patch(
                "app.services.dur_sync_service.refresh_dur_for_ingredients",
                return_value=sync_result,
            ),
        ):
            return dur_service.analyze_dur_consultation(
                user_id=user_id,
                selected_medicine=selected,
                risk_types=risk_types,
            )

    def _snapshot(self):
        conn = self._connect()
        try:
            return (
                [tuple(row) for row in conn.execute("SELECT * FROM user_medicines ORDER BY id")],
                [tuple(row) for row in conn.execute("SELECT * FROM risk_results ORDER BY id")],
            )
        finally:
            conn.close()

    def test_combination_only_returns_matches_involving_selected_medicine(self):
        conn = self._connect()
        conn.executemany(
            """
            INSERT INTO dur_taboo (
                ingredient_a, ingredient_b, taboo_type, severity,
                description, source, external_id
            ) VALUES (?, ?, '병용금기', 'HIGH', ?, 'official', ?)
            """,
            [
                ("ingredientc", "ingredientb", "C and B", "C-B"),
                ("ingredienta", "ingredientb", "A and B", "A-B"),
            ],
        )
        conn.commit()
        conn.close()
        before = self._snapshot()

        with self.assertLogs(dur_service.logger, level="WARNING") as captured:
            result = self._analyze(
                {
                    "medicine_code": "C",
                    "product_name": "Drug C",
                    "ingredient": "ingredientc",
                },
                {"병용금기"},
                sync_result={"status": "ok", "fetched": 5, "upserted": 2},
            )

        self.assertEqual(result["status"], "current")
        self.assertEqual(
            set(result),
            {
                "status",
                "items",
                "scope",
                "reason",
                "checked_types",
                "zero_result_types",
                "user_context",
            },
        )
        self.assertEqual(result["checked_types"], ["병용금기"])
        self.assertEqual(result["zero_result_types"], [])
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual(result["items"][0]["external_id"], "C-B")
        self.assertEqual(self._snapshot(), before)
        output = "\n".join(captured.output)
        self.assertIn("sync_fetched_count=5", output)
        self.assertIn("sync_upserted_count=2", output)
        self.assertIn("taboo_selected_ingredient_count=1", output)
        self.assertIn("duplicate_candidate_count=0", output)
        self.assertIn("official_candidate_count=2", output)
        self.assertIn("efficacy_duplicate_candidate_count=0", output)
        self.assertIn("requested_type_filtered_count=2", output)
        self.assertIn("consultation_relevance_before_count=2", output)
        self.assertIn("consultation_relevance_after_count=1", output)
        self.assertIn("final_match_count=1", output)
        self.assertNotIn("U1", output)
        self.assertNotIn("Drug C", output)
        self.assertNotIn("ingredientc", output)

    def test_duplicate_includes_selected_without_persisting_it(self):
        before = self._snapshot()
        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredienta",
            },
            {"중복성분"},
        )
        self.assertEqual(result["status"], "current")
        self.assertEqual([item["type"] for item in result["items"]], ["중복성분"])
        self.assertIn("Drug C", result["items"][0]["medicine_names_a"])
        self.assertEqual(self._snapshot(), before)

    def test_compound_selected_medicine_keeps_both_related_pairs(self):
        conn = self._connect()
        conn.executemany(
            """
            INSERT INTO dur_taboo (
                ingredient_a, ingredient_b, taboo_type, severity,
                description, source, external_id
            ) VALUES (?, ?, '병용금기', 'HIGH', ?, 'official', ?)
            """,
            [
                ("ingredienta", "ingredientc1", "A-C1", "A-C1"),
                ("ingredientb", "ingredientc2", "B-C2", "B-C2"),
                ("ingredienta", "ingredientb", "A-B", "A-B"),
            ],
        )
        conn.commit()
        conn.close()

        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc1|ingredientc2",
            },
            {"병용금기"},
        )

        self.assertEqual(
            {item["external_id"] for item in result["items"]},
            {"A-C1", "B-C2"},
        )

    def test_compound_selected_medicine_detects_non_primary_duplicate(self):
        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc|ingredientb",
            },
            {"중복성분"},
        )
        self.assertEqual([item["type"] for item in result["items"]], ["중복성분"])
        self.assertIn("Drug C", result["items"][0]["medicine_names_a"])

    def test_sync_success_with_zero_matches_is_current(self):
        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"연령금기"},
        )
        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"], [])

    def test_sync_failure_is_missing_even_with_unrelated_cached_rows(self):
        conn = self._connect()
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, taboo_type, severity, description, source, external_id
            ) VALUES ('unrelated', '연령금기', 'MEDIUM', 'unrelated', 'official', 'other')
            """
        )
        conn.commit()
        conn.close()

        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"연령금기"},
            sync_result={"status": "failed", "fetched": 0, "upserted": 0},
        )
        self.assertEqual(result["status"], "missing")
        self.assertEqual(result["reason"], "dur_data_unavailable")

    def test_efficacy_duplicate_uses_structured_selected_code(self):
        conn = self._connect()
        conn.executemany(
            """
            INSERT INTO dur_taboo (
                ingredient_a, ingredient_b, taboo_type, severity,
                description, source, external_id
            ) VALUES (?, 'GROUP-1', '효능군중복', 'HIGH', ?, 'official', ?)
            """,
            [
                ("ingredienta", "A group", "GROUP-A"),
                ("ingredientc", "C group", "GROUP-C"),
            ],
        )
        conn.commit()
        conn.close()

        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"효능군중복"},
        )
        self.assertEqual([item["type"] for item in result["items"]], ["효능군중복"])
        self.assertNotIn("_medicine_codes", result["items"][0])

    def test_missing_birth_date_still_returns_official_age_criteria(self):
        conn = self._connect()
        conn.execute("UPDATE users SET birth_date = NULL WHERE id = 'U1'")
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, taboo_type, severity, description, source,
                external_id, max_age
            ) VALUES ('ingredientc', '연령금기', 'MEDIUM', 'under 12',
                      'official', 'AGE-C', 11)
            """
        )
        conn.commit()
        conn.close()
        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"연령금기"},
        )
        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"][0]["external_id"], "AGE-C")
        self.assertEqual(result["items"][0]["user_applicability"], "unknown")

    def test_age_not_applicable_still_returns_official_criteria(self):
        conn = self._connect()
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, taboo_type, severity, description, source,
                external_id, max_age
            ) VALUES ('ingredientc', '연령금기', 'MEDIUM', 'under 12',
                      'official', 'AGE-C', 11)
            """
        )
        conn.commit()
        conn.close()
        result = self._analyze(
            {"medicine_code": "C", "product_name": "Drug C", "ingredient": "ingredientc"},
            {"연령금기"},
        )
        self.assertEqual(result["items"][0]["user_applicability"], "not_applicable")

    def test_age_applicable_returns_official_criteria(self):
        conn = self._connect()
        conn.execute("UPDATE users SET birth_date = '2020-01-01' WHERE id = 'U1'")
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, taboo_type, severity, description, source,
                external_id, max_age
            ) VALUES ('ingredientc', '연령금기', 'MEDIUM', 'under 12',
                      'official', 'AGE-C', 11)
            """
        )
        conn.commit()
        conn.close()
        result = self._analyze(
            {"medicine_code": "C", "product_name": "Drug C", "ingredient": "ingredientc"},
            {"연령금기"},
        )
        self.assertEqual(result["items"][0]["user_applicability"], "applicable")

    def test_combination_does_not_require_birth_date(self):
        conn = self._connect()
        conn.execute("UPDATE users SET birth_date = NULL WHERE id = 'U1'")
        conn.commit()
        conn.close()
        before = self._snapshot()

        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"병용금기"},
        )

        self.assertEqual(result["status"], "current")
        self.assertNotEqual(result.get("reason"), "missing_birth_date")
        self.assertEqual(self._snapshot(), before)

    def test_missing_user_combination_returns_current_without_persisting(self):
        before = self._snapshot()
        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"병용금기"},
            user_id="missing-user",
        )

        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"], [])
        self.assertEqual(self._snapshot(), before)

    def test_missing_user_age_returns_official_criteria_as_unknown(self):
        conn = self._connect()
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, taboo_type, severity, description, source,
                external_id, max_age
            ) VALUES ('ingredientc', '연령금기', 'MEDIUM', 'under 12',
                      'official', 'AGE-C', 11)
            """
        )
        conn.commit()
        conn.close()

        result = self._analyze(
            {"medicine_code": "C", "product_name": "Drug C", "ingredient": "ingredientc"},
            {"연령금기"},
            user_id="missing-user",
        )

        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"][0]["external_id"], "AGE-C")
        self.assertEqual(result["items"][0]["user_applicability"], "unknown")

    def test_missing_user_pregnancy_returns_official_criteria_as_unknown(self):
        conn = self._connect()
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, taboo_type, severity, description, source, external_id
            ) VALUES ('ingredientc', '임부금기', 'MEDIUM', 'pregnancy caution',
                      'official', 'PREG-C')
            """
        )
        conn.commit()
        conn.close()

        result = self._analyze(
            {"medicine_code": "C", "product_name": "Drug C", "ingredient": "ingredientc"},
            {"임부금기"},
            user_id="missing-user",
        )

        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"][0]["external_id"], "PREG-C")
        self.assertEqual(result["items"][0]["user_applicability"], "unknown")

    def test_missing_user_duplicate_returns_current_without_persisting(self):
        before = self._snapshot()
        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"중복성분", "효능군중복"},
            user_id="missing-user",
        )

        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"], [])
        self.assertEqual(self._snapshot(), before)

    def test_unusable_selected_ingredient_logs_existing_reason(self):
        with self.assertLogs(dur_service.logger, level="WARNING") as captured:
            result = self._analyze(
                {
                    "medicine_code": "C",
                    "product_name": "Drug C",
                    "ingredient": None,
                },
                {"병용금기"},
            )
        output = "\n".join(captured.output)
        self.assertEqual(result["reason"], "official_medicine_unavailable")
        self.assertIn("ingredient_usable=False", output)
        self.assertIn("reason=official_medicine_unavailable", output)

    def test_missing_pregnancy_status_returns_official_criteria(self):
        conn = self._connect()
        conn.execute("UPDATE users SET is_pregnant = NULL WHERE id = 'U1'")
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, taboo_type, severity, description, source, external_id
            ) VALUES ('ingredientc', '임부금기', 'MEDIUM', 'pregnancy caution',
                      'official', 'PREG-C')
            """
        )
        conn.commit()
        conn.close()
        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"임부금기"},
        )
        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"][0]["user_applicability"], "unknown")
        self.assertEqual(result["user_context"]["pregnancy_status"], "unknown")

    def test_true_pregnancy_status_runs_pregnancy_check(self):
        conn = self._connect()
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, taboo_type, severity, description, source, external_id
            ) VALUES ('ingredientc', '임부금기', 'MEDIUM', 'pregnancy caution',
                      'official', 'PREG-C')
            """
        )
        conn.commit()
        conn.close()
        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"임부금기"},
        )
        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"][0]["external_id"], "PREG-C")
        self.assertEqual(result["items"][0]["user_applicability"], "applicable")
        self.assertEqual(result["user_context"]["pregnancy_status"], "pregnant")

    def test_false_pregnancy_status_still_returns_official_criteria(self):
        conn = self._connect()
        conn.execute("UPDATE users SET is_pregnant = 0 WHERE id = 'U1'")
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, taboo_type, severity, description, source, external_id
            ) VALUES ('ingredientc', '임부금기', 'MEDIUM', 'pregnancy caution',
                      'official', 'PREG-C')
            """
        )
        conn.commit()
        conn.close()
        result = self._analyze(
            {
                "medicine_code": "C",
                "product_name": "Drug C",
                "ingredient": "ingredientc",
            },
            {"임부금기"},
        )
        self.assertEqual(result["status"], "current")
        self.assertEqual(result["items"][0]["external_id"], "PREG-C")
        self.assertEqual(result["items"][0]["user_applicability"], "not_applicable")
        self.assertEqual(
            result["user_context"]["pregnancy_status"], "not_pregnant"
        )

    def test_persistent_analysis_still_inserts_risk_result(self):
        before = self._snapshot()[1]
        with (
            patch.object(dur_service, "get_connection", side_effect=self._connect),
            patch(
                "app.services.dur_sync_service.refresh_dur_for_ingredients",
                return_value={"status": "ok", "fetched": 0, "upserted": 0},
            ),
        ):
            result = dur_service.analyze_dur(
                dur_service.DurAnalyzeRequest(user_id="U1", medicine_codes=[])
            )
        after = self._snapshot()[1]
        self.assertIsNotNone(result["risk_result_id"])
        self.assertEqual(len(after), len(before) + 1)


if __name__ == "__main__":
    unittest.main()
