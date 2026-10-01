import re

from app.services.pharmacist.efficacy_display import display_efficacy_text


def test_keeps_line_breaks_without_list_numbers():
    raw = (
        "1. 수술 후, 신경증에서의 불안, 긴장, 초조 "
        "2. 두드러기, 피부질환에 수반하는 가려움(습진, 피부염, 피부가려움증)"
    )
    text = display_efficacy_text(raw)
    assert text is not None
    assert not re.search(r"^\d+\.", text)
    assert "1." not in text
    assert "2." not in text
    assert "불안, 긴장, 초조" in text
    assert "두드러기, 피부질환에 수반하는 가려움" in text
    assert "수술 후" not in text
    assert "가려움 약" not in text
    assert "\n" in text
    lines = text.split("\n")
    assert len(lines) == 2
    assert lines[0].startswith("신경증에서의")
    assert lines[1].startswith("두드러기")


def test_primalan_stays_as_api_list():
    raw = "두드러기, 고초열, 알레르기 비염, 가려움, 결막염"
    assert display_efficacy_text(raw) == raw


def test_strips_paren_list_numbers():
    raw = (
        "1) 다음 질환에서 혈전 생성 억제 2) 관상동맥 우회술 후 혈전 생성 억제 "
        "3) 고위험군환자에서 심혈관계 위험성 감소"
    )
    text = display_efficacy_text(raw)
    assert text is not None
    assert "1)" not in text
    assert "2)" not in text
    assert text.split("\n")[0].startswith("다음 질환")
    assert len(text.split("\n")) == 3


def test_keeps_postop_symptom_not_hanging_prefix():
    text = display_efficacy_text("1) 멀미 2) 수술후 구역·구토")
    assert text is not None
    assert "수술후 구역" in text
    assert "1)" not in text


def test_splits_number_without_space():
    text = display_efficacy_text(
        "1. 고칼륨혈증 2.심질환(G,I,K요법) 그 외 수분, 에너지 보급 3.약물.독물 중독"
    )
    assert text is not None
    assert "2." not in text
    assert "심질환" in text.split("\n")[1]


def test_strips_label_junk_keeps_symptoms():
    text = display_efficacy_text(
        "1. 주효능 효과 1) 다음 질환의 제산작용 및 증상의 개선 : 위염 2) 변비증"
    )
    assert text is not None
    assert "주효능" not in text
    assert "위염" in text
    assert "변비증" in text


def test_second_pass_keeps_newlines():
    first = display_efficacy_text(
        "1. 신경증에서의 불안, 긴장, 초조 2. 두드러기, 피부질환에 수반하는 가려움"
    )
    assert first == display_efficacy_text(first)


def test_dur_reason_uses_same_display_rules():
    from app.services.dur_service import _official_reason

    text = _official_reason("1. 병용하지 말 것 2. 의사와 상의", "fallback")
    assert "1." not in text
    assert "병용하지 말 것" in text.split("\n")[0]
    assert "의사와 상의" in text.split("\n")[1]
