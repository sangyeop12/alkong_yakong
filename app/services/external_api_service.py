import logging
import re
import threading
import time
from copy import deepcopy
from html import unescape
from typing import Any

import requests
from fastapi import HTTPException

from app.core.config import E_DRUG_API_KEY, E_DRUG_BASE_URL
from app.services.mfds_drug_permission import client as permission_client


logger = logging.getLogger(__name__)
TIMEOUT_SECONDS = 10
DRUG_CANDIDATE_LIMIT = 8
DRUG_SEARCH_TIMEOUT_SECONDS = 5.0
DRUG_SEARCH_TOTAL_BUDGET_SECONDS = 10.0
DRUG_SEARCH_CACHE_TTL_SECONDS = 45.0
DRUG_SEARCH_CACHE_MAX_ENTRIES = 128

_drug_search_cache: dict[str, tuple[float, dict[str, Any]]] = {}
_drug_search_cache_lock = threading.Lock()


def fetch_e_drug_info(
    *,
    medicine_code: str | None = None,
    medicine_name: str | None = None,
) -> dict[str, Any] | None:
    if not E_DRUG_API_KEY:
        logger.info("E_DRUG_API_KEY is not configured; using local drug fallback.")
        return None

    params: dict[str, Any] = {
        "serviceKey": E_DRUG_API_KEY,
        "pageNo": 1,
        "numOfRows": 10,
        "type": "json",
    }
    if medicine_code and medicine_code.isdigit():
        params["itemSeq"] = medicine_code
    elif medicine_name:
        params["itemName"] = medicine_name
    elif medicine_code:
        params["itemName"] = medicine_code
    else:
        return None

    try:
        response = requests.get(
            E_DRUG_BASE_URL,
            params=params,
            timeout=TIMEOUT_SECONDS,
        )
        payload = _load_e_drug_payload(response, operation="fetch")
        _log_e_drug_response(response, payload, operation="fetch")
        response.raise_for_status()
        items = _extract_items(payload)
        if not items:
            logger.info(
                "e약은요 returned no result for code=%s name=%s",
                medicine_code,
                medicine_name,
            )
            return None
        return _normalize_item(items[0])
    except (requests.RequestException, ValueError, TypeError, KeyError) as error:
        logger.warning(
            "e약은요 lookup failed (%s).",
            type(error).__name__,
        )
        return None


def search_drug_info_by_name(
    name: str,
    page_no: int = 1,
    num_of_rows: int = 10,
    *,
    product_name_only: bool = False,
) -> dict:
    if not E_DRUG_API_KEY:
        raise HTTPException(
            status_code=503,
            detail="E_DRUG_API_KEY가 설정되지 않았습니다.",
        )

    try:
        query = name.strip()
        exact_items = _request_drug_items(
            query,
            page_no=page_no,
            num_of_rows=num_of_rows,
        )
        if product_name_only:
            normalized = [_normalize_item(item) for item in exact_items]
            return {
                "query": query,
                "count": len(normalized),
                "items": normalized,
                "match_type": "product_name",
            }

        exact_key = _compact_drug_name(name)
        exact_matches = [
            item
            for item in exact_items
            if _compact_drug_name(item.get("itemName")) == exact_key
        ]
        exact_result_index = next(
            (
                index
                for index, item in enumerate(exact_items)
                if _compact_drug_name(item.get("itemName")) == exact_key
            ),
            None,
        )
        logger.warning(
            "e약은요 match_diagnostic phase=exact raw_result_count=%d "
            "exact_match_count=%d selected_match_type=%s selected_result_index=%s",
            len(exact_items),
            len(exact_matches),
            "exact" if exact_matches else "none",
            exact_result_index,
        )
        if exact_matches:
            normalized = [_normalize_item(item) for item in exact_matches]
            return {
                "query": name,
                "count": len(normalized),
                "items": normalized,
                "match_type": "exact",
            }

        normalized_query = _normalize_drug_search_name(name)
        partial_items = exact_items
        if normalized_query and normalized_query != exact_key:
            partial_items = _request_drug_items(
                normalized_query,
                page_no=page_no,
                num_of_rows=num_of_rows,
            )

        scored_matches = []
        for item in partial_items:
            candidate_name = _normalize_drug_search_name(item.get("itemName"))
            if not normalized_query or (
                normalized_query not in candidate_name
                and candidate_name not in normalized_query
            ):
                continue
            normalized_equal = candidate_name == normalized_query
            startswith = candidate_name.startswith(normalized_query)
            manufacturer_prefix = candidate_name.endswith(normalized_query)
            reverse_contains = candidate_name in normalized_query
            length_ratio = len(normalized_query) / max(len(candidate_name), 1)
            if normalized_equal:
                match_rank = 0
                match_score = 100.0
            elif manufacturer_prefix:
                match_rank = 1
                match_score = 90.0 + (10.0 * length_ratio)
            elif startswith or reverse_contains:
                match_rank = 2
                match_score = 70.0 + (20.0 * length_ratio)
            else:
                match_rank = 3
                match_score = 50.0 + (20.0 * length_ratio)
            scored_matches.append(
                (
                    match_rank,
                    -match_score,
                    abs(len(candidate_name) - len(normalized_query)),
                    _compact_drug_name(item.get("itemName")),
                    item,
                )
            )
        scored_matches.sort(key=lambda match: match[:4])
        best_rank = scored_matches[0][0] if scored_matches else None
        eligible_matches = [
            match for match in scored_matches if match[0] == best_rank
        ]
        is_ambiguous = len(eligible_matches) > 1
        partial_matches = [match[4] for match in eligible_matches]
        if not is_ambiguous:
            partial_matches = partial_matches[:1]
        selected_partial_index = (
            next(
                (
                    index
                    for index, item in enumerate(partial_items)
                    if item is partial_matches[0]
                ),
                None,
            )
            if partial_matches
            else None
        )
        logger.warning(
            "e약은요 match_diagnostic phase=partial raw_result_count=%d "
            "exact_match_count=0 partial_match_count=%d "
            "selected_match_type=%s selected_result_index=%s",
            len(partial_items),
            len(partial_matches),
            "ambiguous" if is_ambiguous else "partial" if partial_matches else "none",
            None if is_ambiguous else selected_partial_index,
        )
        if scored_matches:
            best_match = eligible_matches[0]
            logger.info(
                "match_type=partial matched_name=%s match_score=%.2f",
                best_match[4].get("itemName"),
                -best_match[1],
            )
    except requests.Timeout as error:
        raise HTTPException(status_code=504, detail="식약처 API 타임아웃") from error
    except requests.RequestException as error:
        raise HTTPException(
            status_code=502,
            detail="식약처 API 호출에 실패했습니다.",
        ) from error
    except (ValueError, TypeError, KeyError) as error:
        raise HTTPException(
            status_code=502,
            detail="식약처 API 응답 형식이 올바르지 않습니다.",
        ) from error

    normalized = [_normalize_item(item) for item in partial_matches]
    response = {"query": name, "count": len(normalized), "items": normalized}
    if normalized:
        response["match_type"] = "ambiguous" if is_ambiguous else "partial"
    return response


def search_drug_candidates(
    query: str,
    *,
    limit: int = DRUG_CANDIDATE_LIMIT,
) -> dict[str, Any]:
    cleaned_query = query.strip()
    if len(cleaned_query) < 2:
        raise HTTPException(status_code=422, detail="검색어는 2글자 이상이어야 합니다.")
    compact_query = _compact_drug_name(cleaned_query)
    cached = _get_cached_drug_search(compact_query)
    if cached is not None:
        return cached

    started_at = time.monotonic()
    e_drug_candidates: list[tuple[int, int, int, str, dict[str, Any]]] = []
    permission_candidates: list[tuple[int, int, int, str, dict[str, Any]]] = []
    errors: list[Exception] = []
    source_succeeded = False
    result_is_cacheable = False

    if E_DRUG_API_KEY:
        try:
            raw_items = _request_drug_items(
                cleaned_query,
                page_no=1,
                num_of_rows=max(limit * 2, 10),
                timeout=DRUG_SEARCH_TIMEOUT_SECONDS,
            )
            e_drug_candidates = _build_drug_candidates(
                raw_items,
                compact_query=compact_query,
                item_name_field="itemName",
                manufacturer_field="entpName",
                item_seq_field="itemSeq",
                dedupe_by_name_within_source=True,
            )
            source_succeeded = True
            result_is_cacheable = bool(e_drug_candidates)
        except (requests.RequestException, ValueError, TypeError, KeyError) as error:
            errors.append(error)
    else:
        errors.append(RuntimeError("E_DRUG_API_KEY is not configured"))

    if not e_drug_candidates:
        try:
            remaining_budget = max(
                0.1,
                DRUG_SEARCH_TOTAL_BUDGET_SECONDS
                - (time.monotonic() - started_at),
            )
            permission_items = permission_client.search_permission_products(
                cleaned_query,
                limit=max(limit * 2, 10),
                timeout=min(DRUG_SEARCH_TIMEOUT_SECONDS, remaining_budget),
            )
            permission_candidates = _build_drug_candidates(
                permission_items,
                compact_query=compact_query,
                item_name_field="ITEM_NAME",
                manufacturer_field="ENTP_NAME",
                item_seq_field="ITEM_SEQ",
                dedupe_by_name_within_source=False,
            )
            source_succeeded = True
            result_is_cacheable = True
        except (requests.RequestException, RuntimeError, ValueError, TypeError, KeyError) as error:
            errors.append(error)

    if not source_succeeded:
        _raise_drug_search_error(errors)

    e_drug_candidates.sort(key=lambda candidate: candidate[:4])
    permission_candidates.sort(key=lambda candidate: candidate[:4])
    items = [candidate[4] for candidate in e_drug_candidates[:limit]]
    seen_item_sequences = {
        item_seq
        for item in items
        if (item_seq := item.get("item_seq"))
    }
    for candidate in permission_candidates:
        normalized = candidate[4]
        item_seq = normalized.get("item_seq")
        if item_seq and item_seq in seen_item_sequences:
            continue
        if item_seq:
            seen_item_sequences.add(item_seq)
        items.append(normalized)
        if len(items) >= limit:
            break

    result = {"query": cleaned_query, "count": len(items), "items": items}
    if result_is_cacheable:
        _cache_drug_search(compact_query, result)
    return result


def _get_cached_drug_search(cache_key: str) -> dict[str, Any] | None:
    now = time.monotonic()
    with _drug_search_cache_lock:
        cached = _drug_search_cache.get(cache_key)
        if cached is None:
            return None
        cached_at, result = cached
        if now - cached_at >= DRUG_SEARCH_CACHE_TTL_SECONDS:
            _drug_search_cache.pop(cache_key, None)
            return None
        return deepcopy(result)


def _cache_drug_search(cache_key: str, result: dict[str, Any]) -> None:
    now = time.monotonic()
    with _drug_search_cache_lock:
        expired_keys = [
            key
            for key, (cached_at, _) in _drug_search_cache.items()
            if now - cached_at >= DRUG_SEARCH_CACHE_TTL_SECONDS
        ]
        for key in expired_keys:
            _drug_search_cache.pop(key, None)
        if len(_drug_search_cache) >= DRUG_SEARCH_CACHE_MAX_ENTRIES:
            oldest_key = min(
                _drug_search_cache,
                key=lambda key: _drug_search_cache[key][0],
            )
            _drug_search_cache.pop(oldest_key, None)
        _drug_search_cache[cache_key] = (now, deepcopy(result))


def _build_drug_candidates(
    raw_items: list[dict[str, Any]],
    *,
    compact_query: str,
    item_name_field: str,
    manufacturer_field: str,
    item_seq_field: str,
    dedupe_by_name_within_source: bool,
) -> list[tuple[int, int, int, str, dict[str, Any]]]:
    candidates: list[tuple[int, int, int, str, dict[str, Any]]] = []
    seen: set[tuple[str, str]] = set()
    for item in raw_items:
        item_name = _clean_text(item.get(item_name_field))
        if not item_name:
            continue
        compact_name = _compact_drug_name(item_name)
        position = compact_name.find(compact_query)
        if position < 0:
            continue
        item_seq = _clean_text(item.get(item_seq_field))
        dedupe_key = (
            (item_seq or "", compact_name)
            if dedupe_by_name_within_source
            else (item_seq or "", "" if item_seq else compact_name)
        )
        if dedupe_key in seen:
            continue
        seen.add(dedupe_key)
        candidate = {
            "item_name": item_name,
            "manufacturer": _clean_text(item.get(manufacturer_field)),
            "item_seq": item_seq,
        }
        candidates.append(
            (
                0 if position == 0 else 1,
                position,
                len(compact_name),
                compact_name,
                candidate,
            )
        )
    return candidates


def _raise_drug_search_error(errors: list[Exception]) -> None:
    if any(isinstance(error, requests.Timeout) for error in errors):
        raise HTTPException(status_code=504, detail="식약처 API 타임아웃")
    if any(isinstance(error, requests.RequestException) for error in errors):
        raise HTTPException(status_code=502, detail="식약처 API 호출에 실패했습니다.")
    if any(
        isinstance(error, (ValueError, TypeError, KeyError)) for error in errors
    ):
        raise HTTPException(
            status_code=502,
            detail="식약처 API 응답 형식이 올바르지 않습니다.",
        )
    raise HTTPException(status_code=503, detail="식약처 API Key가 설정되지 않았습니다.")


def _request_drug_items(
    query: str,
    *,
    page_no: int,
    num_of_rows: int,
    timeout: float = TIMEOUT_SECONDS,
) -> list[dict[str, Any]]:
    params = {
        "serviceKey": E_DRUG_API_KEY,
        "pageNo": page_no,
        "numOfRows": num_of_rows,
        "itemName": query,
        "type": "json",
    }
    response = requests.get(
        E_DRUG_BASE_URL,
        params=params,
        timeout=timeout,
    )
    payload = _load_e_drug_payload(response, operation="search")
    _log_e_drug_response(response, payload, operation="search")
    response.raise_for_status()
    return _extract_items(payload)


def _load_e_drug_payload(
    response: requests.Response,
    *,
    operation: str,
) -> dict[str, Any]:
    try:
        payload = response.json()
    except ValueError:
        logger.warning(
            "e약은요 response operation=%s outcome=invalid_json status=%s "
            "content_type=%s",
            operation,
            response.status_code,
            response.headers.get("content-type", ""),
        )
        raise
    if not isinstance(payload, dict):
        logger.warning(
            "e약은요 response operation=%s outcome=invalid_structure status=%s "
            "content_type=%s payload_type=%s",
            operation,
            response.status_code,
            response.headers.get("content-type", ""),
            type(payload).__name__,
        )
        raise TypeError("e약은요 response root must be an object")
    return payload


def _log_e_drug_response(
    response: requests.Response,
    payload: dict[str, Any],
    *,
    operation: str,
) -> None:
    envelope = payload.get("response") if isinstance(payload, dict) else None
    root = envelope if isinstance(envelope, dict) else payload
    header = root.get("header", {}) if isinstance(root, dict) else {}
    result_code = header.get("resultCode") if isinstance(header, dict) else None
    result_message = header.get("resultMsg") if isinstance(header, dict) else None
    items = _extract_items(payload)

    normalized_message = str(result_message or "").casefold()
    auth_terms = (
        "service key",
        "authentication",
        "not registered",
        "access denied",
        "인증",
        "권한",
    )
    if response.status_code in {401, 403} or any(
        term in normalized_message for term in auth_terms
    ):
        outcome = "authentication_or_permission_failure"
    elif not response.ok or result_code not in (None, "00"):
        outcome = "api_error"
    elif not items:
        outcome = "no_items"
    else:
        outcome = "success"

    log = logger.warning if outcome.endswith("failure") or outcome == "api_error" else logger.info
    log(
        "e약은요 response operation=%s outcome=%s status=%s content_type=%s "
        "result_code=%s result_message=%s items_present=%s item_count=%d",
        operation,
        outcome,
        response.status_code,
        response.headers.get("content-type", ""),
        result_code,
        result_message,
        bool(items),
        len(items),
    )


def _compact_drug_name(value: Any) -> str:
    return re.sub(r"\s+", "", str(value or "")).casefold()


def _normalize_drug_search_name(value: Any) -> str:
    text = _compact_drug_name(value)
    text = re.sub(r"\([^)]*\)", "", text)
    text = re.sub(r"\d+(?:\.\d+)?(?:mg|ml)", "", text, flags=re.IGNORECASE)
    text = re.sub(r"(?:mg|ml)", "", text, flags=re.IGNORECASE)
    for dosage_form in ("필름코팅정", "연질캡슐", "캡슐", "정"):
        if text.endswith(dosage_form):
            text = text[: -len(dosage_form)]
            break
    return text


def _extract_items(payload: dict[str, Any]) -> list[dict[str, Any]]:
    body = payload.get("body")
    if body is None:
        body = payload.get("response", {}).get("body", {})
    items = body.get("items", []) if isinstance(body, dict) else []
    if isinstance(items, dict):
        nested = items.get("item")
        if nested is not None:
            items = nested
        else:
            items = [items]
    if isinstance(items, dict):
        items = [items]
    return items if isinstance(items, list) else []


def _normalize_item(item: dict[str, Any]) -> dict[str, Any]:
    cautions = "\n".join(
        value
        for value in (
            _clean_text(item.get("atpnWarnQesitm")),
            _clean_text(item.get("atpnQesitm")),
        )
        if value
    )
    return {
        "medicine_code": _clean_text(item.get("itemSeq")),
        "medicine_name": _clean_text(item.get("itemName")),
        "product_name": _clean_text(item.get("itemName")),
        "ingredient": _first_text(
            item,
            "itemIngredient",
            "ingredient",
            "mainIngredient",
        ),
        "manufacturer": _clean_text(item.get("entpName")),
        "efficacy": _clean_text(item.get("efcyQesitm")),
        "usage": _clean_text(item.get("useMethodQesitm")),
        "cautions": cautions or None,
        "interaction": _clean_text(item.get("intrcQesitm")),
        "side_effects": _clean_text(item.get("seQesitm")),
        "storage": _clean_text(item.get("depositMethodQesitm")),
        "image_url": _clean_text(item.get("itemImage")),
        "source": "e약은요",
    }


def _first_text(item: dict[str, Any], *keys: str) -> str | None:
    for key in keys:
        value = _clean_text(item.get(key))
        if value:
            return value
    return None


def _clean_text(value: Any) -> str | None:
    if value is None:
        return None
    text = unescape(str(value))
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text or None
