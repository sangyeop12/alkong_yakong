"""허가 효능 원문을 화면에 읽히게 조금만 다듬는다. 문장을 요약하지 않는다."""

from __future__ import annotations

import re


# 번호 항목 앞에만 붙어 카드가 어색해지는 말. '수술후 구역' 같은 증상은 남긴다.
_HANGING_PREFIX = re.compile(r"수술\s*[전후]\s*,")
_JUNK_PHRASE = re.compile(r"주효능\s*[·.]?\s*효과")
_FORM_LABEL = re.compile(
    r"\((?:경구\s*[:：][^)]*|정제|캡슐제|시럽제|주사제|껌정)\)"
)


def display_efficacy_text(value: str | None) -> str | None:
    text = str(value or "").replace("\r\n", "\n").replace("\xa0", " ")
    if not text.strip():
        return None
    text = _HANGING_PREFIX.sub("", text)
    text = _JUNK_PHRASE.sub("", text)
    text = _FORM_LABEL.sub("", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n+ *", "\n", text)
    text = re.sub(r"(\d+\.)\s*,\s*", r"\1 ", text)
    text = re.sub(r",\s*,+", ",", text)
    text = re.sub(r"\s+,", ",", text)
    # 이미 줄바꿈된 효능은 번호를 지워도 줄을 유지한다.
    text = re.sub(r"(?<!\n)\s+(?=\d+\.(?:\s|[가-힣]))", "\n", text)
    text = re.sub(r"(?<!\n)\s+(?=\d+\)\s)", "\n", text)
    text = re.sub(r"\s*○\s*", "\n", text)
    text = re.sub(r"(?m)^\d+\.\s*", "", text)
    text = re.sub(r"(?m)^\d+\)\s*", "", text)
    lines: list[str] = []
    for raw_line in text.split("\n"):
        line = raw_line.strip(" ,·●○")
        if not line:
            continue
        lines.append(line)
    return "\n".join(lines) or None
