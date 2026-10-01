"""Extract medicine-name candidates without inventing a medicine."""

from __future__ import annotations

import re


_STOP_WORDS = {
    "약", "약이", "약은", "약을", "뭐", "뭐야", "무엇", "알려줘",
    "알려", "설명", "효능", "효과", "부작용", "주의사항", "복용법",
    "같이", "먹어도", "되나요", "되나", "언제", "어떻게", "안전",
}


def extract_drug_name_candidates(
    message: str,
    lexicon: list[str] | None = None,
) -> list[str]:
    text = (message or "").strip()
    if not text:
        return []

    candidates: list[str] = []
    for name in lexicon or []:
        if name and _compact(name) in _compact(text):
            candidates.append(name)
    if candidates:
        return candidates

    tokens = re.findall(r"[가-힣A-Za-z][가-힣A-Za-z0-9().-]*", text)
    return [token for token in tokens if token not in _STOP_WORDS and len(token) >= 2]


def _compact(value: str) -> str:
    return "".join(str(value or "").casefold().split())
