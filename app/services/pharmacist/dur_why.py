"""DUR 충돌 이유를 쉬운말로 바꾼다. 약 이름 분기는 없다."""

from __future__ import annotations

import re
import unicodedata
from typing import Any

from app.services.medicine_display import omit_placeholder_spoken

FALLBACK_WHY = (
    "몸에 부담이 겹칠 수 있어요. "
    "약국이나 병원에 한 번 확인해 주세요."
)

TYPE_WHY = {
    "중복성분": "같은 성분이 들어 있어서, 양이 겹칩니다.",
    "효능군중복": "비슷한 일을 해서, 효과가 겹칩니다.",
    "연령금기": "지금 나이에는 이 약을 쓰면 안 돼요. 약국이나 병원에 한 번 확인해 주세요.",
    "임부금기": "임신 중에는 이 약을 쓰면 안 돼요. 약국이나 병원에 한 번 확인해 주세요.",
}

SOURCE_LABELS = {
    "병용금기": "식약처 DUR 병용금기 참조",
    "효능군중복": "식약처 DUR 효능군중복 참조",
    "중복성분": "같은 성분 중복 참조",
    "연령금기": "식약처 DUR 연령금기 참조",
    "임부금기": "식약처 DUR 임부금기 참조",
}

# 더 구체적인 말을 앞에 둔다. 약 이름이 아니라 공식 금기 문구만 본다.
_WHY_RULES: tuple[tuple[tuple[str, ...], str], ...] = (
    (
        ("토르사드", "torsade", "qt 연장", "qt연장", "qt 간격"),
        "심장 전기 신호에 겹쳐 영향을 줘서, 박동이 불규칙해질 수 있어요.",
    ),
    (
        ("심실부정맥", "부정맥", "서맥"),
        "심장 박동을 만드는 전기 신호에 영향을 줘서, "
        "박동이 느려지거나 불규칙해질 수 있어요.",
    ),
    (
        ("출혈", "항응고"),
        "피가 멈추는 일에 영향을 줘서, 피가 잘 안 멈출 수 있어요.",
    ),
    (
        ("저혈당", "혈당"),
        "혈당에 겹쳐 작용해서, 혈당이 너무 떨어질 수 있어요.",
    ),
    (
        ("호흡억제", "호흡 억제"),
        "숨 쉬는 일에 겹쳐 영향을 줘서, 숨이 느려질 수 있어요.",
    ),
    (
        ("진정", "졸음", "중추신경"),
        "잠·진정 쪽으로 겹쳐서, 너무 졸리거나 숨이 느려질 수 있어요.",
    ),
    (
        ("세로토닌",),
        "세로토닌 쪽에 겹쳐 작용해서, 몸에 부담이 커질 수 있어요.",
    ),
    (
        ("고칼륨",),
        "피 속 칼륨을 올리는 쪽으로 겹쳐서, 심장 박동에 부담이 될 수 있어요.",
    ),
    (
        ("횡문근",),
        "근육에 겹쳐 부담을 줘서, 근육이 상할 수 있어요.",
    ),
    (
        ("신독성", "신장 독"),
        "콩팥에 겹쳐 부담을 줘서, 콩팥에 무리가 될 수 있어요.",
    ),
    (
        ("간독성", "간손상", "간 손상"),
        "간에 겹쳐 부담을 줘서, 간에 무리가 될 수 있어요.",
    ),
)


def _norm(value: str | None) -> str:
    text = unicodedata.normalize("NFKC", str(value or ""))
    text = text.casefold()
    return re.sub(r"\s+", " ", text).strip()


_COUNT_WORDS = {
    2: "두",
    3: "세",
    4: "네",
    5: "다섯",
    6: "여섯",
    7: "일곱",
    8: "여덟",
    9: "아홉",
    10: "열",
}


def _short_product_name(name: str | None) -> str:
    text = str(name or "").strip()
    index = text.find("(")
    if index > 0:
        return text[:index].strip()
    return text


def _topic_josa(name: str) -> str:
    if not name:
        return "은"
    code = ord(name[-1])
    if code < 0xAC00 or code > 0xD7A3:
        return "은"
    return "은" if (code - 0xAC00) % 28 else "는"


def _spoken_b_for_category(label: str | None) -> str:
    from app.services.pharmacist.easy_category_db import SPOKEN_ROWS

    needle = str(label or "").strip()
    if not needle:
        return ""
    eat = ""
    any_sentence = ""
    for easy_label, route, sentence in SPOKEN_ROWS:
        if easy_label != needle:
            continue
        if route == "eat":
            eat = sentence
            break
        if not any_sentence:
            any_sentence = sentence
    return eat or any_sentence


def _purpose_clause(spoken: str) -> str:
    text = str(spoken or "").strip().rstrip(".")
    text = re.sub(r"\s*약이에요$", "", text).strip()
    text = re.sub(r"\s*(먹는|바르는|붙이는)$", "", text).strip()
    if "때" in text:
        return text
    text = text.replace("하는 데 쓰이는", "하려고")
    text = re.sub(r"고르게 하는$", "고르게 하려고", text)
    text = re.sub(r"하는$", "하려고", text)
    text = re.sub(r"이는$", "이려고", text)
    text = re.sub(r"추는$", "추려고", text)
    return text


def spoken_medicine_line(name: str | None, medicine: Any = None) -> str:
    """아디팜정은 가려울 때 드시는 약이에요."""
    short = _short_product_name(name)
    if not short:
        return ""
    category = ""
    if medicine is not None:
        try:
            category = str(medicine["easy_category"] or "").strip()
        except (KeyError, IndexError, TypeError):
            category = ""
    clause = _purpose_clause(_spoken_b_for_category(category))
    if not clause:
        short_line = _easy_line_from_medicine(medicine)
        clause = _purpose_clause(short_line) if short_line else ""
    if not clause:
        return ""
    return f"{short}{_topic_josa(short)} {clause} 드시는 약이에요."


def together_opener(count: int) -> str:
    if count <= 1:
        return ""
    word = _COUNT_WORDS.get(count)
    if word:
        return f"{word} 약을 같이 드시면, "
    return f"약 {count}가지를 같이 드시면, "


def _conflict_medicine_count(match: dict[str, Any]) -> int:
    names: list[str] = []
    for key in ("medicine_names_a", "medicine_names_b"):
        raw = match.get(key) or []
        if not isinstance(raw, list):
            continue
        for value in raw:
            short = _short_product_name(str(value))
            if short and short not in names:
                names.append(short)
    if len(names) >= 2:
        return len(names)
    codes: list[str] = []
    for key in ("medicine_codes_a", "medicine_codes_b"):
        raw = match.get(key) or []
        if not isinstance(raw, list):
            continue
        for value in raw:
            code = str(value or "").strip()
            if code and code not in codes:
                codes.append(code)
    return max(len(names), len(codes), 0)


def with_together_opener(match: dict[str, Any], body: str) -> str:
    text = str(body or "").strip()
    if not text:
        return ""
    if re.match(r"^(두|세|네|다섯|여섯|일곱|여덟|아홉|열) 약을 같이 드시면,", text):
        return text
    count = _conflict_medicine_count(match)
    opener = together_opener(count if count >= 2 else 2)
    return f"{opener}{text}"


def official_cause(match: dict[str, Any]) -> str:
    explicit = str(match.get("official_reason") or "").strip()
    if explicit:
        return explicit
    text = str(match.get("reason") or "").strip()
    sep = text.find(" — ")
    if sep >= 0:
        text = text[sep + 3 :].strip()
    return text.rstrip(" .")


def why_easy_for(match: dict[str, Any]) -> str:
    risk_type = str(match.get("type") or "").strip()
    typed = TYPE_WHY.get(risk_type)
    if typed:
        return typed
    if risk_type != "병용금기":
        return FALLBACK_WHY
    haystack = _norm(official_cause(match))
    if not haystack:
        return FALLBACK_WHY
    for needles, sentence in _WHY_RULES:
        if any(_norm(needle) in haystack for needle in needles):
            return sentence
    return FALLBACK_WHY


def source_label_for(match: dict[str, Any]) -> str:
    risk_type = str(match.get("type") or "").strip()
    return SOURCE_LABELS.get(risk_type, "식약처 DUR 참조")


def _easy_line_from_medicine(medicine: Any) -> str:
    if medicine is None:
        return ""
    try:
        short = omit_placeholder_spoken(medicine["short_explanation"])
    except (KeyError, IndexError, TypeError):
        short = ""
    if short:
        return short
    try:
        category = omit_placeholder_spoken(medicine["easy_category"])
    except (KeyError, IndexError, TypeError):
        category = ""
    return category


def _first_name(values) -> str:
    if not isinstance(values, list):
        return ""
    for value in values:
        short = _short_product_name(str(value))
        if short:
            return short
    return ""


def _medicine_for_codes(codes: list | None, by_code: dict[str, Any]) -> Any:
    for raw in codes or []:
        code = str(raw or "").strip()
        if code in by_code:
            return by_code[code]
    return None


def enrich_matches(matches: list[dict], medicines: list | None = None) -> list[dict]:
    """분석이 끝난 match에 화면용 쉬운 필드를 붙인다."""
    by_code: dict[str, Any] = {}
    for medicine in medicines or []:
        try:
            code = str(medicine["medicine_code"] or "").strip()
        except (KeyError, IndexError, TypeError):
            continue
        if code:
            by_code[code] = medicine

    enriched: list[dict] = []
    for match in matches or []:
        if not isinstance(match, dict):
            continue
        row = dict(match)
        med_a = _medicine_for_codes(row.get("medicine_codes_a"), by_code)
        med_b = _medicine_for_codes(row.get("medicine_codes_b"), by_code)
        if med_b is med_a:
            codes_a = [str(value).strip() for value in (row.get("medicine_codes_a") or [])]
            unique = list(dict.fromkeys(code for code in codes_a if code))
            if len(unique) > 1:
                med_b = by_code.get(unique[1])
        name_a = _first_name(row.get("medicine_names_a"))
        name_b = _first_name(row.get("medicine_names_b"))
        if not name_a and med_a is not None:
            try:
                name_a = _short_product_name(med_a["product_name"])
            except (KeyError, IndexError, TypeError):
                name_a = ""
        if (not name_b or name_b == name_a) and med_b is not None:
            try:
                name_b = _short_product_name(med_b["product_name"])
            except (KeyError, IndexError, TypeError):
                name_b = name_b
        row["easy_line_a"] = spoken_medicine_line(name_a, med_a)
        row["easy_line_b"] = spoken_medicine_line(name_b, med_b)
        if str(row.get("type") or "") in {"병용금기", "중복성분", "효능군중복"}:
            row["why_easy"] = with_together_opener(row, why_easy_for(row))
        else:
            row["why_easy"] = why_easy_for(row)
        row["source_label"] = source_label_for(row)
        enriched.append(row)
    return enriched
