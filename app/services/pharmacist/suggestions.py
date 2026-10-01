"""Suggestions for the guided pharmacist chat (Asan-style autocomplete)."""

from __future__ import annotations

import re
import time

from app.database import get_connection
from app.services.matching.chosung import is_chosung_query, to_chosung
from app.services.mfds_drug_permission.db import search_permission_names
from app.services.pharmacist.easy_category_db import lookup_chat_links


FAQ_SUGGESTIONS = (
    "이 약 설명",
    "같이 먹으면",
    "안 먹었을 때",
)

RELATED_FAQ = (
    "이 약 설명",
    "같이 먹으면",
    "안 먹었을 때",
)

FALLBACK_OFFICIAL_NAMES = (
    "타이레놀정500밀리그램",
    "타이레놀8시간이알서방정",
    "부루펜정200밀리그램(이부프로펜)",
    "게보린정",
    "아스피린장용정",
)

_CACHE_TTL_SECONDS = 60.0
_official_cache: dict[str, tuple[float, list[str]]] = {}


def get_chat_suggestions(query: str = "", user_id: str | None = None) -> list[dict[str, str]]:
    needle = _compact(query)
    if not needle:
        items = [{"label": label, "type": "faq"} for label in FAQ_SUGGESTIONS]
        items.extend(_today_medicines(user_id, ""))
        return _unique(items)[:20]

    items: list[dict[str, str]] = []
    links = lookup_chat_links(query)

    # DB 일상어 연결: 연관 검색어(phrase) → 약검색 → FAQ
    for phrase in links.get("phrase") or []:
        items.append({"label": phrase, "type": "phrase"})

    search_queries: list[str] = []
    search_queries.extend(links.get("search") or ())
    raw_query = query.strip()
    if is_chosung_query(raw_query) or len(needle) >= 2:
        search_queries.append(raw_query)

    seen_search: set[str] = set()
    for search_query in search_queries:
        key = _compact(search_query)
        if not key or key in seen_search:
            continue
        seen_search.add(key)
        items.extend(
            {"label": name, "type": "medicine"}
            for name in _official_names(search_query)
        )

    items.extend(_today_medicines(user_id, needle))
    items.extend(_local_medicines(needle))

    seen_names = {_compact(item["label"]) for item in items}
    first_medicine = next(
        (item["label"] for item in items if item["type"] == "medicine"),
        None,
    )
    if first_medicine:
        short = _short_name(first_medicine)
        for faq in RELATED_FAQ:
            label = f"{short} {faq}"
            if _compact(label) not in seen_names:
                items.append({"label": label, "type": "faq"})
                seen_names.add(_compact(label))

    for faq in links.get("faq") or ():
        if _compact(faq) not in seen_names:
            items.append({"label": faq, "type": "faq"})
            seen_names.add(_compact(faq))

    for label in FAQ_SUGGESTIONS:
        if needle in _compact(label) or _compact(label) in needle:
            if _compact(label) not in seen_names:
                items.append({"label": label, "type": "faq"})
                seen_names.add(_compact(label))

    return _unique(items)[:16]


def _today_medicines(user_id: str | None, needle: str) -> list[dict[str, str]]:
    if not user_id:
        return []
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT DISTINCT m.product_name
            FROM user_medicines um
            JOIN medicines m ON m.medicine_code = um.medicine_code
            WHERE um.user_id = ?
              AND um.is_active = 1
              AND m.product_name IS NOT NULL
            """,
            (user_id,),
        ).fetchall()
    finally:
        conn.close()
    return _filter_names(rows, needle, "today_medicine")


def _local_medicines(needle: str) -> list[dict[str, str]]:
    conn = get_connection()
    try:
        rows = conn.execute(
            "SELECT product_name FROM medicines WHERE product_name IS NOT NULL"
        ).fetchall()
    finally:
        conn.close()
    return _filter_names(rows, needle, "medicine")


def _filter_names(rows, needle: str, item_type: str) -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    for row in rows:
        label = str(row["product_name"] or "").strip()
        if label and (not needle or needle in _compact(label)):
            items.append({"label": label, "type": item_type})
    return items


def _official_names(query: str) -> list[str]:
    raw = (query or "").strip()
    if not raw:
        return []

    if is_chosung_query(raw):
        chosung = "".join(raw.split())
        cache_key = f"chosung:{chosung}"
        cached = _official_cache.get(cache_key)
        now = time.monotonic()
        if cached and now - cached[0] < _CACHE_TTL_SECONDS:
            return cached[1]
        names: list[str] = []
        try:
            names.extend(search_permission_names(raw, limit=10))
        except Exception:
            pass
        for name in FALLBACK_OFFICIAL_NAMES:
            if to_chosung(name).startswith(chosung) and name not in names:
                names.append(name)
        unique_names = list(dict.fromkeys(names))
        _official_cache[cache_key] = (now, unique_names)
        return unique_names

    needle = _compact(raw)
    cached = _official_cache.get(needle)
    now = time.monotonic()
    if cached and now - cached[0] < _CACHE_TTL_SECONDS:
        return cached[1]

    names: list[str] = []
    try:
        for label in search_permission_names(raw, limit=10):
            if label and (
                _matches_prefix(label, needle) or needle in _compact(label)
            ):
                names.append(label)
    except Exception:
        pass

    for name in FALLBACK_OFFICIAL_NAMES:
        if (
            _matches_prefix(name, needle) or needle in _compact(name)
        ) and name not in names:
            names.append(name)

    names.sort(key=lambda name: _rank_name(name, needle))
    unique_names = list(dict.fromkeys(names))
    _official_cache[needle] = (now, unique_names)
    return unique_names


def _matches_prefix(name: str, needle: str) -> bool:
    compact = re.sub(r"\([^)]*\)", "", _compact(name))
    short = _compact(_short_name(name))
    return compact.startswith(needle) or short.startswith(needle)


def _rank_name(name: str, needle: str) -> tuple:
    compact = re.sub(r"\([^)]*\)", "", _compact(name))
    short = _compact(_short_name(name))
    preferred = name in FALLBACK_OFFICIAL_NAMES
    starts = compact.startswith(needle) or short.startswith(needle)
    return (0 if starts else 1, 0 if preferred else 1, len(short), len(compact), name)


def _short_name(name: str) -> str:
    text = re.sub(r"\([^)]*\)", "", _compact(name))
    text = re.sub(r"\d+(?:\.\d+)?(?:mg|ml|g|밀리그램|밀리그람)", "", text)
    for suffix in ("필름코팅정", "서방정", "연질캡슐", "캡슐", "정", "시럽"):
        if text.endswith(suffix):
            text = text[: -len(suffix)]
            break
    return text or name.strip()


def _compact(value: str) -> str:
    return "".join(str(value or "").casefold().split())


def _unique(items: list[dict[str, str]]) -> list[dict[str, str]]:
    unique: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in items:
        label = item["label"]
        if label in seen:
            continue
        seen.add(label)
        unique.append(item)
    return unique
