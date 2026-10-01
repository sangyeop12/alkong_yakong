import pytest

from app.services.pharmacist.generate import (
    MISSING_OFFICIAL_TEXT,
    apply_card_guard,
    validate_easy_output,
)


def test_validate_keeps_short_sentences():
    text = "이 약은 열을 내립니다. 통증을 줄여 줍니다."
    assert validate_easy_output(text) == text


def test_validate_clips_to_three_sentences():
    text = "첫째입니다. 둘째입니다. 셋째입니다. 넷째입니다."
    result = validate_easy_output(text)
    assert result == "첫째입니다. 둘째입니다. 셋째입니다."


def test_validate_rejects_long_sentence():
    long_sentence = "가" * 81
    with pytest.raises(ValueError, match="sentence_too_long"):
        validate_easy_output(long_sentence)


def test_validate_rejects_empty():
    with pytest.raises(ValueError, match="empty_reply"):
        validate_easy_output("   ")


def test_card_guard_keeps_source_overlap():
    source = (
        "제품명: 타이레놀정500밀리그램\n"
        "효능/효과: 감기로 인한 발열 및 동통\n"
        "복용법: 1회 1정 1일 3회 복용\n"
        "보관법: 실온에서 보관하십시오"
    )
    parsed = {
        "easy_summary": "타이레놀정500밀리그램은 감기로 인한 발열 및 동통에 씁니다.",
        "what_it_does": "감기로 인한 발열 및 동통을 가라앉힙니다.",
        "how_to_take": "1회 1정 1일 3회 복용합니다.",
        "cautions": ["이 약은 암을 치료합니다."],
        "possible_side_effects": ["공식 정보에 없는 환각 증상"],
        "storage": "실온에서 보관하십시오.",
        "ask_doctor_when": ["의사/약사와 상담하세요."],
        "source_based": True,
    }
    card = apply_card_guard(parsed, source)
    assert card is not None
    assert "타이레놀정500밀리그램" in card["easy_summary"]
    assert card["how_to_take"] != MISSING_OFFICIAL_TEXT
    assert card["cautions"] == [MISSING_OFFICIAL_TEXT]
    assert card["possible_side_effects"] == [MISSING_OFFICIAL_TEXT]
    assert card["source_based"] is True


def test_card_guard_rejects_all_invented_claims():
    source = "제품명: 타이레놀정500밀리그램\n효능/효과: 해열 및 진통"
    parsed = {
        "easy_summary": "이 약은 암을 완치합니다.",
        "what_it_does": "혈압을 낮춥니다.",
        "how_to_take": "하루 열 알씩 드세요.",
        "cautions": ["임의로 용량을 늘리세요."],
        "possible_side_effects": ["날개가 돋습니다."],
        "storage": "냉동실에 보관하세요.",
        "ask_doctor_when": ["의사/약사와 상담하세요."],
        "source_based": True,
    }
    assert apply_card_guard(parsed, source) is None
