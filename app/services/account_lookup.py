"""전화번호로 가입 계정을 찾는다. 로그인과 보호자 연결이 같은 규칙을 쓴다."""

from __future__ import annotations

import re
import sqlite3


def phone_digits(phone: str | None) -> str:
    return re.sub(r"\D", "", phone or "")


def find_account_by_phone(
    conn: sqlite3.Connection, phone: str | None, *, exclude_id: str | None = None
):
    """비밀번호가 있는 계정 중 번호가 같은 것. 하이픈은 따지지 않는다."""
    digits = phone_digits(phone)
    if not digits:
        return None
    for row in conn.execute(
        "SELECT * FROM users WHERE password_hash IS NOT NULL ORDER BY created_at"
    ):
        if row["id"] != exclude_id and phone_digits(row["phone"]) == digits:
            return row
    return None
