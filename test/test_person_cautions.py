import sqlite3

from app.services.dur_service import person_cautions_for_medicine
from init_db import TABLE_DEFINITIONS


def _open(path):
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def _prepare(path):
    conn = _open(path)
    conn.execute(TABLE_DEFINITIONS["users"])
    conn.execute(TABLE_DEFINITIONS["dur_taboo"])
    conn.execute(
        """
        INSERT INTO dur_taboo (
            ingredient_a, taboo_type, severity, description,
            source, external_id, max_age
        ) VALUES (
            '테스트성분', '연령금기', 'MEDIUM', '안전성 및 유효성 미확립',
            'test', 'age-1', 18
        )
        """
    )
    conn.execute(
        """
        INSERT INTO dur_taboo (
            ingredient_a, taboo_type, severity, description,
            source, external_id, pregnancy_grade
        ) VALUES (
            '테스트성분', '임부금기', 'MEDIUM', '임부에 대한 안전성 미확립',
            'test', 'preg-1', '2등급'
        )
        """
    )
    conn.commit()
    conn.close()


def _user(conn, user_id, *, birth_date, is_pregnant=0):
    conn.execute(
        "INSERT INTO users (id, name, birth_date, is_pregnant) VALUES (?, '환자', ?, ?)",
        (user_id, birth_date, is_pregnant),
    )
    conn.commit()


def _medicine():
    return {
        "medicine_code": "MED-1",
        "product_name": "테스트정",
        "ingredient": "테스트성분",
    }


def test_child_sees_age_caution_adult_does_not(tmp_path):
    db_path = tmp_path / "person.sqlite3"
    _prepare(db_path)
    conn = _open(db_path)
    try:
        _user(conn, "child", birth_date="2020-01-01")
        _user(conn, "adult", birth_date="1950-01-01")
        child = person_cautions_for_medicine(conn, user_id="child", medicine=_medicine())
        adult = person_cautions_for_medicine(conn, user_id="adult", medicine=_medicine())
        assert any("나이" in line for line in child)
        assert not any("나이" in line for line in adult)
        assert "사용상의주의사항" not in " ".join(child)
        assert "사용상의주의사항" not in " ".join(adult)
    finally:
        conn.close()


def test_pregnancy_caution_only_when_pregnant(tmp_path):
    db_path = tmp_path / "person.sqlite3"
    _prepare(db_path)
    conn = _open(db_path)
    try:
        _user(conn, "preg", birth_date="1990-01-01", is_pregnant=1)
        _user(conn, "not-preg", birth_date="1990-01-01", is_pregnant=0)
        pregnant = person_cautions_for_medicine(
            conn, user_id="preg", medicine=_medicine()
        )
        other = person_cautions_for_medicine(
            conn, user_id="not-preg", medicine=_medicine()
        )
        assert any("임신" in line for line in pregnant)
        assert not any("임신" in line for line in other)
    finally:
        conn.close()
