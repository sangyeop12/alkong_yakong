import sqlite3

from app.services.drug_explain_service import reviewed_detail_payload
from app.services.medicine_detail_service import ensure_medicine_detail
from app.services.prescription_service import _upsert_official_medicine
from init_db import TABLE_DEFINITIONS


def test_reviewed_official_and_ocr_medicines_share_quality_pipeline():
    """One integration test covering READY, long official text, and OCR registration."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    for table in (
        "medicines",
        "ai_explanation_cards",
        "ingredient_explanations",
        "medicine_detail_profiles",
        "medicine_detail_jobs",
    ):
        conn.execute(TABLE_DEFINITIONS[table])

    conn.execute(
        """
        INSERT INTO medicines (
            medicine_code, product_name, ingredient, efficacy, usage, precautions
        ) VALUES ('EXISTING-1', '기존심장약', '검토성분', '부정맥 치료',
                  '처방에 따라 복용', '호흡이 불편하면 의료진과 상담')
        """
    )
    conn.execute(
        """
        INSERT INTO ai_explanation_cards (
            medicine_code, summary, ingredient_explanation,
            approved_use_summary, approved_uses, cautions, ask_doctor_when,
            review_status, source_verified, content_generated_by,
            source, source_url, reviewed_at
        ) VALUES (
            'EXISTING-1', '심장 박동을 조절하는 약이에요.',
            '검토성분은 심장 전기 신호가 불규칙해지는 것을 조절하는 성분이에요.',
            '부정맥 치료에 사용될 수 있어요.', '["부정맥 치료"]',
            '["호흡이 불편하면 의료진에게 알려주세요."]',
            '["숨쉬기 어려울 때"]', 'REVIEWED', 1, 'manual-review',
            '식약처 의약품 허가정보', 'https://nedrug.mfds.go.kr', CURRENT_TIMESTAMP
        )
        """
    )

    existing_profile = ensure_medicine_detail(conn, "EXISTING-1")
    assert existing_profile is not None
    assert existing_profile["status"] == "READY"
    existing_payload = reviewed_detail_payload(
        conn, dict(conn.execute("SELECT * FROM medicines WHERE medicine_code='EXISTING-1'").fetchone())
    )
    assert existing_payload["explanation"]["status"] == "READY"
    assert "전기 신호" in existing_payload["explanation"]["ingredient_explanation"]

    conn.execute(
        """
        INSERT INTO medicines (
            medicine_code, product_name, ingredient, efficacy, usage, precautions
        ) VALUES (
            'IBU-1', '부루펜정200밀리그램', '이부프로펜',
            '다음 질환에도 사용할 수 있다. 류마티양 관절염, 골관절염(퇴행성 관절질환), 감기로 인한 발열 및 통증, 요통, 월경곤란증, 수술후 통증, 두통, 치통, 근육통, 신경통, 급성통풍, 건염, 건초염, 활액낭염',
            '의료진의 처방에 따라 복용합니다.',
            '다른 약을 복용 중이면 의료진에게 알려주세요.'
        )
        """
    )
    ibuprofen_profile = ensure_medicine_detail(conn, "IBU-1")
    assert ibuprofen_profile is not None
    assert ibuprofen_profile["status"] == "OFFICIAL_ONLY"
    assert "이부프로펜" in ibuprofen_profile["ingredient_explanation"]
    assert "준비 중" not in ibuprofen_profile["ingredient_explanation"]
    assert 1 < len(ibuprofen_profile["approved_uses"]) <= 3
    assert len(ibuprofen_profile["all_approved_uses"]) > 3
    assert all(
        "다음 질환에도 사용할 수 있다" not in item
        for item in ibuprofen_profile["approved_uses"]
        + ibuprofen_profile["all_approved_uses"]
    )
    assert len(ibuprofen_profile["all_approved_uses"]) == len(
        set(ibuprofen_profile["all_approved_uses"])
    )

    code, _ = _upsert_official_medicine(
        conn,
        {
            "source": "local",
            "medicine": {
                "medicine_code": "MFDS-OCR-1",
                "product_name": "OCR공식약정",
                "ingredient": "공식성분",
                "manufacturer": "공식제약",
                "efficacy": "알레르기 비염, 두드러기 및 가려움",
                "usage": "의료진의 처방에 따라 복용합니다.",
                "precautions": "다른 약을 복용 중이면 의료진에게 알려주세요.",
            },
        },
    )
    assert code == "MFDS-OCR-1"
    ocr_profile = conn.execute(
        "SELECT * FROM medicine_detail_profiles WHERE medicine_code=?", (code,)
    ).fetchone()
    ocr_job = conn.execute(
        "SELECT * FROM medicine_detail_jobs WHERE medicine_code=?", (code,)
    ).fetchone()
    assert ocr_profile is not None
    assert ocr_profile["status"] == "OFFICIAL_ONLY"
    assert ocr_job is not None and ocr_job["status"] == "READY"
    ocr_payload = reviewed_detail_payload(
        conn, dict(conn.execute("SELECT * FROM medicines WHERE medicine_code=?", (code,)).fetchone())
    )
    assert ocr_payload["explanation"]["status"] == "OFFICIAL_ONLY"
    assert "공식성분" in ocr_payload["explanation"]["ingredient_explanation"]
    assert "준비 중" not in ocr_payload["explanation"]["ingredient_explanation"]
    assert ocr_payload["explanation"]["approved_use_summary"]
    assert ocr_payload["official_usage"]["available"] is True

    conn.close()
