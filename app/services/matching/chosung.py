"""Korean initial-consonant (chosung) helpers for senior autocomplete."""

from __future__ import annotations

CHOSUNG = (
    "ㄱ",
    "ㄲ",
    "ㄴ",
    "ㄷ",
    "ㄸ",
    "ㄹ",
    "ㅁ",
    "ㅂ",
    "ㅃ",
    "ㅅ",
    "ㅆ",
    "ㅇ",
    "ㅈ",
    "ㅉ",
    "ㅊ",
    "ㅋ",
    "ㅌ",
    "ㅍ",
    "ㅎ",
)
_CHOSUNG_SET = set(CHOSUNG)


def to_chosung(value: str) -> str:
    result: list[str] = []
    for char in str(value or ""):
        if "가" <= char <= "힣":
            result.append(CHOSUNG[(ord(char) - ord("가")) // 588])
        elif char in _CHOSUNG_SET:
            result.append(char)
    return "".join(result)


def is_chosung_query(value: str) -> bool:
    compact = "".join(str(value or "").split())
    return bool(compact) and all(char in _CHOSUNG_SET for char in compact)
