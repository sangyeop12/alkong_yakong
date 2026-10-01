"""A background official-medicine lookup must not block account creation."""

import sqlite3
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

import app.database as database
from app.routes import users
from app.services.pharmacist.retrieve import refresh_app_medicines_from_permission
from init_db import TABLE_DEFINITIONS


class SignupDatabaseLockTest(unittest.TestCase):
    def test_signup_waits_for_brief_sqlite_write_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "isolated.db")
            blocker = sqlite3.connect(path)
            try:
                blocker.execute(TABLE_DEFINITIONS["users"])
                blocker.commit()
                blocker.execute("BEGIN IMMEDIATE")

                finished = threading.Event()
                result = []

                def signup():
                    try:
                        api = FastAPI()
                        api.include_router(users.router)
                        result.append(
                            TestClient(api).post(
                                "/api/v1/users",
                                json={"name": "합성 사용자", "role": "patient"},
                            )
                        )
                    except Exception as error:
                        result.append(error)
                    finally:
                        finished.set()

                with patch.object(database, "DB_PATH", path):
                    worker = threading.Thread(target=signup)
                    worker.start()
                    try:
                        time.sleep(0.2)
                        self.assertFalse(finished.is_set())
                    finally:
                        blocker.commit()
                        worker.join(5)

                self.assertTrue(finished.is_set())
                self.assertEqual(len(result), 1)
                self.assertEqual(result[0].status_code, 200)
            finally:
                blocker.close()

    def test_signup_proceeds_while_next_medicine_lookup_waits(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "isolated.db")
            conn = sqlite3.connect(path)
            try:
                conn.execute(TABLE_DEFINITIONS["users"])
                conn.execute(TABLE_DEFINITIONS["medicines"])
                conn.executemany(
                    "INSERT INTO medicines (medicine_code, product_name, ingredient) "
                    "VALUES (?, ?, ?)",
                    [("TEST-1", "합성약1", "합성성분1"), ("TEST-2", "합성약2", "합성성분2")],
                )
                conn.commit()
            finally:
                conn.close()

            second_lookup_started = threading.Event()
            release_lookup = threading.Event()
            signup_finished = threading.Event()
            errors = []
            result = []

            def fake_lookup(name):
                if name == "합성약1":
                    return {"medicine": {"medicine_code": "TEST-1", "efficacy": "합성 효능"}}
                second_lookup_started.set()
                release_lookup.wait(10)
                return None

            def refresh():
                try:
                    refresh_app_medicines_from_permission()
                except Exception as error:
                    errors.append(error)

            def signup():
                try:
                    api = FastAPI()
                    api.include_router(users.router)
                    client = TestClient(api)
                    result.append(
                        client.post(
                            "/api/v1/users",
                            json={
                                "name": "합성 사용자",
                                "phone": "01000000000",
                                "password": "test1234",
                                "role": "patient",
                            },
                        )
                    )
                except Exception as error:
                    errors.append(error)
                finally:
                    signup_finished.set()

            with (
                patch.object(database, "DB_PATH", path),
                patch("app.services.pharmacist.retrieve._retrieve_for_app_medicine", fake_lookup),
                patch("app.services.pharmacist.easy_category.sync_medicine_guidance"),
                patch("app.services.medicine_detail_service.ensure_medicine_detail"),
            ):
                worker = threading.Thread(target=refresh)
                worker.start()
                try:
                    self.assertTrue(second_lookup_started.wait(5))
                    signup_worker = threading.Thread(target=signup)
                    signup_worker.start()
                    self.assertTrue(
                        signup_finished.wait(3),
                        "회원가입이 다음 약의 외부 조회 동안 DB 잠금에 막혔습니다.",
                    )
                finally:
                    release_lookup.set()
                    worker.join(10)
                    if "signup_worker" in locals():
                        signup_worker.join(10)

            self.assertFalse(errors, errors)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0].status_code, 200)
            self.assertTrue(result[0].json()["id"])


if __name__ == "__main__":
    unittest.main()
