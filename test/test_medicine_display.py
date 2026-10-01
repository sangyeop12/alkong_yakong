from app.services.medicine_display import (
    card_display_name,
    card_official_name,
    card_purpose_label,
    is_card_purpose_label,
    is_mock_drug_info_name,
    strip_export_alias,
    strip_easy_category_paren,
)


def test_mock_drug_info_names():
    assert is_mock_drug_info_name("아스피린 100mg")
    assert is_mock_drug_info_name("아스피린 100mg (피 묽게)")
    assert is_mock_drug_info_name("암로디핀5mg")
    assert is_mock_drug_info_name("메트포르민 500mg")
    assert not is_mock_drug_info_name("아스피린장용정100밀리그램")
    assert not is_mock_drug_info_name("히드록시진염산염")


def test_strips_keyword_paren_keeps_ingredient_paren():
    assert (
        strip_easy_category_paren("히드록시진염산염 (알레르기·두통·어지러움)")
        == "히드록시진염산염"
    )
    assert (
        card_display_name("아디팜정(히드록시진염산염)")
        == "아디팜정(히드록시진염산염)"
    )


def test_card_purpose_label_keeps_reviewed_relief_pair():
    label = card_purpose_label(
        [
            {"easy_label": "가려움 완화"},
            {"easy_label": "불안·긴장 완화"},
        ]
    )
    assert label == "가려움 완화 · 불안·긴장 완화"


def test_official_name_prefers_permission_product():
    assert (
        card_official_name(
            product_name="아디팜정(히드록시진염산염)",
            display_name="히드록시진염산염 (알레르기·두통·어지러움)",
            ingredient="히드록시진염산염",
        )
        == "아디팜정(히드록시진염산염)"
    )
    assert (
        card_official_name(
            product_name="휴온스시메티딘정200밀리그램",
            display_name="시메티딘 (속쓰림·위·소화·알레르기)",
            ingredient="시메티딘",
        )
        == "휴온스시메티딘정200밀리그램"
    )


def test_card_purpose_label_drops_symptom_keywords():
    assert is_card_purpose_label("알레르기") is False
    assert is_card_purpose_label("피가 굳지 않게 하는 약") is True
    assert is_card_purpose_label("해열제") is True
    assert (
        card_purpose_label(
            [
                {"easy_label": "알레르기"},
                {"easy_label": "두통"},
                {"easy_label": "어지러움"},
            ]
        )
        == ""
    )


def test_export_alias_is_removed_but_ingredient_parentheses_are_kept():
    assert (
        strip_export_alias("휴온스시메티딘정200밀리그램(수출명:TAGAMENT Tab.)")
        == "휴온스시메티딘정200밀리그램"
    )
    assert strip_export_alias("제품정(수출명 : TEST)(성분명)") == "제품정(성분명)"
    assert strip_export_alias("제품정(수출용)") == "제품정"
    assert strip_export_alias("아디팜정(히드록시진염산염)") == "아디팜정(히드록시진염산염)"
