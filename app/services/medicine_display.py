"""Home/list card display rules shared by today-medicines and user medicines."""

from __future__ import annotations

import re

_MOCK_COMPACT = frozenset(
    {
        "아스피린100mg",
        "암로디핀5mg",
        "메트포르민500mg",
    }
)

_WS = re.compile(r"\s+")
_TRAILING_PAREN = re.compile(r"\s*\(([^)]*)\)\s*$")
_PERMISSION_NAME_HINT = re.compile(r"(정|캡슐|캅셀|액|시럽|연고|밀리그램|밀리그람)")
_EXPORT_PAREN = re.compile(
    r"\s*\((?:수출\s*명\s*[:：]?|수출\s*용|수출용\s*별칭)[^)]*\)",
    re.I,
)
_STRENGTH = re.compile(
    r"\d+(?:\.\d+)?\s*(?:mg|mL|g|%|밀리그램|밀리그람|밀리리터)",
    re.I,
)
_TAKE_AMOUNT = re.compile(
    r"^(\d+(?:\.\d+)?)\s*(알|정|캡슐|포|개|mL|ml|방울)$",
    re.I,
)

# 예전 괄호 분류·사전 표기를 지금 DB 쉬운말로 맞춘다.
EASY_LABEL_ALIASES = {
    "피 묽게 하는 약": "피가 굳지 않게 하는 약",
    "피 묽게": "피가 굳지 않게 하는 약",
    "피를 묽게 하는 약": "피가 굳지 않게 하는 약",
    "혈압 낮춤": "혈압약",
    "혈당 조절": "당뇨약",
}

PLACEHOLDER_SPOKEN = "처방받은 약이에요"
SPOKEN_ALIASES = {
    "피를 묽게 하는 약이에요": "피가 굳지 않게 하는 약이에요",
    "피를 묽게 하는 약이에요.": "피가 굳지 않게 하는 약이에요",
}


def normalize_easy_label(label: str | None) -> str:
    text = str(label or "").strip()
    return EASY_LABEL_ALIASES.get(text, text)


def strip_export_alias(name: str | None) -> str:
    text = str(name or "").strip()
    if not text:
        return ""
    return _WS.sub(" ", _EXPORT_PAREN.sub("", text)).strip(" /")


def ingredient_strength_from(
    ingredient: str | None,
    product_name: str | None,
) -> str:
    for raw in (ingredient, product_name):
        match = _STRENGTH.search(str(raw or ""))
        if match:
            return _WS.sub("", match.group(0))
    return ""


def split_take_amount(value: str | None) -> tuple[str | None, str | None]:
    match = _TAKE_AMOUNT.fullmatch(str(value or "").strip())
    if not match:
        return None, None
    amount = f"{float(match.group(1)):.3f}".rstrip("0").rstrip(".")
    raw_unit = match.group(2)
    unit = "알" if raw_unit == "정" else ("mL" if raw_unit.lower() == "ml" else raw_unit)
    return amount, unit


def infer_dosage_form(name: str | None) -> str:
    text = strip_export_alias(name)
    for token, label in (
        ("점안", "점안제"),
        ("안연고", "안연고"),
        ("연고", "연고"),
        ("크림", "크림"),
        ("패취", "패치"),
        ("패치", "패치"),
        ("플라스타", "패치"),
        ("캡슐", "캡슐"),
        ("시럽", "시럽"),
        ("액", "액제"),
        ("정", "정제"),
    ):
        if token in text:
            return label
    return ""


def strip_easy_category_paren(name: str | None) -> str:
    """이름 뒤에 붙인 분류 괄호만 뗀다. 허가명 속 성분명 괄호는 남긴다."""
    text = str(name or "").strip()
    match = _TRAILING_PAREN.search(text)
    if not match:
        return text
    inner = match.group(1).strip()
    if _is_category_paren(inner):
        return text[: match.start()].strip()
    return text


def _is_category_paren(inner: str) -> bool:
    text = normalize_easy_label(inner)
    if "·" in text or "," in text:
        return True
    if is_card_purpose_label(text):
        return True
    if any(token in inner for token in ("묽게", "낮춤", "조절", "속쓰림", "알레르기", "두통")):
        return True
    return False


def card_display_name(name: str | None) -> str:
    return strip_easy_category_paren(name) or "약"


def looks_like_permission_product_name(name: str | None) -> bool:
    text = strip_easy_category_paren(name)
    return bool(text and _PERMISSION_NAME_HINT.search(text))


def card_official_name(
    *,
    product_name: str | None = None,
    display_name: str | None = None,
    ingredient: str | None = None,
) -> str:
    """허가 제품명을 제목으로 쓴다. 성분+키워드 괄호는 제목이 아니다."""
    candidates = (product_name, display_name, ingredient)
    for raw in candidates:
        stripped = strip_easy_category_paren(strip_export_alias(raw))
        if not stripped:
            continue
        if looks_like_permission_product_name(raw) or looks_like_permission_product_name(
            stripped
        ):
            return stripped
    for raw in candidates:
        stripped = strip_easy_category_paren(strip_export_alias(raw))
        if stripped:
            return stripped
    return "약"


def is_mock_drug_info_name(*names: str | None) -> bool:
    """DrugInfo 데모 이름만 걸러 낸다. 허가명(아스피린장용정 등)은 통과한다."""
    for raw in names:
        compact = _WS.sub("", strip_easy_category_paren(raw)).lower()
        if not compact:
            continue
        if compact in _MOCK_COMPACT:
            return True
    return False


def omit_placeholder_spoken(text: str | None) -> str:
    value = str(text or "").strip()
    value = SPOKEN_ALIASES.get(value, value)
    if not value or value == PLACEHOLDER_SPOKEN:
        return ""
    return value


def split_ingredients(raw: str | None) -> list[str]:
    """카드 축약에 쓸 성분 목록. 공식 원문은 변경하지 않는다."""
    parts = [part.strip() for part in re.split(r"[|;\r\n]+", str(raw or ""))]
    return list(dict.fromkeys(part for part in parts if part))


def ingredient_summary(raw: str | None) -> str:
    parts = split_ingredients(raw)
    if not parts:
        return ""
    if len(parts) == 1:
        return parts[0]
    return f"{parts[0]} 외 {len(parts) - 1}개"


def is_card_purpose_label(label: str | None, *, review_status: str | None = None) -> bool:
    """짧은 분류로 쓸 수 있는 쉬운말인지."""
    text = normalize_easy_label(label)
    if not text:
        return False
    if str(review_status or "").upper() == "REVIEWED":
        return True
    if "완화" in text or "약이에요" in text:
        return True
    if text.endswith(("약", "제")) or "하는 약" in text:
        return True
    return False


def card_purpose_label(purposes: list[dict]) -> str:
    labels = []
    seen: set[str] = set()
    for item in purposes:
        label = normalize_easy_label(item.get("easy_label"))
        status = str(item.get("review_status") or "")
        if not is_card_purpose_label(label, review_status=status) or label in seen:
            continue
        seen.add(label)
        labels.append(label)
    return " · ".join(labels)
