import sqlite3

from app.services.pharmacist.easy_category import (
    derive_easy_category,
    derive_easy_purposes_from_medicine,
    derive_easy_spoken,
    format_display_name,
    medicine_guidance_from_medicine,
    sync_medicine_guidance,
)
from app.services.pharmacist.easy_category_db import initialize_easy_category_map_db


def setup_module():
    initialize_easy_category_map_db(reset_seed=True)


def test_amlodipine_is_blood_pressure():
    assert (
        derive_easy_category(product_name="암로디핀", ingredient="암로디핀 5mg")
        == "혈압약"
    )


def test_aspirin_is_blood_thinning():
    assert derive_easy_category(ingredient="아스피린 100mg") == "피가 굳지 않게 하는 약"


def test_metformin_is_diabetes():
    assert derive_easy_category(ingredient="메트포르민 500mg") == "당뇨약"


def test_tylenol_name_fallback():
    assert derive_easy_category(product_name="타이레놀정500밀리그램") == "해열제"


def test_cold_symptoms_are_one_nickname():
    label = derive_easy_category(
        efficacy="이 약은 감기의 제증상(콧물, 코막힘, 재채기, 발열)의 완화에 사용합니다"
    )
    assert label == "감기약"


def test_fever_and_pain_from_efficacy():
    label = derive_easy_category(efficacy="해열 및 감기에 의한 동통, 두통")
    assert label in {"해열제", "진통제", "두통약"}


def test_unknown_without_keyword_returns_none():
    assert derive_easy_category(product_name="무명정") is None


def test_format_display_name():
    assert format_display_name("암로디핀정", "혈압약") == "암로디핀정 (혈압약)"
    assert format_display_name("암로디핀정", None) == "암로디핀정"


def test_gastritis_is_heartburn_medicine():
    label = derive_easy_category(
        efficacy="급성위염, 만성위염의 급성악화기, 위·십이지장궤양, 역류성식도염"
    )
    assert label == "속쓰림 약"


def test_caution_allergy_does_not_become_category():
    label = derive_easy_category(
        efficacy="급성위염",
        usage="성인 1일 3회 투여",
        source_text="이 약 성분에 알레르기 병력이 있는 환자는 투여하지 않는다.",
    )
    assert label == "속쓰림 약"


def test_one_purpose_not_joined_keywords():
    label = derive_easy_category(
        efficacy="1. 수술 후, 신경증에서의 불안, 긴장, 초조 2. 두드러기, 피부질환에 수반하는 가려움"
    )
    assert label == "가려움 약"
    assert "·" not in label


def test_adipharm_has_both_official_purposes_without_claiming_diagnosis():
    guidance = medicine_guidance_from_medicine(
        {
            "medicine_code": "197800210",
            "product_name": "아디팜정(히드록시진염산염)",
            "ingredient": "히드록시진염산염",
            "efficacy": (
                "신경증에서의 불안, 긴장, 초조\n"
                "두드러기, 피부질환에 수반하는 가려움"
            ),
            "precautions": "졸음이 올 수 있으며 자동차운전 또는 기계조작을 피한다.",
        }
    )
    assert [p["purpose_code"] for p in guidance["easy_purposes"]] == [
        "ITCH_RELIEF",
        "ANXIETY_TENSION_RELIEF",
    ]
    assert guidance["purpose_label"] == "가려움 완화 · 불안·긴장 완화"
    assert guidance["short_explanation"] == (
        "가려움 또는 불안·긴장을 완화할 목적으로 사용될 수 있어요."
    )
    assert "처방받은 이유" in guidance["purpose_notice"]
    assert "운전" in guidance["key_caution"]


def test_antibiotic_name_wins_over_influenza_bacteria_word():
    purposes = derive_easy_purposes_from_medicine(
        {
            "product_name": "옴니세프캡슐100밀리그램(세프디니르)",
            "ingredient": "세프디니르",
            "efficacy": "인플루엔자균, 폐렴구균에 의한 감염증",
        }
    )
    assert purposes[0]["easy_label"] == "감염약"


def test_special_medicines_use_specific_categories_not_generic_fallback():
    pentamidine = derive_easy_purposes_from_medicine(
        {
            "product_name": "화이자펜타미딘이세티온산염주300mg",
            "ingredient": "펜타미딘이세티온산염",
            "efficacy": "뉴우모시스티스 카리니 감염의 치료",
        }
    )
    vandetanib = derive_easy_purposes_from_medicine(
        {
            "product_name": "카프렐사정100밀리그램(반데타닙)",
            "ingredient": "반데타닙",
            "efficacy": "절제 불가능한 갑상선 수질암의 치료",
        }
    )
    assert pentamidine[0]["easy_label"] == "특정 감염 치료약"
    assert vandetanib[0]["easy_label"] == "갑상선암 치료약"


def test_name_match_wins_over_secondary_efficacy_word():
    assert (
        derive_easy_category(
            ingredient="아스피린 100mg",
            efficacy="고혈압, 고콜레스테롤혈증 위험이 있는 환자의 혈전 예방",
        )
        == "피가 굳지 않게 하는 약"
    )


def test_reviewed_purpose_is_not_overwritten_by_derived_sync():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.executescript(
        """
        CREATE TABLE medicine_purposes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            medicine_code TEXT NOT NULL,
            purpose_code TEXT NOT NULL,
            easy_label TEXT NOT NULL,
            easy_sentence TEXT NOT NULL,
            evidence_type TEXT NOT NULL,
            evidence_text TEXT,
            source TEXT NOT NULL,
            confidence TEXT NOT NULL,
            review_status TEXT NOT NULL,
            classifier_version TEXT NOT NULL,
            priority INTEGER NOT NULL,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE (medicine_code, purpose_code)
        );
        CREATE TABLE medicine_key_cautions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            medicine_code TEXT NOT NULL,
            caution_code TEXT NOT NULL,
            short_sentence TEXT NOT NULL,
            evidence_text TEXT,
            source TEXT NOT NULL,
            severity TEXT NOT NULL,
            review_status TEXT NOT NULL,
            classifier_version TEXT NOT NULL,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE (medicine_code, caution_code)
        );
        """
    )
    conn.execute(
        """
        INSERT INTO medicine_purposes (
            medicine_code, purpose_code, easy_label, easy_sentence,
            evidence_type, evidence_text, source, confidence,
            review_status, classifier_version, priority
        ) VALUES ('197800210', 'ITCH_RELIEF', '약사 검토 분류',
                  '약사가 검토한 설명이에요.', 'PHARMACIST_REVIEW',
                  '검토 기록', '약사 검토', 'HIGH', 'REVIEWED', 'manual', 1)
        """
    )
    guidance = sync_medicine_guidance(
        conn,
        {
            "medicine_code": "197800210",
            "product_name": "아디팜정(히드록시진염산염)",
            "ingredient": "히드록시진염산염",
            "efficacy": "두드러기, 피부질환에 수반하는 가려움",
        },
    )
    assert guidance["purpose_label"] == "약사 검토 분류"
    assert guidance["short_explanation"] == "약사가 검토한 설명이에요."
    conn.close()


def test_spoken_gasmotin_is_digestion():
    text = derive_easy_spoken(
        product_name="가스모틴정5밀리그램",
        efficacy="기능성소화불량으로 인한 소화기증상(속쓰림, 구역, 구토)",
        usage="식전 또는 식후에 경구투여한다.",
    )
    assert text == "소화가 안 될 때 먹는 약이에요"


def test_spoken_lipitor_is_cholesterol_not_blood_pressure():
    text = derive_easy_spoken(
        product_name="리피토정20밀리그램",
        efficacy="고지혈증. 다중위험요소(고혈압, 흡연)가 있는 성인",
    )
    assert text == "피 속 기름을 낮추는 약이에요"


def test_spoken_prevel_is_topical_itch():
    text = derive_easy_spoken(
        product_name="프레벨액0.25%(프레드니카르베이트)",
        efficacy="습진ㆍ피부염군(아토피피부염, 접촉성알레르기피부염, 가려움발진 포함), 건선",
    )
    assert text == "가려운 피부에 바르는 약이에요"


def test_spoken_cordarone_is_heartbeat():
    text = derive_easy_spoken(
        product_name="코다론정(아미오다론염산염)",
        efficacy="심방성부정맥, 심실성부정맥, 재발성중증 부정맥",
    )
    assert text == "심장 박동을 고르게 하는 약이에요"


def test_spoken_xanax_is_anxiety_not_heartburn():
    text = derive_easy_spoken(
        product_name="자낙스정0.25밀리그람(알프라졸람)",
        efficacy="불안장애의 치료 및 불안증상의 단기완화. 정신신체장애(위·십이지장궤양)에서의 불안",
    )
    assert text == "마음이 불안할 때 먹는 약이에요"


def test_spoken_unknown_fallback():
    assert derive_easy_spoken(product_name="무명정") == ""


def test_keyword_purpose_rows_are_not_joined_as_card_label():
    from app.services.pharmacist.easy_category import _compose_guidance

    guidance = _compose_guidance(
        [
            {
                "purpose_code": "알러지",
                "easy_label": "알레르기",
                "sentence": "가려움을 줄이는 데 쓰이는 약이에요.",
            },
            {
                "purpose_code": "두통",
                "easy_label": "두통",
                "sentence": "머리를 아프지 않게 하는 약이에요.",
            },
            {
                "purpose_code": "어지러움",
                "easy_label": "어지러움",
                "sentence": "처방받은 약이에요",
            },
        ],
        [],
    )
    assert guidance["purpose_label"] == ""
    assert "완화할 목적으로" in guidance["short_explanation"]


def test_strips_export_name():
    from app.services.pharmacist.easy_category import display_product_name

    assert "수출명" not in display_product_name(
        "휴온스시메티딘정200밀리그램(수출명:TAGAMENTTab.200밀리그램)"
    )


def test_key_cautions_from_precaution_keywords():
    guidance = medicine_guidance_from_medicine(
        {
            "product_name": "부루펜정200밀리그램(이부프로펜)",
            "ingredient": "이부프로펜",
            "precautions": (
                "졸음이 올 수 있으며 운전 및 기계조작을 피한다. "
                "임부에 투여하지 않는다. 음주 시 주의한다."
            ),
        }
    )
    codes = {item["caution_code"] for item in guidance["key_cautions"]}
    assert "DROWSINESS_DRIVING" in codes
    assert "PREGNANCY" in codes
    assert "ALCOHOL" in codes
    assert guidance["key_caution"]


def test_fallback_spoken_is_not_used_for_known_demo_names():
    from app.services.pharmacist.easy_category import derive_easy_spoken

    samples = [
        derive_easy_spoken(
            product_name="코다론정(아미오다론염산염)",
            efficacy="심방성부정맥, 심실성부정맥",
        ),
        derive_easy_spoken(
            product_name="부루펜정200밀리그램(이부프로펜)",
            efficacy="감기로 인한 발열 및 동통",
        ),
        derive_easy_spoken(
            product_name="게루삼정",
            efficacy="속쓰림, 위산과다",
        ),
    ]
    assert all(text != "처방받은 약이에요" for text in samples)
