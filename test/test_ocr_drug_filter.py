from app.services.ocr.parser import (
    _clean_drug_label,
    _is_plausible_drug_candidate,
    filter_to_source,
    strip_percent_strength,
    take_amount_for_display,
)


def test_strips_half_and_full_width_prescription_markers():
    variants = (
        "비)다이크로지정",
        "비 )다이크로지정",
        "비）다이크로지정",
        "비 ）다이크로지정",
    )
    assert {_clean_drug_label(value) for value in variants} == {"다이크로지정"}


def test_preserves_real_names_starting_with_bi():
    assert _clean_drug_label("비타민정") == "비타민정"
    assert _clean_drug_label("비오플정") == "비오플정"


def test_product_search_name_is_product_only():
    from app.services.ocr.parser import product_search_name
    from app.services.mfds_drug_permission.sync import _ocr_name_query_variants

    assert product_search_name("프레벨액0.25%") == "프레벨액"
    assert product_search_name("프레벨액 0.25%") == "프레벨액"
    assert product_search_name("토파씬정25mg") == "토파씬정"
    assert product_search_name("프리마라정1정2회7일") == "프리마라정"
    assert _ocr_name_query_variants("프레벨액0.25%", similar=False) == ["프레벨액"]


def test_strips_percent_strength_from_names():
    assert strip_percent_strength("프레벨액0.25%") == "프레벨액"
    assert strip_percent_strength("프레벨액 0.25%") == "프레벨액"
    assert _clean_drug_label("프레벨액0.25%(프레드니카르베이트)") == "프레벨액"
    assert "%" not in _clean_drug_label("비)프레베넥액0.25%")


def test_rejects_markers_headers_and_thumbnail_fragments():
    rejected = (
        "비)",
        "약품명",
        "투약량",
        "조제약사",
        "비)슈...",
        "비)바실...",
        "슈",
        "바실",
        "나주",
        "진정",
        "총수납금액",
    )
    assert all(not _is_plausible_drug_candidate(value) for value in rejected)


def test_accepts_clean_drug_candidates():
    accepted = (
        "비)다이크로지정",
        "휴터민세미정",
        "토파씬정25mg",
        "그린엠캡슐",
        "게보린",
    )
    assert all(_is_plausible_drug_candidate(value) for value in accepted)


def test_unknown_take_amount_is_not_replaced_with_one_pill():
    assert take_amount_for_display(None) == ""
    assert take_amount_for_display(None, times_per_take=2) == "2알"


def test_product_strength_is_never_a_take_amount():
    from app.services.ocr.parser import is_strength_dosage, persistable_take_dosage

    assert is_strength_dosage("200밀리그램") is True
    assert is_strength_dosage("0.25%") is True
    assert persistable_take_dosage("200밀리그램") is None
    assert persistable_take_dosage("0.25%") is None


def test_filter_drops_plausible_but_source_free_drug_name():
    result = filter_to_source(
        {"items": [{"drug_name": "타이레놀정", "duration_days": 7}]},
        "중앙성모의원 처방일 2026-09-09",
    )
    assert result["items"] == []
    assert result["discarded_names"] == ["타이레놀정"]


def test_filter_keeps_only_drug_rows_from_images_fixture_shape():
    raw = """
    미래팜약국
    투약량 횟수 일수
    비)다이크로지정 | 0.25 | 1 | 14
    비)휴터민세미정 | 0.5 | 1 | 14
    비)슈...
    """
    parsed = {
        "items": [
            {"drug_name": "비)다이크로지정", "frequency_per_day": 1, "duration_days": 14},
            {"drug_name": "비)휴터민세미정", "frequency_per_day": 1, "duration_days": 14},
            {"drug_name": "투약량"},
            {"drug_name": "비)슈..."},
        ]
    }

    result = filter_to_source(parsed, raw)

    assert [item["drug_name"] for item in result["items"]] == [
        "다이크로지정",
        "휴터민세미정",
    ]
    assert "비)슈..." in result["discarded_names"]
    assert "투약량" in result["discarded_names"]


def test_filter_keeps_official_name_when_source_has_ocr_typo():
    raw = "프리마라정1정2회7일 프레베넥액0.25%"
    parsed = {
        "items": [
            {"drug_name": "프리마란정"},
            {"drug_name": "프레벨액"},
        ]
    }
    result = filter_to_source(parsed, raw)
    assert [item["drug_name"] for item in result["items"]] == [
        "프리마란정",
        "프레벨액",
    ]


def test_infers_glued_ocr_rows_without_official_rename():
    from app.services.ocr.parser import parse_prescription_text

    raw = "프리마라정1정2회7일프레베넥액0.25%"
    result = parse_prescription_text(raw)
    assert result is not None
    names = [item["drug_name"] for item in result["items"]]
    assert "프리마라정" in names
    assert "프레베넥액" in names
    assert "프레베넥액0.25%" not in names
    assert all("%" not in name for name in names)
    assert "프리마란정" not in names
    assert "프레벨액" not in names
    liquid = next(item for item in result["items"] if item["drug_name"] == "프레베넥액")
    assert "0.25" in str(liquid.get("dosage") or "")
    prema = next(item for item in result["items"] if item["drug_name"] == "프리마라정")
    assert prema.get("times_per_take") == 1
    assert prema.get("frequency_per_day") == 2
    assert prema.get("duration_days") == 7


def test_table_take_amount_not_name_milligrams():
    from app.services.ocr.parser import parse_prescription_text

    raw = "휴온스시메티딘정200밀리그램 | 0.50 | 3 | 7"
    result = parse_prescription_text(raw)
    assert result is not None
    item = next(
        row
        for row in result["items"]
        if "시메티딘" in str(row.get("drug_name") or "")
    )
    assert item.get("dosage") == "0.50"
    assert "200" not in str(item.get("dosage") or "")
    assert "밀리그램" not in str(item.get("dosage") or "")


def test_normalize_does_not_copy_milligrams_from_name():
    from app.services.ocr.parser import _normalize_table_dosing

    items = _normalize_table_dosing(
        [
            {
                "drug_name": "휴온스시메티딘정200밀리그램",
                "dosage": "1 T",
                "unit": "T",
            }
        ]
    )
    assert "밀리그램" not in str(items[0].get("dosage") or "")
    assert items[0].get("times_per_take") == 1


def test_compact_scan_does_not_invent_naju_or_jinjung():
    from app.services.ocr.parser import parse_prescription_text

    raw = """
    옴니세프캡슐100밀리그람 | 약효 세균감염증 치료제 | 1캡슐 | 1일 3회 | 4일분
    헤라신정250밀리그램 | 1정 | 1일 3회 | 4일분
    주의사항 나주시 진정 취침전
    """
    result = parse_prescription_text(raw)
    assert result is not None
    names = [item["drug_name"] for item in result["items"]]
    assert "나주" not in names
    assert "진정" not in names
    assert any("옴니세프" in name for name in names)
    assert any("헤라신" in name for name in names)
