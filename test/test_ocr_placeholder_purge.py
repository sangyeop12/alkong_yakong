from app.database import get_connection, purge_ocr_placeholder_rows
from app.services.ocr.parser import looks_truncated_ocr_name
from app.services.prescription_service import _should_retake
from init_db import initialize_database


def test_purge_removes_ocr_placeholder_medicine_and_user_row(tmp_path, monkeypatch):
    db_path = tmp_path / "purge.db"
    monkeypatch.setattr("app.database.DB_PATH", str(db_path))
    monkeypatch.setattr("init_db.DB_PATH", str(db_path))
    initialize_database()

    conn = get_connection()
    try:
        conn.execute(
            "INSERT INTO users (id, name, role) VALUES (?, ?, ?)",
            ("u1", "테스터", "PATIENT"),
        )
        conn.execute(
            """
            INSERT INTO medicines (medicine_code, product_name, ingredient)
            VALUES (?, ?, ?)
            """,
            ("OCR-PREVENEX", "프레베넥액", "없음"),
        )
        conn.execute(
            """
            INSERT INTO user_medicines (user_id, medicine_code, is_active)
            VALUES (?, ?, 1)
            """,
            ("u1", "OCR-PREVENEX"),
        )
        conn.commit()
        assert (
            conn.execute(
                "SELECT COUNT(*) FROM medicines WHERE medicine_code LIKE 'OCR-%'"
            ).fetchone()[0]
            == 1
        )
        deleted = purge_ocr_placeholder_rows(conn)
        assert deleted == 1
        assert (
            conn.execute(
                "SELECT COUNT(*) FROM medicines WHERE medicine_code LIKE 'OCR-%'"
            ).fetchone()[0]
            == 0
        )
        assert conn.execute("SELECT COUNT(*) FROM user_medicines").fetchone()[0] == 0
    finally:
        conn.close()


def test_retake_when_truncated_names_were_dropped():
    assert looks_truncated_ocr_name("비)슈...")
    assert _should_retake(100, [], ["비)슈..."])
    assert _should_retake(90, ["없는약이름정"], [])
    assert not _should_retake(100, [], ["투약량"])
