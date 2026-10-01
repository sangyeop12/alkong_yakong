"""Clean official ingredient strings so DUR matching can use them."""

from __future__ import annotations

import re
from typing import Any


_PLACEHOLDERS = {
    "",
    "없음",
    "미상",
    "확인중",
    "확인 중",
    "공식 정보에 명시되어 있지 않습니다.",
}

_SALT_SUFFIXES = (
    "브롬화수소산염",
    "베실산염",
    "말레산염",
    "시트르산염",
    "푸마르산염",
    "타르타르산염",
    "주석산염",
    "메실산염",
    "염산염",
    "황산염",
    "인산염",
    "아세트산염",
    "탄산염",
    "수화물",
)


def clean_ingredient_text(value: Any) -> str:
    text = str(value or "").strip()
    if not text or text in _PLACEHOLDERS or text.casefold() in {"none", "null"}:
        return ""
    text = re.sub(r"<[^>]+>", " ", text)
    # 식약처 원료코드 [M051756] 같은 것은 화면에 보이면 안 된다.
    text = re.sub(r"\[[A-Za-z]?\d{4,}\]", " ", text)
    text = re.sub(r"\b[A-Za-z]\d{5,}\b", " ", text)
    text = re.sub(r"\s+", " ", text).strip(" ,;/|")
    # "시메티딘| 시메티딘"처럼 같은 성분이 반복되면 하나만 남긴다.
    parts = [
        part.strip()
        for part in re.split(r"[|,;/·]| 및 ", text)
        if part.strip()
    ]
    if len(parts) > 1:
        text = "|".join(dict.fromkeys(parts))
    if text in _PLACEHOLDERS:
        return ""
    return text


def normalize_ingredient(value: str | None) -> str:
    text = clean_ingredient_text(value).casefold()
    text = re.sub(
        r"\d+(?:\.\d+)?\s*(?:mg|ml|g|㎎|밀리그램|밀리그람|마이크로그램|%|정|캡슐)",
        "",
        text,
    )
    text = re.sub(r"[^0-9a-z가-힣]", "", text)
    return text


def ingredient_keys(value: str | None) -> tuple[str, ...]:
    """DUR 조회용 키. 염·수화물 접미를 떼 공식 성분명과 맞춘다.

    암로디핀베실산염 → 암로디핀. 에스암로디핀은 그대로 두어 암로디핀과 섞지 않는다.
    """
    cleaned = clean_ingredient_text(value)
    if not cleaned:
        return ()
    keys: list[str] = []
    seen: set[str] = set()

    def _add(raw: str) -> None:
        key = normalize_ingredient(raw)
        if len(key) < 2 or key in seen:
            return
        seen.add(key)
        keys.append(key)
        stripped = key
        for suffix in _SALT_SUFFIXES:
            salt = normalize_ingredient(suffix)
            if salt and stripped.endswith(salt) and len(stripped) - len(salt) >= 2:
                stripped = stripped[: -len(salt)]
                if stripped not in seen:
                    seen.add(stripped)
                    keys.append(stripped)

    parts = [part for part in re.split(r"[|,;/·]| 및 ", cleaned) if part.strip()]
    for part in parts:
        _add(part)
    return tuple(keys)


def primary_ingredient_key(value: str | None) -> str:
    keys = ingredient_keys(value)
    if not keys:
        return ""
    return min(keys, key=len)


def primary_ingredient_keys(value: str | None) -> tuple[str, ...]:
    cleaned = clean_ingredient_text(value)
    if not cleaned:
        return ()
    result: list[str] = []
    for part in (part.strip() for part in cleaned.split("|")):
        key = primary_ingredient_key(part)
        if key and key not in result:
            result.append(key)
    return tuple(result)


def is_usable_ingredient(ingredient: Any, product_name: Any = None) -> bool:
    cleaned = clean_ingredient_text(ingredient)
    if not cleaned:
        return False
    product = clean_ingredient_text(product_name)
    if product and normalize_ingredient(cleaned) == normalize_ingredient(product):
        return False
    return bool(normalize_ingredient(cleaned))
