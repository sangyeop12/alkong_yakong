from app.services.matching.name_matcher import match_medicine_name


LEXICON = ["타이레놀정500밀리그램", "부루펜정200밀리그램(이부프로펜)", "게보린정"]


def test_exact_match():
    result = match_medicine_name("게보린정", LEXICON)
    assert result.method == "exact"
    assert result.matched_name == "게보린정"


def test_typo_not_auto_accepted():
    result = match_medicine_name("타이래놀", LEXICON)
    assert result.matched_name is None
    assert result.method == "none"
    assert result.score < 0.90


def test_one_char_ocr_typo_matches_when_similar():
    result = match_medicine_name("프리마라정", ["프리마란정"], similar=True)
    assert result.matched_name == "프리마란정"
    assert result.score >= 0.80
    result = match_medicine_name("", LEXICON)
    assert result.matched_name is None
    assert result.method == "none"


def test_similar_false_does_not_confirm_ocr_typo():
    result = match_medicine_name("프리마라정", ["프리마란정"], similar=False)
    assert result.matched_name is None
    result = match_medicine_name("프레베넥액", ["프레벨액0.25%(프레드니카르베이트)"], similar=False)
    assert result.matched_name is None


def test_dichlozid_ocr_fold_and_truncated_overlay():
    official = "다이크로짙정(히드로클로로티아지드)"
    result = match_medicine_name("다이크로징", [official], similar=True)
    assert result.matched_name == official
    from app.services.matching.name_matcher import line_matches_drug_name

    assert line_matches_drug_name("다이크로징", official)
    assert line_matches_drug_name("다이크로짙정 (히드로클로", official)
    assert line_matches_drug_name("다이크로짙정", "다이크로짙정")


def test_premaran_and_prebel_ocr_typos_align():
    from app.services.matching.name_matcher import line_matches_drug_name

    assert line_matches_drug_name("프리마라정", "프리마란정(케토티펜)")
    assert line_matches_drug_name("프레베넥액", "프레벨액0.25%(프레드니카르베이트)")
    result = match_medicine_name(
        "프레베넥액",
        ["프레벨액0.25%(프레드니카르베이트)"],
        similar=True,
    )
    assert result.matched_name == "프레벨액0.25%(프레드니카르베이트)"


def test_does_not_treat_cold_variant_as_same_drug():
    from app.services.matching.name_matcher import names_correspond

    assert not names_correspond("타이레놀", "타이레놀콜드")
    result = match_medicine_name(
        "타이레놀",
        ["타이레놀콜드정", "타이레놀정500밀리그램"],
    )
    assert result.matched_name == "타이레놀정500밀리그램"


def test_truncated_prefix_keeps_same_product_only():
    from app.services.matching.name_matcher import names_correspond

    official = "피엠에스플루옥세틴캡슐10밀리그램"
    assert names_correspond("피엠에스플루옥세틴캡슐10", official)
    assert not names_correspond("피엠에스", official)
