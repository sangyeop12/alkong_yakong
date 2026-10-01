from app.database import get_connection
from app.services.matching.name_matcher import match_medicine_name


# e약은요 표기 형태의 공식 제품명 fixture.
OFFICIAL_LEXICON = [
    "타이레놀정500밀리그램",
    "부루펜정200밀리그램(이부프로펜)",
    "게보린정",
    "아스피린장용정",
]


def test_official_spacing_normalizes():
    result = match_medicine_name("타이레놀정 500밀리그램", OFFICIAL_LEXICON)
    assert result.matched_name == "타이레놀정500밀리그램"
    assert result.method in {"normalized", "medicine_key"}
    assert result.score >= 0.90


def test_official_short_name_matches_product():
    result = match_medicine_name("게보린", OFFICIAL_LEXICON)
    assert result.matched_name == "게보린정"
    assert result.score >= 0.90


def test_official_korean_milligram_key():
    result = match_medicine_name("타이레놀", OFFICIAL_LEXICON)
    assert result.matched_name == "타이레놀정500밀리그램"
    assert result.method == "medicine_key"


def test_official_parentheses_ignored():
    result = match_medicine_name("부루펜정200밀리그램", OFFICIAL_LEXICON)
    assert result.matched_name == "부루펜정200밀리그램(이부프로펜)"
    assert result.score >= 0.90


def test_official_typo_not_auto_accepted():
    result = match_medicine_name("타이래놀", OFFICIAL_LEXICON)
    assert result.matched_name is None
    assert result.score < 0.90


def test_db_product_names_if_present():
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT product_name FROM medicines
            WHERE product_name IS NOT NULL AND product_name != ''
            """
        ).fetchall()
    finally:
        conn.close()
    lexicon = [row["product_name"] for row in rows] or OFFICIAL_LEXICON
    sample = lexicon[0]
    exact = match_medicine_name(sample, lexicon)
    assert exact.matched_name == sample
    assert exact.method == "exact"
    spaced = match_medicine_name(f"{sample[0]} {sample[1:]}", lexicon)
    assert spaced.matched_name == sample
    assert spaced.score >= 0.90
