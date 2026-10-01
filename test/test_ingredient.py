from app.services.pharmacist.ingredient import (
    clean_ingredient_text,
    ingredient_keys,
    is_usable_ingredient,
    primary_ingredient_key,
    primary_ingredient_keys,
)


def test_strips_xml_and_placeholder():
    assert clean_ingredient_text("<INGR>암로디핀베실산염</INGR>") == "암로디핀베실산염"
    assert clean_ingredient_text("공식 정보에 명시되어 있지 않습니다.") == ""
    assert not is_usable_ingredient("암로디핀정", "암로디핀정")


def test_salt_suffix_matches_dur_core():
    keys = ingredient_keys("암로디핀베실산염")
    assert "암로디핀베실산염" in keys
    assert "암로디핀" in keys
    assert primary_ingredient_key("암로디핀베실산염") == "암로디핀"


def test_esamlodipine_does_not_collapse_to_amlodipine():
    keys = ingredient_keys("에스암로디핀")
    assert "에스암로디핀" in keys
    assert "암로디핀" not in keys


def test_compound_ingredient_separators_and_deduplication():
    assert ingredient_keys("성분A") == ("성분a",)
    assert ingredient_keys("성분A|성분B|성분C") == ("성분a", "성분b", "성분c")
    assert ingredient_keys("성분A, 성분B, 성분C") == ("성분a", "성분b", "성분c")
    assert ingredient_keys("성분A/성분B;성분C 및 성분D") == (
        "성분a",
        "성분b",
        "성분c",
        "성분d",
    )
    assert ingredient_keys("성분A|성분A,성분B") == ("성분a", "성분b")
    assert primary_ingredient_keys("성분A|성분B|성분A") == ("성분a", "성분b")
