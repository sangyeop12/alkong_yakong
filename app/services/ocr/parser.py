"""Prescription raw text to structured medicine data."""

from __future__ import annotations

import json
import re
import unicodedata
from typing import Any

# 앱·DB가 기대하는 정형 필드. drug_name만 필수, 나머지는 원문에 있을 때만 채운다.
PRESCRIPTION_SCHEMA = {
    "type": "object",
    "properties": {
        "hospital_name": {"type": "string"},
        "pharmacy_name": {"type": "string"},
        "prescribed_date": {"type": "string"},
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "drug_name": {"type": "string"},
                    "dosage": {"type": "string"},
                    "unit": {"type": "string"},
                    "frequency_per_day": {"type": "integer"},
                    "times_per_take": {"type": "integer"},
                    "duration_days": {"type": "integer"},
                    "easy_explanation": {"type": "string"},
                    "warning_note": {"type": "string"},
                },
                "required": ["drug_name"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["items"],
    "additionalProperties": False,
}

# 병원·약국·처방일은 참고용일 뿐 점수에 넣지 않는다.
HEADER_FIELDS = ("hospital_name", "pharmacy_name", "prescribed_date")
# 사용자 인식 점수는 약품명·성분만 본다. 횟수·일수는 문서에 없을 수 있다.
SCORE_FIELDS = ("drug_name", "ingredient")

# 제품명 함량(200밀리그램, 0.25%) — 처방 표의 투약량(0.50, 1알)과 구분한다.
_STRENGTH_DOSAGE_RE = re.compile(
    r"(?:mg|ml|g|%|밀리그램|밀리그람)(?:\b|(?=\s|$|[),/]))",
    re.IGNORECASE,
)


def is_strength_dosage(value: str | None) -> bool:
    """함량 표기면 True. 0.50 / 1알 / 1정 같은 투약량은 False."""
    return bool(_STRENGTH_DOSAGE_RE.search(str(value or "").strip()))


def persistable_take_dosage(value: str | None) -> str | None:
    text = str(value or "").strip()
    if not text or is_strength_dosage(text):
        return None
    if re.match(
        r"^\d+(?:\.\d+)?\s*(T|C|EA|PKG)$",
        text.replace(" ", ""),
        re.IGNORECASE,
    ):
        return None
    return text


def _should_replace_dosage_with_table(existing: str) -> bool:
    if not existing:
        return True
    if is_strength_dosage(existing):
        return True
    return bool(
        re.match(
            r"^\d+(?:\.\d+)?\s*(T|C|EA|PKG|정|캡슐)$",
            existing.replace(" ", ""),
            re.IGNORECASE,
        )
    )


def take_amount_for_display(
    dosage: str | None,
    *,
    times_per_take: int | float | None = None,
) -> str:
    take = persistable_take_dosage(dosage)
    if take:
        return take
    if times_per_take is not None:
        try:
            n = float(times_per_take)
        except (TypeError, ValueError):
            n = 0
        if n > 0:
            if n == int(n):
                return f"{int(n)}알"
            text = f"{n:.2f}".rstrip("0").rstrip(".")
            return text
    # 처방전에서 확인하지 못한 복용량을 임의로 "1알"로 만들지 않는다.
    return ""


def parse_prescription_text(
    raw_text: str,
    *,
    tables: list[dict[str, Any]] | tuple[dict[str, Any], ...] | None = None,
) -> dict[str, Any] | None:
    """CLOVA 원문을 외부 생성 모델 없이 결정적으로 구조화한다."""
    text = (raw_text or "").strip()
    if not text:
        return None

    parsed = _parse_with_heuristic(text)
    parser_engine = "heuristic"
    if not parsed:
        parsed = {"items": []}
        parser_engine = "heuristic"

    table_items = _items_from_clova_tables(tables or ())
    if table_items:
        # 표 행의 값이 같은 이름 주변에서 추측한 숫자보다 우선한다.
        parsed["items"] = [*table_items, *(parsed.get("items") or [])]
        parser_engine = "heuristic+clova-table"

    parsed = expand_inferred_drug_items(parsed, text)
    if not parsed.get("items"):
        return None

    filtered = filter_to_source(parsed, text)
    if not filtered.get("items"):
        return None
    filtered = enrich_dosing_from_raw(filtered, text)
    filtered = correct_drug_names(filtered)

    if not filtered.get("items"):
        return None
    filtered["items"] = _normalize_table_dosing(filtered["items"])
    filtered["items"] = _merge_duplicate_drugs(filtered["items"])
    if not filtered.get("items"):
        return None
    filtered["field_coverage"] = measure_field_coverage(filtered)
    filtered["parser_engine"] = parser_engine
    return filtered


def _clova_cell_text(cell: dict[str, Any]) -> str:
    """CLOVA 표 셀의 여러 응답 형태에서 읽힌 문자열을 꺼낸다."""
    direct = cell.get("inferText") or cell.get("text")
    if direct:
        return str(direct).strip()

    parts: list[str] = []
    for line in cell.get("cellTextLines") or []:
        if not isinstance(line, dict):
            continue
        words = line.get("cellWords") or line.get("words") or []
        line_parts = []
        for word in words:
            if not isinstance(word, dict):
                continue
            value = word.get("inferText") or word.get("text")
            if value:
                line_parts.append(str(value).strip())
        if line_parts:
            parts.append(" ".join(line_parts))
    return "\n".join(parts).strip()


def _table_header_role(text: str) -> str | None:
    compact = _compact(text)
    if any(word in compact for word in ("투약일수", "복용일수", "처방일수")) or compact in {
        "일수",
        "투약일",
    }:
        return "duration_days"
    if "1회" in compact and any(word in compact for word in ("투약량", "복용량", "사용량")):
        return "dosage"
    if any(word in compact for word in ("투약량", "복용량", "사용량")) and "일수" not in compact:
        return "dosage"
    if "1일" in compact and any(word in compact for word in ("투여횟수", "복용횟수", "횟수")):
        return "frequency_per_day"
    if any(word in compact for word in ("투여횟수", "복용횟수", "1일횟수", "횟수")):
        return "frequency_per_day"
    if any(word in compact for word in ("약품명", "의약품명", "제품명")):
        return "drug_name"
    return None


def _table_number(text: str, *, integer: bool = False) -> str | int | None:
    match = re.search(r"(?<!\d)(\d+(?:\.\d+)?)(?!\d)", str(text or ""))
    if not match:
        return None
    value = match.group(1)
    if not integer:
        return value
    try:
        return int(float(value))
    except ValueError:
        return None


def _items_from_clova_tables(
    tables: list[dict[str, Any]] | tuple[dict[str, Any], ...],
) -> list[dict[str, Any]]:
    """CLOVA 표 좌표로 약명과 1회량·횟수·일수를 같은 행에 묶는다."""
    items: list[dict[str, Any]] = []
    for table in tables:
        if not isinstance(table, dict):
            continue
        rows: dict[int, dict[int, str]] = {}
        for cell in table.get("cells") or []:
            if not isinstance(cell, dict):
                continue
            try:
                row_index = int(cell.get("rowIndex"))
                column_index = int(cell.get("columnIndex"))
            except (TypeError, ValueError):
                continue
            value = _clova_cell_text(cell)
            if value:
                rows.setdefault(row_index, {})[column_index] = value
        if not rows:
            continue

        roles: dict[str, int] = {}
        role_rows: dict[str, int] = {}
        header_row = -1
        for row_index in sorted(rows):
            for column, value in rows[row_index].items():
                role = _table_header_role(value)
                if role is not None and role not in roles:
                    roles[role] = column
                    role_rows[role] = row_index
            if {
                "drug_name",
                "dosage",
                "frequency_per_day",
                "duration_days",
            }.issubset(roles):
                header_row = max(role_rows.values())
                break
        required = {"drug_name", "dosage", "frequency_per_day", "duration_days"}
        if not required.issubset(roles):
            continue

        for row_index in sorted(index for index in rows if index > header_row):
            row = rows[row_index]
            drug_cell = row.get(roles["drug_name"], "")
            candidates = iter_glued_drug_tokens(drug_cell)
            if not candidates:
                continue
            item = dict(candidates[0])
            dosage = _table_number(row.get(roles["dosage"], ""))
            frequency = _table_number(
                row.get(roles["frequency_per_day"], ""), integer=True
            )
            duration = _table_number(
                row.get(roles["duration_days"], ""), integer=True
            )
            if dosage is not None:
                item["dosage"] = dosage
            if frequency is not None:
                item["frequency_per_day"] = frequency
            if duration is not None:
                item["duration_days"] = duration
            items.append(item)
    return items


def _parse_with_heuristic(text: str) -> dict[str, Any] | None:
    """CLOVA 원문에서 약 줄을 결정적 규칙으로 뽑는다."""
    if not text.strip():
        return None

    hospital = None
    pharmacy = None
    prescribed = None
    for pattern, key in (
        (r"(미래의원|[\w가-힣]+의원|[\w가-힣]+병원)", "hospital"),
        (r"(?:조제약\s*사|약사)\s*:?\s*([가-힣]{2,4})", "pharmacy"),
        (r"(?:조제\s*일\s*자|처방일자)\s*:?\s*(\d{4}[.-]\d{1,2}[.-]\d{1,2})", "date"),
        (r"(\d{4}-\d{2}-\d{2})", "date"),
    ):
        match = re.search(pattern, text)
        if not match:
            continue
        value = match.group(1) if match.lastindex else match.group(0)
        if key == "hospital" and not hospital:
            hospital = value
        elif key == "pharmacy" and not pharmacy:
            pharmacy = value
        elif key == "date" and not prescribed:
            prescribed = value.replace(".", "-")

    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for token in iter_glued_drug_tokens(text):
        name = token["drug_name"]
        if not name or name in seen:
            continue
        if _looks_like_shape_not_drug(name):
            continue
        if not _is_plausible_drug_candidate(name, name):
            continue
        seen.add(name)
        items.append(token)

    # 약이름 + 용량 + 횟수 + (일수) 표 줄
    row_re = re.compile(
        r"([가-힣A-Za-z][가-힣A-Za-z0-9.%]{1,40}(?:정|캡슐|액|시럽|산|주))"
        r"(?:\s*\([^)]*\))?"
        r".{0,80}?"
        r"(\d+(?:\.\d+)?)"
        r"\s*[|/\s]+\s*"
        r"(\d+)"
        r"(?:\s*[|/\s]+\s*(\d+))?",
        re.DOTALL,
    )
    for match in row_re.finditer(text):
        raw_name = match.group(1)
        name = _clean_drug_label(raw_name)
        if not name or name in seen:
            continue
        if not _is_plausible_drug_candidate(raw_name, name):
            continue
        seen.add(name)
        item: dict[str, Any] = {
            "drug_name": name,
            "dosage": match.group(2),
            "frequency_per_day": int(match.group(3)),
        }
        if match.group(4):
            item["duration_days"] = int(match.group(4))
        items.append(item)

    if not items:
        return None
    result: dict[str, Any] = {"items": items}
    if hospital:
        result["hospital_name"] = hospital
    if pharmacy:
        result["pharmacy_name"] = pharmacy
    if prescribed:
        result["prescribed_date"] = prescribed
    return result


def measure_field_coverage(structured: dict[str, Any]) -> dict[str, Any]:
    """약품명·성분 채움만 overall에 넣는다. 병원·약국·처방일은 참고 수치만 둔다."""
    header_hit = sum(1 for key in HEADER_FIELDS if str(structured.get(key) or "").strip())
    header_total = len(HEADER_FIELDS)

    item_hit = 0
    item_total = 0
    per_item: list[dict[str, Any]] = []
    for item in structured.get("items") or []:
        if not isinstance(item, dict):
            continue
        filled = []
        missing = []
        for key in SCORE_FIELDS:
            item_total += 1
            value = item.get(key)
            ok = value is not None and str(value).strip() != ""
            if ok:
                item_hit += 1
                filled.append(key)
            else:
                missing.append(key)
        per_item.append(
            {
                "drug_name": item.get("drug_name"),
                "filled": filled,
                "missing": missing,
                "item_coverage_pct": round(100.0 * len(filled) / len(SCORE_FIELDS), 1),
            }
        )

    return {
        "header_pct": round(100.0 * header_hit / header_total, 1) if header_total else 0.0,
        "items_pct": round(100.0 * item_hit / item_total, 1) if item_total else 0.0,
        "overall_pct": round(100.0 * item_hit / item_total, 1) if item_total else 0.0,
        "header_filled": header_hit,
        "header_total": header_total,
        "item_fields_filled": item_hit,
        "item_fields_total": item_total,
        "per_item": per_item,
        "score_fields": list(SCORE_FIELDS),
    }


def filter_to_source(parsed: dict[str, Any], raw_text: str) -> dict[str, Any]:
    """Drop invented drug names and numbers that are not in the OCR source."""
    source = raw_text or ""
    compact_source = _compact(source)
    items: list[dict[str, Any]] = []
    discarded: list[str] = [
        str(name).strip()
        for name in (parsed.get("discarded_names") or [])
        if str(name).strip()
    ]
    for item in parsed.get("items") or []:
        if not isinstance(item, dict):
            continue
        raw_name = str(item.get("drug_name") or "").strip()
        name = _clean_drug_label(raw_name)
        if not _is_plausible_drug_candidate(raw_name, name):
            if raw_name:
                discarded.append(raw_name)
            continue
        # 약처럼 보이는 이름이라도 OCR 원문에 근거가 없으면 등록 후보로 남기지 않는다.
        if name and not _name_in_source(name, compact_source, source):
            if not _name_in_source(name.split("(")[0].strip(), compact_source, source):
                discarded.append(name)
                continue
        cleaned = dict(item)
        cleaned["drug_name"] = name
        for key in ("frequency_per_day", "times_per_take", "duration_days"):
            if key in cleaned and not _number_in_source(key, cleaned.get(key), source):
                cleaned.pop(key, None)
        items.append(cleaned)
    result = dict(parsed)
    result["items"] = items
    result["discarded_names"] = discarded
    return result


def _first_dosing_match(text: str):
    triple = _DOSE_TRIPLE_RE.search(text)
    pair = _DOSE_PAIR_RE.search(text)
    candidates = [match for match in (triple, pair) if match]
    if not candidates:
        return None
    return min(candidates, key=lambda match: (match.start(), -match.end()))


def _trailing_dosing_text(text: str) -> str:
    first = _first_dosing_match(text)
    if first is None:
        return ""
    rest = text[first.end() :]
    extra = _DOSE_TRIPLE_RE.search(rest) or _DOSE_PAIR_RE.search(rest)
    return extra.group(0) if extra else ""


def _apply_dosing(item: dict[str, Any], dosing: dict[str, Any]) -> dict[str, Any]:
    cleaned = dict(item)
    if not dosing:
        return cleaned
    existing = str(cleaned.get("dosage") or "").strip()
    table_dose = dosing.get("dosage")
    if table_dose and _should_replace_dosage_with_table(existing):
        cleaned["dosage"] = table_dose
    if cleaned.get("frequency_per_day") is None and dosing.get("frequency_per_day") is not None:
        cleaned["frequency_per_day"] = dosing["frequency_per_day"]
    if cleaned.get("duration_days") is None and dosing.get("duration_days") is not None:
        cleaned["duration_days"] = dosing["duration_days"]
    return cleaned


def enrich_dosing_from_raw(structured: dict[str, Any], raw_text: str) -> dict[str, Any]:
    """구조화에서 빠진 용량·횟수·일수를 원문 표 숫자로 채운다."""
    source = raw_text or ""
    raw_items = [
        dict(item) for item in structured.get("items") or [] if isinstance(item, dict)
    ]
    if not raw_items:
        return structured

    lines = source.splitlines()
    spans: list[int | None] = []
    used: set[int] = set()
    for item in raw_items:
        name = str(item.get("drug_name") or "")
        core = _name_core(name)
        found = None
        if len(core) >= 2:
            for index, line in enumerate(lines):
                if index in used:
                    continue
                if _line_matches_name(line, name, core):
                    found = index
                    used.add(index)
                    break
        spans.append(found)

    leftovers = [""] * len(raw_items)
    items: list[dict[str, Any]] = []
    for index, item in enumerate(raw_items):
        start = spans[index]
        if start is None:
            items.append(
                _apply_dosing(
                    item,
                    _dosing_near_name(str(item.get("drug_name") or ""), source),
                )
            )
            continue
        next_start = next(
            (spans[j] for j in range(index + 1, len(spans)) if spans[j] is not None),
            len(lines),
        )
        window = " ".join(lines[start:next_start])
        combined = f"{leftovers[index]} {window}".strip()
        dosing = _dosing_from_window(combined)
        extra = _trailing_dosing_text(combined)
        next_item = next(
            (j for j in range(index + 1, len(spans)) if spans[j] is not None),
            None,
        )
        if extra and next_item is not None:
            leftovers[next_item] = extra
        items.append(_apply_dosing(item, dosing))

    result = dict(structured)
    result["items"] = items
    return result


def _normalize_table_dosing(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """보험 처방 표: '1 T'는 용량이 아님. 총량 60을 횟수로 쓰지 않음."""
    result: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        cleaned = dict(item)
        dosage = str(cleaned.get("dosage") or "").strip()
        unit = str(cleaned.get("unit") or "").strip()

        take_match = re.match(
            r"^(\d+(?:\.\d+)?)\s*(T|C|EA|PKG|정|캡슐)$",
            dosage.replace(" ", ""),
            re.IGNORECASE,
        )
        if take_match or unit.upper() in {"T", "C", "EA", "PKG"}:
            if take_match:
                try:
                    cleaned["times_per_take"] = int(float(take_match.group(1)))
                except ValueError:
                    cleaned["times_per_take"] = 1
                cleaned["unit"] = take_match.group(2).upper()
            if is_strength_dosage(dosage) or take_match:
                cleaned.pop("dosage", None)

        leftover = str(cleaned.get("dosage") or "")
        if is_strength_dosage(leftover) and "%" not in leftover:
            cleaned.pop("dosage", None)

        freq = cleaned.get("frequency_per_day")
        days = cleaned.get("duration_days")
        try:
            freq_n = int(freq) if freq is not None else None
        except (TypeError, ValueError):
            freq_n = None
        # 총량/일수 60을 1일 횟수로 오인
        if freq_n is not None and freq_n >= 10:
            if days is None:
                cleaned["duration_days"] = freq_n
            cleaned["frequency_per_day"] = 1
        result.append(cleaned)
    return result


def _merge_duplicate_drugs(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """아침/점심/저녁으로 반복된 같은 약을 한 줄로 합친다."""
    try:
        from app.services.matching.name_matcher import _medicine_key, extract_strengths
    except Exception:
        return items

    groups: dict[tuple, list[dict[str, Any]]] = {}
    order: list[tuple] = []
    for item in items:
        name = str(item.get("drug_name") or "")
        key = _medicine_key(name)
        strengths = tuple(sorted(extract_strengths(name + " " + str(item.get("dosage") or ""))))
        group_key = (key, strengths)
        if group_key not in groups:
            groups[group_key] = []
            order.append(group_key)
        groups[group_key].append(item)

    merged: list[dict[str, Any]] = []
    for group_key in order:
        rows = groups[group_key]
        base = dict(rows[0])
        if len(rows) > 1:
            slot_n = len(rows)
            freq = base.get("frequency_per_day")
            try:
                freq_n = int(freq) if freq is not None else slot_n
            except (TypeError, ValueError):
                freq_n = slot_n
            base["frequency_per_day"] = max(slot_n, freq_n if freq_n < 10 else slot_n)
        days_vals = []
        for row in rows:
            if row.get("duration_days") is not None:
                try:
                    days_vals.append(int(row["duration_days"]))
                except (TypeError, ValueError):
                    pass
        if days_vals and base.get("duration_days") is None:
            base["duration_days"] = max(days_vals)
        merged.append(base)
    return merged


def expand_inferred_drug_items(
    parsed: dict[str, Any],
    raw_text: str,
) -> dict[str, Any]:
    """붙어 있는 약 줄·이어진 이름을 나눠 후보를 보탠다. 공식명으로 바꾸지 않는다."""
    result = dict(parsed or {})
    items: list[dict[str, Any]] = []
    seen: set[str] = set()

    def _add(item: dict[str, Any]) -> None:
        name = str(item.get("drug_name") or "").strip()
        key = _compact(name)
        if not name or not key or key in seen:
            return
        if _looks_like_shape_not_drug(name):
            return
        if not _is_plausible_drug_candidate(name, name):
            return
        seen.add(key)
        items.append(item)

    for item in result.get("items") or []:
        if not isinstance(item, dict):
            continue
        raw_name = str(item.get("drug_name") or "").strip()
        pieces = split_concatenated_drug_names(raw_name)
        if len(pieces) <= 1:
            pieces = [raw_name]
        for index, piece in enumerate(pieces):
            row = dict(item) if index == 0 else {"drug_name": piece}
            _ignored, percent = split_percent_strength(piece)
            peeled, dosing = peel_glued_dosing(_strip_pack_noise(_clean_drug_label(piece)))
            row["drug_name"] = peeled or _clean_drug_label(piece)
            if percent and not row.get("dosage"):
                row["dosage"] = percent
            if dosing.get("dosage") and not row.get("dosage"):
                row["dosage"] = dosing["dosage"]
            if dosing.get("times_per_take") and row.get("times_per_take") is None:
                row["times_per_take"] = dosing["times_per_take"]
            if dosing.get("frequency_per_day") is not None and row.get("frequency_per_day") is None:
                row["frequency_per_day"] = dosing["frequency_per_day"]
            if dosing.get("duration_days") is not None and row.get("duration_days") is None:
                row["duration_days"] = dosing["duration_days"]
            _add(row)

    # 줄 단위에서만 붙은 약 이름을 추가로 찾는다.
    # 공백을 지운 전체 원문을 훑으면 '나주' '진정' 같은 조각이 약으로 잡힌다.
    for line in (raw_text or "").splitlines():
        for token in iter_glued_drug_tokens(line):
            _add(token)
    glued = re.sub(r"\s+", "", raw_text or "")
    if glued and glued != (raw_text or "").strip():
        for token in iter_glued_drug_tokens(glued):
            if token.get("times_per_take") or token.get("frequency_per_day") or token.get("duration_days"):
                _add(token)

    result["items"] = items
    return result


def correct_drug_names(structured: dict[str, Any]) -> dict[str, Any]:
    """붙어 있는 용량·횟수를 이름에서 떼고, 이어진 약 이름을 나눈다. 공식명으로 바꾸지 않는다."""
    items: list[dict[str, Any]] = []
    discarded: list[str] = [
        str(name).strip()
        for name in (structured.get("discarded_names") or [])
        if str(name).strip()
    ]
    for item in structured.get("items") or []:
        if not isinstance(item, dict):
            continue
        raw_name = str(item.get("drug_name") or "").strip()
        pieces = split_concatenated_drug_names(raw_name)
        if not pieces:
            pieces = [raw_name]
        for index, piece in enumerate(pieces):
            cleaned = dict(item) if index == 0 else {"drug_name": piece}
            name = _clean_drug_label(piece)
            name = _strip_pack_noise(name)
            _ignored, percent = split_percent_strength(piece)
            peeled, dosing = peel_glued_dosing(name)
            name = peeled or name
            if not _is_plausible_drug_candidate(piece, name):
                if piece:
                    discarded.append(piece)
                continue
            cleaned["drug_name"] = name
            if percent and not cleaned.get("dosage"):
                cleaned["dosage"] = percent
            if dosing.get("dosage") and not cleaned.get("dosage"):
                cleaned["dosage"] = dosing["dosage"]
            if dosing.get("times_per_take") and cleaned.get("times_per_take") is None:
                cleaned["times_per_take"] = dosing["times_per_take"]
            if dosing.get("frequency_per_day") is not None and cleaned.get("frequency_per_day") is None:
                cleaned["frequency_per_day"] = dosing["frequency_per_day"]
            if dosing.get("duration_days") is not None and cleaned.get("duration_days") is None:
                cleaned["duration_days"] = dosing["duration_days"]
            if name != raw_name:
                cleaned["ocr_drug_name_raw"] = raw_name
            items.append(cleaned)
    result = dict(structured)
    result["items"] = items
    result["discarded_names"] = discarded
    return result


_DRUG_NAME_LINE_RE = re.compile(
    r"[가-힣A-Za-z][가-힣A-Za-z0-9.%]{1,40}(?:정|캡슐|액|시럽|산|주)"
)
_DOSE_TRIPLE_RE = re.compile(
    r"(?P<dose>\d+\.\d+)\s*[|/\s]+\s*(?P<freq>[1-9])\s*[|/\s]+\s*(?P<days>\d{1,3})\b"
)
_DOSE_PAIR_RE = re.compile(
    r"(?P<dose>\d+\.\d+)\s*[|/\s]+\s*(?P<freq>[1-9])\b"
)


def _name_core(drug_name: str) -> str:
    core = _compact(drug_name)
    for suffix in ("필름코팅정", "서방정", "연질캡슐", "캡슐", "정", "시럽", "액"):
        if core.endswith(suffix) and len(core) > len(suffix) + 1:
            return core[: -len(suffix)]
    return core


def _line_matches_name(line: str, name: str, core: str) -> bool:
    compact_line = _compact(line)
    if not compact_line:
        return False
    needle = core[: min(4, len(core))]
    return needle in compact_line or _compact(name)[:6] in compact_line


def _is_other_drug_line(line: str, core: str) -> bool:
    compact_line = _compact(line)
    if not compact_line or core[: min(4, len(core))] in compact_line:
        return False
    match = _DRUG_NAME_LINE_RE.search(line)
    return match is not None and _compact(match.group(0)) != _compact(core)


def _dosing_from_window(window: str) -> dict[str, Any]:
    triple = _DOSE_TRIPLE_RE.search(window)
    if triple:
        days = int(triple.group("days"))
        result = {
            "dosage": triple.group("dose"),
            "frequency_per_day": int(triple.group("freq")),
        }
        if 1 <= days <= 365:
            result["duration_days"] = days
        return result
    pair = _DOSE_PAIR_RE.search(window)
    result: dict[str, Any] = {}
    if pair:
        result["dosage"] = pair.group("dose")
        result["frequency_per_day"] = int(pair.group("freq"))
        leftover = re.search(r"(?<!\d)(\d{1,3})(?!\d(?:\.\d+)?)", window[pair.end() :])
        if leftover:
            days = int(leftover.group(1))
            if 1 <= days <= 365:
                result["duration_days"] = days
    days = re.search(r"(?<!\d)(\d{1,3})\s*일분", window)
    if days:
        value = int(days.group(1))
        if 1 <= value <= 365:
            result["duration_days"] = value
    return result


def _dosing_near_name(drug_name: str, raw_text: str) -> dict[str, Any]:
    """약이름 앞뒤의 표 숫자(줄바꿈으로 떨어진 0.50 / 3 / 7)를 횟수·일수로 붙인다."""
    name = (drug_name or "").strip()
    if not name or not raw_text:
        return {}
    core = _name_core(name)
    if len(core) < 2:
        return {}

    lines = raw_text.splitlines()
    name_index = next(
        (
            index
            for index, line in enumerate(lines)
            if _line_matches_name(line, name, core)
        ),
        None,
    )
    if name_index is None:
        return {}

    end = name_index + 1
    while end < len(lines) and not _is_other_drug_line(lines[end], core):
        end += 1
        if end - name_index > 40:
            break
    window = " ".join(lines[name_index:end])
    return _dosing_from_window(window)


_PERCENT_STRENGTH_RE = re.compile(r"\s*\d+(?:\.\d+)?\s*%")


def split_percent_strength(name: str) -> tuple[str, str | None]:
    """'프레벨액0.25%' → ('프레벨액', '0.25%'). 식약처 검색에서 농도를 뺀다."""
    text = str(name or "")
    match = _PERCENT_STRENGTH_RE.search(text)
    found = None
    if match:
        found = re.sub(r"\s+", "", match.group(0))
    cleaned = _PERCENT_STRENGTH_RE.sub("", text)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -/")
    return cleaned, found


def strip_percent_strength(name: str) -> str:
    return split_percent_strength(name)[0]


_STRENGTH_IN_NAME_RE = re.compile(
    r"\s*\d+(?:\.\d+)?\s*(?:mg|ml|g|%|밀리그램|밀리그람)\b",
    re.IGNORECASE,
)


def product_search_name(name: str) -> str:
    """API 검색용: 제품명만. 농도·용량·1정2회는 뺀다."""
    text = _clean_drug_label(name)
    peeled, _dosing = peel_glued_dosing(text)
    text = peeled or text
    text = _STRENGTH_IN_NAME_RE.sub("", text)
    text = strip_percent_strength(text)
    return re.sub(r"\s+", " ", text).strip(" -/")


_INFER_FORM_ALT = (
    "필름코팅정|이알서방정|서방정|연질캡슐|경질캡슐|캡슐|"
    "현탁액|점안액|주사액|시럽|연고|크림|겔|패취|패치|플라스타|과립|액|정"
)
_GLUED_TOKEN_RE = re.compile(
    rf"(?P<name>[가-힣A-Za-z][가-힣A-Za-z0-9]*?(?:{_INFER_FORM_ALT}))"
    rf"(?P<strength>\d+(?:\.\d+)?(?:mg|ml|g|%|밀리그램|밀리그람))?"
    rf"(?:(?P<take>\d+)(?:정|캡슐|T|C))?"
    rf"(?:(?P<freq>\d+)(?:회|번))?"
    rf"(?:(?P<days>\d+)일(?:분)?)?",
    re.IGNORECASE,
)


def _looks_like_shape_not_drug(name: str) -> bool:
    compact = _compact(name)
    if compact.endswith("정제") or compact in {"정제", "액제", "주사"}:
        return True
    if any(bit in compact for bit in ("원형", "장방형", "타원형", "육각형")):
        return True
    if compact.startswith(("흰색", "노란", "분홍", "갈색", "투명")):
        return True
    return False


def peel_glued_dosing(name: str) -> tuple[str, dict[str, Any]]:
    """'프리마라정1정2회7일' → ('프리마라정', {횟수·일수}). 공식명으로 바꾸지 않는다."""
    raw = (name or "").strip()
    compact = re.sub(r"\s+", "", raw)
    dosing: dict[str, Any] = {}
    match = _GLUED_TOKEN_RE.match(compact)
    if not match:
        return raw, dosing
    peeled = match.group("name") or raw
    peeled, percent = split_percent_strength(peeled)
    strength = match.group("strength") or ""
    if percent:
        dosing["dosage"] = percent
    elif "%" in strength:
        dosing["dosage"] = strength
    if match.group("take"):
        dosing["times_per_take"] = int(match.group("take"))
    if match.group("freq"):
        dosing["frequency_per_day"] = int(match.group("freq"))
    if match.group("days"):
        dosing["duration_days"] = int(match.group("days"))
    return peeled, dosing


def split_concatenated_drug_names(name: str) -> list[str]:
    compact = re.sub(r"\s+", "", str(name or ""))
    matches = list(_GLUED_TOKEN_RE.finditer(compact))
    if len(matches) < 2:
        return [str(name or "").strip()] if str(name or "").strip() else []
    parts: list[str] = []
    for match in matches:
        piece = match.group("name") or ""
        piece = strip_percent_strength(piece)
        if piece and not _looks_like_shape_not_drug(piece):
            parts.append(piece)
    return parts if len(parts) >= 2 else ([str(name or "").strip()] if name else [])


def iter_glued_drug_tokens(text: str) -> list[dict[str, Any]]:
    tokens: list[dict[str, Any]] = []
    for match in _GLUED_TOKEN_RE.finditer(text or ""):
        name = match.group("name") or ""
        strength = match.group("strength") or ""
        name, peeled_pct = split_percent_strength(name)
        name = _clean_drug_label(name)
        if not name or _looks_like_shape_not_drug(name):
            continue
        item: dict[str, Any] = {"drug_name": name}
        if peeled_pct:
            item["dosage"] = peeled_pct
        elif "%" in strength:
            item["dosage"] = strength
        if match.group("take"):
            item["times_per_take"] = int(match.group("take"))
        if match.group("freq"):
            item["frequency_per_day"] = int(match.group("freq"))
        if match.group("days"):
            item["duration_days"] = int(match.group("days"))
        tokens.append(item)
    return tokens


def _strip_pack_noise(name: str) -> str:
    """'케토톱엘플라스타 7매/PKG', '코푸시럽 20ml/pkg' → 제품명만."""
    text = str(name or "").strip()
    text = re.sub(r"\s*\d+\s*매\s*/?\s*pkg.*$", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s*\d+(?:\.\d+)?\s*ml\s*/?\s*pkg.*$", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s*/\s*pkg.*$", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s*\d+(?:\.\d+)?\s*mg/24hours?.*$", "", text, flags=re.IGNORECASE)
    return text.strip(" ,-/")


def _strip_non_drug_markers(name: str) -> str:
    """처방 표 기호·구분코드를 약 이름에서 제거.

    비)다이크로지정, 급)타이레놀, 원내)세파클러 처럼
    '한 글자/짧은 말 + 괄호·점' 형태는 약 이름이 아님.
    비타민·비오플처럼 '비'로 시작하는 실제 약명은 그대로 둔다.
    """
    # NFKC로 전각 괄호/숫자/공백을 반각 형태로 통일한다.
    # 예: "비）다이크로지정", "비 ）다이크로지정" → "비)다이크로지정"
    text = unicodedata.normalize("NFKC", str(name or "")).strip()
    delim = r"[)\]\}>:.\-/|·,]"
    words = (
        "비급여",
        "급여대상",
        "급여약",
        "비급여약",
        "본인부담",
        "산정특례",
        "원내처방",
        "원외처방",
        "원내약",
        "원외약",
        "의료급여",
        "보훈급여",
        "차상위",
        "전액본인",
        "100분의100",
        "100/100",
        "비급여",
        "급여",
        "비급",
        "원내",
        "원외",
        "보훈",
        "향정",
        "마약",
        "한약",
        "건보",
        "자보",
        "산재",
    )
    # 한 글자 구분 코드: 비) 급) 원) 보) 향) 마) 산) 자)
    code_letters = "비급원보향마산자내외특"

    for _ in range(5):
        prev = text
        text = re.sub(r"^(?:" + "|".join(words) + r")\s*", "", text)
        text = re.sub(rf"^[{code_letters}]\s*{delim}\s*", "", text)
        text = re.sub(rf"^{delim}+\s*", "", text)
        # 선두 기호: ★ ☆ ● ○ ◎ ■ □ △ ▲ ※
        text = re.sub(r"^[\s★☆●○◎■□△▲※*]+", "", text)
        # 표준코드처럼 이름 앞에 붙은 숫자 코드 (8자리 이상)
        text = re.sub(r"^\d{8,}\s*", "", text)
        if text == prev:
            break
    return text.strip(" -/|")


def looks_truncated_ocr_name(name: str) -> bool:
    """글자가 잘리거나 가려진 OCR명인지."""
    text = unicodedata.normalize("NFKC", str(name or "")).strip()
    if re.search(r"[.…·]{1,}$", text) or text.endswith(".."):
        return True
    hangul = re.sub(r"[^가-힣]", "", text)
    if hangul and len(hangul) < 2:
        return True
    return False


def _strip_occlusion_noise(name: str) -> str:
    """가림·잘림 표시(…, □)만 제거하고, 남은 글자는 유지."""
    text = str(name or "").strip()
    text = re.sub(r"[.…·]+$", "", text)
    text = re.sub(r"\.{2,}$", "", text)
    text = re.sub(r"[□■○●¿?]+", "", text)
    return text.strip(" -/")


def _clean_drug_label(name: str) -> str:
    """'비)다이크로지정 (이뇨제)' → '다이크로지정'. 가림 표시도 정리."""
    text = _strip_non_drug_markers(str(name or "").strip())
    text = _strip_occlusion_noise(text)
    text = re.sub(r"\s*\([^)]*\)\s*", " ", text)
    text = re.sub(r"\s*\[[^\]]*\]\s*", " ", text)
    text = strip_percent_strength(text)
    return re.sub(r"\s+", " ", text).strip()


_NON_DRUG_LABELS = {
    "약품명",
    "의약품명",
    "처방의약품의명칭",
    "투약량",
    "1회투약량",
    "횟수",
    "투여횟수",
    "1일투여횟수",
    "일수",
    "투약일수",
    "총투약일수",
    "총량",
    "복약안내",
    "주의사항",
    "효능효과",
    "조제약사",
    "조제일자",
    "처방일자",
    "약국명",
    "병원명",
    "사업자등록번호",
    "현금영수증",
}

_DOSAGE_FORMS = (
    "필름코팅정",
    "이알서방정",
    "서방정",
    "연질캡슐",
    "경질캡슐",
    "캡슐",
    "시럽",
    "현탁액",
    "점안액",
    "주사액",
    "연고",
    "크림",
    "겔",
    "패취",
    "패치",
    "플라스타",
    "과립",
    "산",
    "액",
    "정",
    "주",
)


def _is_plausible_drug_candidate(raw_name: str, cleaned_name: str | None = None) -> bool:
    """머리글·구분기호·잘린 썸네일 글자를 약 후보에서 제외한다.

    이 함수는 공식 약을 확정하지 않는다. 실제 확정은 허가정보 검색 단계에서 한다.
    """
    raw = unicodedata.normalize("NFKC", str(raw_name or "")).strip()
    if not raw or looks_truncated_ocr_name(raw):
        return False

    cleaned = (cleaned_name if cleaned_name is not None else _clean_drug_label(raw)).strip()
    compact = re.sub(r"[^0-9a-z가-힣]", "", cleaned.casefold())
    if not compact or compact in _NON_DRUG_LABELS:
        return False

    # 금액·수납 같은 영수증 단어는 약이 아니다. ('총수납금액'이 '액'으로 끝나 오인됨)
    if re.search(r"금액|수납|영수|본인부담|진료비|결제", compact):
        return False
    # 효능 설명·복약 지시 문구가 약 이름에 붙은 쓰레기
    # ('세균감염증치료제옴니세프캡슐', '취침전비급여약품명복약안내주')
    if re.search(
        r"치료제|감염증|질환|진통제|해열|소염제|항생|소화제|지사제|"
        r"비급여|급여|복약|안내|취침|식전|식후|약품명|주의사항",
        compact,
    ):
        return False
    # 표 머리글이 약 이름에 붙은 쓰레기 ('약용사진옴니세프캡슐')
    if re.match(r"^(약품명?|의약품|약용|약사|복약안내?|주의사항|효능)", compact):
        return False
    # 날짜·복용지시 잔여물이 이름 앞/중간에 붙은 쓰레기 ('일분헤라신정', '년08월28일...시럽')
    if re.match(r"^(\d+일분?|\d+회|\d+번|\d+년|\d+월|일분|일수|년\d|월\d)", compact):
        return False
    if re.search(r"\d+(일분|일수|회|번|일)", compact):
        return False

    # '비)' 자체, OCR 사진 칸의 '슈'·'바실' 같은 짧은 조각을 제거한다.
    letters = re.sub(r"[^a-z가-힣]", "", compact)
    if len(letters) < 2:
        return False
    has_form = any(compact.endswith(form.casefold()) for form in _DOSAGE_FORMS)
    if not has_form and len(letters) < 3:
        return False
    # '나주' '진정'처럼 제형 한 글자만 붙은 일반어는 약이 아니다.
    # 헤라신정(헤라신+정)처럼 제형 앞 이름이 두 글자 이상이어야 한다.
    if has_form:
        stem = compact
        for form in sorted(_DOSAGE_FORMS, key=len, reverse=True):
            form_key = form.casefold()
            if compact.endswith(form_key):
                stem = compact[: -len(form_key)]
                break
        stem_letters = re.sub(r"[^a-z가-힣]", "", stem)
        if len(stem_letters) < 2:
            return False

    return True


def _compact(value: str) -> str:
    return "".join(str(value or "").casefold().split())


def _name_in_source(name: str, compact_source: str, raw_text: str = "") -> bool:
    compact_name = _compact(name)
    if not compact_name:
        return False
    if compact_name in compact_source:
        return True
    # OCR이 띄어쓰기·용량단위를 조금 다르게 읽어도 원문에 포함된 핵심 이름은 살린다.
    core = compact_name
    for suffix in ("필름코팅정", "서방정", "연질캡슐", "캡슐", "정", "시럽", "액", "mg", "ml", "g"):
        if core.endswith(suffix) and len(core) > len(suffix) + 1:
            core = core[: -len(suffix)]
            break
    if core and len(core) >= 2 and core in compact_source:
        return True

    try:
        from app.services.matching.name_matcher import (
            _fold_ocr_chars,
            compare_key,
            names_correspond,
        )
    except Exception:
        return False

    key = compare_key(name)
    folded_source = _fold_ocr_chars(compact_source)
    if len(key) >= 3 and key in folded_source:
        return True
    hangul_key = "".join(ch for ch in key if "가" <= ch <= "힣")
    if len(hangul_key) >= 3 and hangul_key in folded_source:
        return True
    for token in re.findall(r"[가-힣A-Za-z][가-힣A-Za-z0-9.%]{1,40}", raw_text or ""):
        if names_correspond(name, token, allow_typo=True):
            return True
    return False


def _source_without_column_headers(raw_text: str) -> str:
    """표 머리글 '1회 투약량'·'1일 투여횟수'가 횟수 1·일수 1로 오인되지 않게 뺀다."""
    text = raw_text or ""
    text = re.sub(r"1회\s*투약량", " ", text)
    text = re.sub(r"1일\s*투여횟수", " ", text)
    text = re.sub(r"투약\s*일수", " ", text)
    return text


def _number_in_source(key: str, value: Any, raw_text: str) -> bool:
    if value is None or value == "":
        return False
    try:
        number = str(int(value))
    except (TypeError, ValueError):
        number = str(value).strip()
    if not number:
        return False
    evidence = _source_without_column_headers(raw_text)
    if key == "duration_days":
        if f"{number}일" in evidence:
            return True
        # 복약안내 표: "... | 0.50 | 3 | 7"
        return _table_int_present(number, raw_text, role="duration")
    if key == "frequency_per_day":
        if f"{number}회" in evidence or f"{number}번" in evidence:
            return True
        return _table_int_present(number, raw_text, role="frequency")
    if key == "times_per_take":
        if (
            f"{number}정" in raw_text
            or f"{number}캡슐" in raw_text
            or f"{number}개" in raw_text
        ):
            return True
        return _table_int_present(number, raw_text, role="times")
    return number in raw_text


def _table_int_present(number: str, raw_text: str, *, role: str) -> bool:
    """표 OCR에서 단위 없이 나온 정수(횟수·일수)를 허용한다. 단독 '1' 같은 느슨한 일치는 쓰지 않는다."""
    # 용량(소수) 옆의 정수들: 0.50 | 3 | 7  또는  0.50  3  7
    row_pattern = re.compile(
        r"(?P<dose>\d+(?:\.\d+)?)\s*[|/\s]+\s*(?P<freq>\d+)\s*[|/\s]+\s*(?P<days>\d+)"
    )
    for match in row_pattern.finditer(raw_text):
        if role == "frequency" and match.group("freq") == number:
            return True
        if role == "duration" and match.group("days") == number:
            return True
        if role == "times" and (
            match.group("dose").startswith(number + ".") or match.group("dose") == number
        ):
            return True
    # 횟수만 있는 줄: 0.50 | 3  (일수 없음)
    if role == "frequency":
        pair = re.compile(
            r"(?P<dose>\d+(?:\.\d+)?)\s*[|/\s]+\s*(?P<freq>\d+)(?!\s*[|/\s]+\s*\d)"
        )
        for match in pair.finditer(raw_text):
            if match.group("freq") == number:
                return True
    return False
