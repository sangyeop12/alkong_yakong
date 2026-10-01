from app.services.pharmacist.dur_why import (
    FALLBACK_WHY,
    enrich_matches,
    why_easy_for,
)


def test_arrhythmia_official_phrase_becomes_easy_why():
    why = why_easy_for(
        {
            "type": "병용금기",
            "official_reason": "심실부정맥 위험 증가",
        }
    )
    assert "심장 박동" in why
    assert "심실부정맥" not in why


def test_unknown_taboo_phrase_does_not_invent_a_cause():
    why = why_easy_for(
        {
            "type": "병용금기",
            "official_reason": "알려지지 않은 상호작용 XYZ",
        }
    )
    assert why == FALLBACK_WHY


def test_duplicate_and_efficacy_use_type_templates():
    assert "같은 성분" in why_easy_for({"type": "중복성분"})
    assert "비슷한 일" in why_easy_for({"type": "효능군중복"})


def test_why_does_not_branch_on_product_names():
    first = why_easy_for(
        {
            "type": "병용금기",
            "official_reason": "심실부정맥 위험 증가",
            "medicine_names_a": ["아디팜정"],
            "medicine_names_b": ["코다론정"],
        }
    )
    second = why_easy_for(
        {
            "type": "병용금기",
            "official_reason": "심실부정맥 위험 증가",
            "medicine_names_a": ["다른약A"],
            "medicine_names_b": ["다른약B"],
        }
    )
    assert first == second


def test_enrich_matches_fills_easy_lines_and_source():
    matches = enrich_matches(
        [
            {
                "type": "병용금기",
                "reason": "아디팜정 ↔ 코다론정 — 심실부정맥 위험 증가",
                "official_reason": "심실부정맥 위험 증가",
                "medicine_names_a": ["아디팜정"],
                "medicine_names_b": ["코다론정"],
                "medicine_codes_a": ["A"],
                "medicine_codes_b": ["B"],
            }
        ],
        [
            {
                "medicine_code": "A",
                "product_name": "아디팜정",
                "easy_category": "가려움 약",
            },
            {
                "medicine_code": "B",
                "product_name": "코다론정",
                "easy_category": "심장 박동 약",
            },
        ],
    )
    row = matches[0]
    assert row["easy_line_a"] == "아디팜정은 가려울 때 드시는 약이에요."
    assert row["easy_line_b"] == "코다론정은 심장 박동을 고르게 하려고 드시는 약이에요."
    assert row["source_label"] == "식약처 DUR 병용금기 참조"
    assert row["why_easy"].startswith("두 약을 같이 드시면,")
    assert "심장 박동" in row["why_easy"]


def test_together_opener_grows_with_medicine_count():
    matches = enrich_matches(
        [
            {
                "type": "중복성분",
                "medicine_names_a": ["약가", "약나", "약다"],
                "medicine_names_b": ["약가", "약나", "약다"],
                "medicine_codes_a": ["1", "2", "3"],
                "medicine_codes_b": ["1", "2", "3"],
            }
        ]
    )
    assert matches[0]["why_easy"].startswith("세 약을 같이 드시면,")


def test_pair_card_fields_share_arrow_easy_why_and_risk_factor():
    from app.services.dur_service import pair_card_fields

    fields = pair_card_fields(
        {
            "type": "병용금기",
            "official_reason": "심실부정맥 위험 증가",
            "medicine_names_a": ["아디팜정(히드록시진염산염)"],
            "medicine_names_b": ["코다론정(아미오다론염산염)"],
        }
    )
    assert fields["pair_label"] == "아디팜정 ↔ 코다론정"
    assert "심장" in fields["why_easy"]
    assert "심실부정맥" in fields["risk_factor"]
    assert "심실부정맥" not in fields["why_easy"]
