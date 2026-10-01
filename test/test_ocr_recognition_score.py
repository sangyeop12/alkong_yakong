from app.services.ocr.parser import measure_field_coverage
from app.models.schemas import OCRMedicineItem
from app.services.prescription_service import (
    _druglike_misses,
    _ocr_field_confidences,
    _user_readiness,
)


def test_coverage_excludes_hospital_pharmacy_date():
    coverage = measure_field_coverage(
        {
            "hospital_name": "",
            "pharmacy_name": "",
            "prescribed_date": "",
            "items": [
                {
                    "drug_name": "프리마란정",
                    "ingredient": "프로게스테론",
                    "frequency_per_day": None,
                    "duration_days": None,
                }
            ],
        }
    )
    assert coverage["header_pct"] == 0.0
    assert coverage["overall_pct"] == 100.0
    assert coverage["items_pct"] == 100.0


def test_readiness_ignores_missing_dosing_and_header_coverage():
    result = _user_readiness(
        [
            {
                "drug_name": "프리마란정",
                "product_name": "프리마란정",
                "ingredient": "프로게스테론",
                "match_status": "MATCHED",
                "uncertain": False,
            }
        ],
        {
            "engine_confidence": 0.1,
            "field_coverage": {"overall_pct": 10.0},
        },
    )
    assert result["pct"] == 100
    assert result["metric"] == "official_name"
    assert "공식 약" in result["meaning"]
    assert "하루 횟수" not in result["missing_hints"]
    assert "투약 일수" not in result["missing_hints"]


def test_readiness_penalizes_unmatched_name_and_missing_ingredient():
    result = _user_readiness(
        [
            {
                "drug_name": "없는약이름정",
                "ingredient": "",
                "match_status": "UNMATCHED",
                "uncertain": True,
            }
        ]
    )
    assert result["pct"] == 0
    assert "약 이름 확인" in result["missing_hints"]


def test_discarded_official_names_count_as_misses():
    misses = _druglike_misses(
        ["프리마란정", "투약량", "비)슈...", "나주", "진정"],
        ["다이크로짙정"],
    )
    assert misses == ["프리마란정"]

    mixed = _user_readiness(
        [
            {
                "drug_name": "다이크로짙정",
                "product_name": "다이크로짙정",
                "ingredient": "히드로클로로티아지드",
                "match_status": "MATCHED",
                "uncertain": False,
            },
            {
                "drug_name": "프리마란정",
                "ingredient": "",
                "match_status": "UNMATCHED",
                "uncertain": True,
            },
        ]
    )
    assert mixed["pct"] == 50


def test_four_matched_drugs_are_one_hundred():
    matched = [
        {
            "drug_name": name,
            "product_name": name,
            "ingredient": "",
            "match_status": "MATCHED",
            "uncertain": False,
        }
        for name in ("옴니세프캡슐", "헤라신정", "베포렌비정", "덱스노펜세미정")
    ]
    result = _user_readiness(matched)
    assert result["pct"] == 100
    assert result["label"] == "good"


def test_ocr_field_confidence_uses_real_clova_values():
    result = _ocr_field_confidences(
        OCRMedicineItem(
            drug_name="아디팜정",
            dosage="0.50",
            frequency_per_day=3,
            duration_days=7,
        ),
        raw_name="아디팜정",
        ocr_trace={
            "fields": [
                {"text": "아디팜정", "confidence": 0.97},
                {"text": "0.50", "confidence": 0.88},
                {"text": "3회", "confidence": 0.91},
                {"text": "7일", "confidence": 0.89},
            ]
        },
    )

    assert result == {
        "drug_name": 97,
        "dose_amount": 88,
        "frequency_per_day": 91,
        "duration_days": 89,
    }
