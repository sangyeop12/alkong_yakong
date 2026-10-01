from datetime import date
import json

import pytest

from app.models.schemas import PrescriptionConfirmItem, PrescriptionConfirmRequest
from app.models.schemas import OCRMedicineItem, PrescriptionOCRRequest
from app.database import get_connection
import app.services.prescription_service as prescription_service
from app.services.prescription_service import (
    _schedule_dates,
    _confirmed_clock_times,
    _validated_confirm_dosage,
    confirm_prescription,
)


def _item(**overrides):
    values = {
        "medicine_code": "TEST-001",
        "drug_name": "테스트정",
        "dosage": "1알",
        "frequency_per_day": 2,
        "duration_days": 7,
    }
    values.update(overrides)
    return PrescriptionConfirmItem(**values)


def test_confirm_allows_missing_dosing_fields():
    assert (
        _validated_confirm_dosage(
            _item(dosage=None, frequency_per_day=None, duration_days=None),
            "테스트정",
        )
        is None
    )


def test_confirm_accepts_user_checked_dosing_fields():
    assert _validated_confirm_dosage(_item(), "테스트정") == "1알"


@pytest.mark.parametrize("dosage", ["200밀리그램", "0.25%"])
def test_confirm_keeps_product_strength_from_becoming_take_amount(dosage):
    assert (
        _validated_confirm_dosage(_item(dosage=dosage, unit=None), "테스트정")
        is None
    )


def test_table_dose_is_separated_labeled_and_preserved_for_tablet():
    preview = OCRMedicineItem(drug_name="아디팜정", dosage="0.50")
    assert prescription_service._preview_take_fields(
        preview,
        dosage_form="정제",
    ) == ("0.5", "정", True)

    confirmed = _item(
        dosage="0.50",
        dose_amount="0.5",
        dose_unit="정",
        dosage_form="정제",
    )
    assert _validated_confirm_dosage(confirmed, "아디팜정") == "0.5알"


def test_confirm_normalizes_numeric_amount_with_verified_unit():
    assert _validated_confirm_dosage(
        _item(dosage="0.50", unit="T"),
        "테스트정",
    ) == "0.5알"


@pytest.mark.parametrize("dosage", ["1/2정", "반 알"])
def test_confirm_normalizes_common_half_tablet_notation(dosage):
    assert _validated_confirm_dosage(
        _item(dosage=dosage, unit=None),
        "테스트정",
    ) == "0.5알"


def test_missing_duration_never_creates_a_default_one_day_range():
    assert _schedule_dates(None, None, None) == []
    assert _schedule_dates("2026-09-09", None, 2) == [
        date(2026, 9, 9),
        date(2026, 9, 10),
    ]


def test_prescription_expiry_never_extends_confirmed_duration():
    assert _schedule_dates("2026-09-09", "2026-12-31", 2) == [
        date(2026, 9, 9),
        date(2026, 9, 10),
    ]


def test_only_explicit_clock_or_named_times_can_create_schedules():
    assert _confirmed_clock_times(["08:30", "저녁", "20:15", "3회"]) == [
        "08:30",
        "20:00",
        "20:15",
    ]


def test_same_confirm_payload_is_idempotent():
    user_id = "test-confirm-idempotent"
    medicine_code = "TEST-IDEMPOTENT"
    conn = get_connection()
    conn.execute(
        "INSERT OR IGNORE INTO users (id, name, role) VALUES (?, '테스트', 'PATIENT')",
        (user_id,),
    )
    conn.execute(
        """
        INSERT OR REPLACE INTO medicines (medicine_code, product_name, ingredient)
        VALUES (?, '중복방지정', '테스트성분')
        """,
        (medicine_code,),
    )
    conn.commit()
    conn.close()

    request = PrescriptionConfirmRequest(
        user_id=user_id,
        prescribed_date="2026-09-11",
        items=[
            PrescriptionConfirmItem(
                medicine_code=medicine_code,
                drug_name="중복방지정",
                dosage="1알",
                frequency_per_day=1,
                duration_days=1,
                administration_times=["08:30"],
                match_status="MATCHED",
            )
        ],
    )
    first = confirm_prescription(request)
    second = confirm_prescription(request)
    assert first["registered"] is True
    assert second["duplicate"] is True
    assert second["prescription_id"] == first["prescription_id"]

    conn = get_connection()
    assert conn.execute(
        "SELECT COUNT(*) FROM user_medicines WHERE user_id = ? AND medicine_code = ?",
        (user_id, medicine_code),
    ).fetchone()[0] == 1
    conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
    conn.execute("DELETE FROM medicines WHERE medicine_code = ?", (medicine_code,))
    conn.commit()
    conn.close()


def test_ocr_preview_returns_multi_purpose_patient_guidance(monkeypatch):
    user_id = "test-guidance-preview"
    conn = get_connection()
    conn.execute(
        "INSERT OR IGNORE INTO users (id, name, role) VALUES (?, '테스트', 'PATIENT')",
        (user_id,),
    )
    conn.execute(
        """
        INSERT INTO medicines (
            medicine_code, product_name, ingredient, efficacy, precautions, easy_category
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(medicine_code) DO UPDATE SET
            product_name = excluded.product_name,
            ingredient = excluded.ingredient,
            efficacy = excluded.efficacy,
            precautions = excluded.precautions
        """,
        (
            "TEST-ADIPHARM",
            "아디팜정(히드록시진염산염)",
            "히드록시진염산염",
            "신경증에서의 불안, 긴장, 초조. 두드러기, 피부질환에 수반하는 가려움",
            "졸음이 올 수 있으며 운전 및 기계조작을 피한다.",
            "가려움 약",
        ),
    )
    conn.commit()
    before_user_medicines = conn.execute(
        "SELECT COUNT(*) FROM user_medicines WHERE user_id = ?", (user_id,)
    ).fetchone()[0]
    before_prescriptions = conn.execute(
        "SELECT COUNT(*) FROM prescriptions WHERE user_id = ?", (user_id,)
    ).fetchone()[0]
    conn.close()

    monkeypatch.setattr(
        prescription_service,
        "_extract_items",
        lambda _request: (
            [
                OCRMedicineItem(
                    drug_name="아디팜정",
                    medicine_code="TEST-ADIPHARM",
                    dosage="1알",
                    frequency_per_day=1,
                    duration_days=1,
                )
            ],
            "아디팜정 1정 1회 1일",
            {},
            {},
        ),
    )
    result = prescription_service.create_prescription_from_ocr(
        PrescriptionOCRRequest(user_id=user_id, ocr_text="테스트")
    )
    item = result["items"][0]
    assert item["purpose_label"] == "가려움 완화 · 불안·긴장 완화"
    assert len(item["easy_purposes"]) == 2
    assert "운전" in item["key_caution"]
    assert "처방받은 이유" in item["purpose_notice"]

    conn = get_connection()
    assert conn.execute(
        "SELECT COUNT(*) FROM user_medicines WHERE user_id = ?", (user_id,)
    ).fetchone()[0] == before_user_medicines
    assert conn.execute(
        "SELECT COUNT(*) FROM prescriptions WHERE user_id = ?", (user_id,)
    ).fetchone()[0] == before_prescriptions
    conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
    conn.execute("DELETE FROM medicines WHERE medicine_code = 'TEST-ADIPHARM'")
    conn.commit()
    conn.close()


def _seed_schedule_user(user_id: str, medicine_code: str) -> None:
    conn = get_connection()
    conn.execute(
        "INSERT OR IGNORE INTO users (id, name, role) VALUES (?, '테스트', 'PATIENT')",
        (user_id,),
    )
    conn.execute(
        """
        INSERT OR REPLACE INTO medicines (medicine_code, product_name, ingredient)
        VALUES (?, '스케줄첨부정', '테스트성분')
        """,
        (medicine_code,),
    )
    conn.commit()
    conn.close()


def _cleanup_schedule_user(user_id: str, medicine_code: str) -> None:
    conn = get_connection()
    conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
    conn.execute("DELETE FROM medicines WHERE medicine_code = ?", (medicine_code,))
    conn.commit()
    conn.close()


def test_confirm_attaches_schedules_for_frequency_and_duration():
    user_id = "test-schedule-attach"
    medicine_code = "TEST-SCHEDULE-ATTACH"
    _seed_schedule_user(user_id, medicine_code)
    try:
        result = confirm_prescription(
            PrescriptionConfirmRequest(
                user_id=user_id,
                items=[
                    PrescriptionConfirmItem(
                        medicine_code=medicine_code,
                        drug_name="스케줄첨부정",
                        frequency_per_day=3,
                        duration_days=7,
                        match_status="MATCHED",
                    )
                ],
            )
        )
        assert result["registered"] is True
        assert result["schedule_count"] == 21
        conn = get_connection()
        times = conn.execute(
            """
            SELECT administration_times FROM user_medicines
            WHERE user_id = ? AND medicine_code = ? AND COALESCE(is_active, 1) = 1
            """,
            (user_id, medicine_code),
        ).fetchone()
        conn.close()
        assert times is not None
        assert json.loads(times["administration_times"]) == ["08:00", "13:00", "20:00"]
    finally:
        _cleanup_schedule_user(user_id, medicine_code)


def test_confirm_does_not_invent_schedule_without_duration():
    user_id = "test-schedule-no-days"
    medicine_code = "TEST-SCHEDULE-NO-DAYS"
    _seed_schedule_user(user_id, medicine_code)
    try:
        result = confirm_prescription(
            PrescriptionConfirmRequest(
                user_id=user_id,
                items=[
                    PrescriptionConfirmItem(
                        medicine_code=medicine_code,
                        drug_name="스케줄첨부정",
                        frequency_per_day=3,
                        duration_days=None,
                        match_status="MATCHED",
                    )
                ],
            )
        )
        assert result["registered"] is True
        assert result["schedule_count"] == 0
    finally:
        _cleanup_schedule_user(user_id, medicine_code)


def test_confirm_does_not_default_missing_frequency_to_once():
    user_id = "test-schedule-no-freq"
    medicine_code = "TEST-SCHEDULE-NO-FREQ"
    _seed_schedule_user(user_id, medicine_code)
    try:
        result = confirm_prescription(
            PrescriptionConfirmRequest(
                user_id=user_id,
                items=[
                    PrescriptionConfirmItem(
                        medicine_code=medicine_code,
                        drug_name="스케줄첨부정",
                        frequency_per_day=None,
                        duration_days=7,
                        match_status="MATCHED",
                    )
                ],
            )
        )
        assert result["registered"] is True
        assert result["schedule_count"] == 0
    finally:
        _cleanup_schedule_user(user_id, medicine_code)


def test_confirm_skips_unmatched_item_without_rolling_back_matched():
    user_id = "test-partial-unmatched"
    medicine_code = "TEST-PARTIAL-MATCHED"
    _seed_schedule_user(user_id, medicine_code)
    try:
        result = confirm_prescription(
            PrescriptionConfirmRequest(
                user_id=user_id,
                items=[
                    PrescriptionConfirmItem(
                        medicine_code=medicine_code,
                        drug_name="스케줄첨부정",
                        frequency_per_day=1,
                        duration_days=1,
                        match_status="MATCHED",
                    ),
                    PrescriptionConfirmItem(
                        medicine_code="OCR-UNKNOWN",
                        drug_name="모르는약",
                        match_status="UNMATCHED",
                    ),
                ],
            )
        )
        assert result["registered"] is True
        assert result["medicine_codes"] == [medicine_code]
    finally:
        _cleanup_schedule_user(user_id, medicine_code)
