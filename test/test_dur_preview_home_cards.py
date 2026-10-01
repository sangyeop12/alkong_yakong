import pytest

import app.database as database
import init_db
from app.database import get_connection
from app.models.schemas import DurAnalyzeRequest
from app.services.dur_service import (
    analyze_dur,
    preview_conflicts_for_codes,
)
from app.services.seed_mvp_medicines import MVP_USER_ID, ensure_mvp_demo_medicines
from app.services.today_medication_service import get_today_medicines

ADIPAM = "197800210"
CODARONE = "200701021"


@pytest.fixture
def dur_pair(tmp_path, monkeypatch):
    """Use an isolated DB with an explicitly synthetic interaction rule."""
    path = str(tmp_path / "dur-preview.db")
    monkeypatch.setattr(database, "DB_PATH", path)
    monkeypatch.setattr(init_db, "DB_PATH", path)
    init_db.initialize_database()
    ensure_mvp_demo_medicines()
    conn = get_connection()
    try:
        conn.execute(
            """
            INSERT INTO medicines (medicine_code, product_name, ingredient, efficacy)
            VALUES (?, '아디팜정', '히드록시진염산염', '합성 테스트 자료')
            """,
            (ADIPAM,),
        )
        conn.execute(
            """
            INSERT INTO dur_taboo (
                ingredient_a, ingredient_b, taboo_type, severity,
                description, source, external_id
            ) VALUES (
                '히드록시진염산염', '아미오다론염산염', '병용금기', 'HIGH',
                '심부정맥 위험 증가', 'synthetic-test', 'test-adipam-codarone'
            )
            """
        )
        conn.commit()
    finally:
        conn.close()


def test_ocr_preview_flags_adipam_against_registered_codarone(dur_pair):
    ensure_mvp_demo_medicines()
    conflicts = preview_conflicts_for_codes(MVP_USER_ID, [ADIPAM])
    assert ADIPAM in conflicts
    other_names = " ".join(row["other_name"] for row in conflicts[ADIPAM])
    assert "코다론" in other_names
    assert any("심부정맥" in str(row.get("reason") or "") for row in conflicts[ADIPAM])


def test_preview_conflicts_do_not_save_risk_results(dur_pair):
    ensure_mvp_demo_medicines()
    conn = get_connection()
    before = conn.execute(
        "SELECT COUNT(*) AS n FROM risk_results WHERE user_id = ?",
        (MVP_USER_ID,),
    ).fetchone()["n"]
    conn.close()
    preview_conflicts_for_codes(MVP_USER_ID, [ADIPAM])
    conn = get_connection()
    after = conn.execute(
        "SELECT COUNT(*) AS n FROM risk_results WHERE user_id = ?",
        (MVP_USER_ID,),
    ).fetchone()["n"]
    conn.close()
    assert after == before


def test_home_puts_pair_caution_cards_first(dur_pair):
    ensure_mvp_demo_medicines()
    conn = get_connection()
    try:
        conn.execute(
            "INSERT INTO prescriptions (id, user_id, source_type) VALUES ('synthetic-ocr', ?, 'OCR')",
            (MVP_USER_ID,),
        )
        item = conn.execute(
            """
            INSERT INTO prescription_items (
                prescription_id, medicine_code, ocr_drug_name, match_status
            ) VALUES ('synthetic-ocr', ?, '아디팜정', 'MATCHED')
            """,
            (ADIPAM,),
        )
        conn.execute(
            """
            INSERT INTO user_medicines (
                user_id, medicine_code, prescription_item_id, dosage, frequency_per_day,
                administration_times
            ) VALUES (?, ?, ?, '1알', 1, '["08:00"]')
            """,
            (MVP_USER_ID, ADIPAM, item.lastrowid),
        )
        conn.commit()
    finally:
        conn.close()
    result = analyze_dur(
        DurAnalyzeRequest(user_id=MVP_USER_ID, medicine_codes=[ADIPAM, CODARONE]),
        persist=True,
        refresh=False,
    )
    assert result["has_risk"] is True
    try:
        today = get_today_medicines(MVP_USER_ID)
        cards = today["interaction_cards"]
        assert cards
        names = f"{cards[0]['name_a']} {cards[0]['name_b']}"
        assert "아디팜" in names
        assert "코다론" in names
        assert "심장" in str(cards[0]["reason"])
        factor = str(cards[0].get("risk_factor") or "")
        assert "부정맥" in factor
        assert not cards[0].get("caution_a")
        assert "함께 먹을 때 주의" in str(today.get("interaction_alert") or "")
    finally:
        conn = get_connection()
        conn.execute(
            "DELETE FROM risk_results WHERE id = ?",
            (result["risk_result_id"],),
        )
        conn.commit()
        conn.close()
