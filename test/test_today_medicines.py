import pytest

import app.database as database
import init_db
from app.services.seed_mvp_medicines import MVP_USER_ID, ensure_mvp_demo_medicines
from app.services.today_medication_service import (
    _doses_from_active_medicines,
    _medicine_item,
    _is_current_ocr_interaction,
    _visible_medicine_item,
    get_today_medicines,
)
from app.database import get_connection


@pytest.fixture(autouse=True)
def isolated_medicine_db(tmp_path, monkeypatch):
    path = str(tmp_path / "today-medicines.db")
    monkeypatch.setattr(database, "DB_PATH", path)
    monkeypatch.setattr(init_db, "DB_PATH", path)
    init_db.initialize_database()


def test_mvp_user_today_medicines_from_server():
    ensure_mvp_demo_medicines()
    data = get_today_medicines(MVP_USER_ID)
    assert data["user_id"] == MVP_USER_ID
    assert data["has_server_medicines"] is True
    assert data["doses"]
    names = [
        med["display_name"]
        for dose in data["doses"]
        for med in dose["medicines"]
    ]
    assert any("코다론" in name for name in names)
    assert all("부루펜" not in name for name in names)
    assert all("게루삼" not in name for name in names)
    assert not any("아디팜" in name for name in names)
    assert not any("프리마란" in name for name in names)
    assert not any("프레벨" in name for name in names)
    assert not any("휴온스시" in name for name in names)
    assert any(med.get("efficacy") for dose in data["doses"] for med in dose["medicines"])
    assert any(
        "약이에요" in str(med.get("easy_category") or "")
        for dose in data["doses"]
        for med in dose["medicines"]
    )


def test_home_amount_uses_take_dose_not_name_milligrams():
    milligrams = _medicine_item(
        {
            "product_name": "휴온스시메티딘정200밀리그램",
            "dosage": "200밀리그램",
            "ingredient": "시메티딘",
            "easy_category": "위약",
            "efficacy": "위궤양",
        }
    )
    assert milligrams["amount"] == ""
    assert "200" not in milligrams["amount"]

    half = _medicine_item(
        {
            "product_name": "휴온스시메티딘정200밀리그램",
            "dosage": "0.50",
            "ingredient": "시메티딘",
            "easy_category": "위약",
            "efficacy": "위궤양",
        }
    )
    assert half["amount"] == ""


def test_home_item_separates_purpose_explanation_and_key_caution():
    item = _medicine_item(
        {
            "medicine_code": "197800210",
            "product_name": "아디팜정(히드록시진염산염)",
            "ingredient": "히드록시진염산염",
            "dosage": "1알",
            "efficacy": (
                "신경증에서의 불안, 긴장, 초조. "
                "두드러기, 피부질환에 수반하는 가려움"
            ),
            "precautions": "졸음이 올 수 있으며 운전 및 기계조작을 피한다.",
        }
    )
    assert item["purpose_label"] == "가려움 완화 · 불안·긴장 완화"
    assert item["short_explanation"] == "가려울 때 먹는 약이에요"
    assert "목적으로 처방" not in item["short_explanation"]
    assert "운전" in item["key_caution"]
    assert len(item["easy_purposes"]) == 2
    assert all(isinstance(value, str) for value in item["easy_purposes"])
    assert all(isinstance(value, dict) for value in item["purposes"])
    assert all(isinstance(value, str) for value in item["key_cautions"])


def test_active_medicine_without_frequency_does_not_get_a_made_up_morning_dose():
    rows = [
        {
            "medicine_code": "TEST-1",
            "product_name": "테스트정",
            "ingredient": "테스트성분",
            "dosage": "1알",
            "frequency_per_day": None,
            "administration_times": "[]",
            "easy_category": "처방받은 약이에요",
            "efficacy": "",
        }
    ]
    assert _doses_from_active_medicines(rows) == []


def test_explicit_named_times_are_kept_as_today_slots():
    rows = [
        {
            "medicine_code": "TEST-NAMED-TIMES",
            "product_name": "시간확인정",
            "ingredient": "테스트성분",
            "dosage": "1알",
            "frequency_per_day": 3,
            "administration_times": '["아침", "점심", "저녁"]',
            "easy_category": "",
            "efficacy": "",
        }
    ]
    doses = _doses_from_active_medicines(rows)
    assert [dose["slot"] for dose in doses] == ["morning", "lunch", "dinner"]


def test_visible_item_skips_druginfo_mock_names():
    assert (
        _visible_medicine_item(
            {
                "medicine_code": "MVP-ANY",
                "product_name": "체험용정",
                "ingredient": "체험성분",
                "dosage": "1알",
            }
        )
        is None
    )
    assert (
        _visible_medicine_item(
            {
                "product_name": "아스피린 100mg",
                "ingredient": "아스피린 100mg",
                "dosage": "1알",
            }
        )
        is None
    )
    real = _visible_medicine_item(
        {
            "product_name": "휴온스시메티딘정200밀리그램",
            "ingredient": "시메티딘",
            "dosage": "0.50",
            "efficacy": "위궤양",
        }
    )
    assert real is not None
    assert real["amount"] == ""


def test_adipam_card_uses_permission_name_and_itch_copy():
    item = _medicine_item(
        {
            "medicine_code": "197800210",
            "product_name": "아디팜정(히드록시진염산염)",
            "ingredient": "히드록시진염산염",
            "dosage": "0.50",
            "easy_category": "알레르기·두통·어지러움",
            "efficacy": (
                "신경증에서의 불안, 긴장, 초조. "
                "두드러기, 피부질환에 수반하는 가려움"
            ),
            "short_explanation": "가려움 또는 불안·긴장을 완화할 목적으로 처방될 수 있어요.",
            "explanation_review_status": "REVIEWED",
        }
    )
    assert item["display_name"] == "아디팜정(히드록시진염산염)"
    assert item["product_name"] == "아디팜정(히드록시진염산염)"
    assert item["purpose_label"] == "가려움 완화 · 불안·긴장 완화"
    assert "가려울 때" in item["short_explanation"]
    assert "목적으로 처방" not in (item["short_explanation"] or "")
    assert item["amount"] == ""
    assert "처방받은 약이에요" not in (item["short_explanation"] or "")


def test_home_does_not_expose_a_risk_without_current_ocr_match():
    ensure_mvp_demo_medicines()
    marker = "테스트 함께먹기 주의"
    conn = get_connection()
    conn.execute(
        """
        INSERT INTO risk_results (
            user_id, risk_level, description, analyzed_ingredients,
            total_matches, matches_json, assessment_status
        ) VALUES (?, 'HIGH', ?, '[]', 1, '[]', 'RISK_FOUND')
        """,
        (MVP_USER_ID, marker),
    )
    conn.commit()
    conn.close()
    try:
        assert get_today_medicines(MVP_USER_ID)["interaction_alert"] is None
    finally:
        conn = get_connection()
        conn.execute(
            "DELETE FROM risk_results WHERE user_id = ? AND description = ?",
            (MVP_USER_ID, marker),
        )
        conn.commit()
        conn.close()


def test_current_ocr_interaction_requires_active_pair_and_ocr_origin():
    match = {
        "medicine_codes_a": ["OCR-A"],
        "medicine_codes_b": ["OTHER-B"],
    }
    assert _is_current_ocr_interaction(
        match,
        active_codes={"OCR-A", "OTHER-B"},
        active_ocr_codes={"OCR-A"},
    )
    assert not _is_current_ocr_interaction(
        match,
        active_codes={"OCR-A"},
        active_ocr_codes={"OCR-A"},
    )
    assert not _is_current_ocr_interaction(
        match,
        active_codes={"OCR-A", "OTHER-B"},
        active_ocr_codes=set(),
    )
