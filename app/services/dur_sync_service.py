import json
import logging
import re
import threading
from typing import Any
from urllib.parse import quote, unquote, urlencode
from xml.etree import ElementTree

import requests
from fastapi import HTTPException

from app.core.config import (
    DUR_API_BASE_URL,
    DUR_API_KEY,
    DUR_AUTO_SYNC,
    DUR_BOOTSTRAP_MAX_PAGES,
)
from app.database import get_connection
from app.models.schemas import DurSyncRequest


logger = logging.getLogger(__name__)
TIMEOUT_SECONDS = 20
MFDS_DUR_SOURCE = "식약처 DUR 성분정보 OpenAPI"
_SYNC_LOCK = threading.Lock()
_BOOTSTRAP_STARTED = False
_USER_REFRESH_LOCK = threading.Lock()
_USERS_REFRESHING: set[str] = set()
_INGR_QUERY_KEYS = ("ingrKorName", "INGR_KOR_NAME")
_MAX_INGREDIENT_PAGES = 5

ENDPOINTS = {
    "병용금기": "getUsjntTabooInfoList02",
    "연령금기": "getSpcifyAgrdeTabooInfoList02",
    "임부금기": "getPwnmTabooInfoList02",
    "효능군중복": "getEfcyDplctInfoList02",
}

DUR_INGREDIENT_QUERY_PARAM = {
    "병용금기": "ingrKorName",
    "연령금기": "ingrName",
    "임부금기": "ingrName",
    "효능군중복": "ingrName",
}


def diagnose_dur_api_key(
    risk_type: str = "병용금기",
) -> dict[str, Any]:
    if risk_type not in ENDPOINTS:
        raise HTTPException(
            status_code=400,
            detail=f"지원하지 않는 DUR 유형입니다: {risk_type}",
        )
    if not DUR_API_KEY:
        return {
            "key_loaded": False,
            "risk_type": risk_type,
            "endpoint": ENDPOINTS[risk_type],
            "results": [],
        }

    endpoint = ENDPOINTS[risk_type]
    base_url = f"{DUR_API_BASE_URL}/{endpoint}"
    public_params = {
        "pageNo": 1,
        "numOfRows": 1,
        "type": "json",
    }
    safe_url = f"{base_url}?{urlencode(public_params)}"
    logger.info(
        "MFDS DUR diagnostic request key_loaded=%s url_without_serviceKey=%s",
        bool(DUR_API_KEY),
        safe_url,
    )

    decoded_key = unquote(DUR_API_KEY.strip())
    encoded_key = quote(decoded_key, safe="")
    results = [
        _diagnose_request(
            "decoding_key_via_params",
            base_url,
            params={"serviceKey": decoded_key, **public_params},
        ),
        _diagnose_request(
            "encoding_key_in_query",
            f"{base_url}?serviceKey={encoded_key}&{urlencode(public_params)}",
        ),
    ]
    return {
        "key_loaded": True,
        "key_contains_percent_encoding": "%" in DUR_API_KEY,
        "decoded_and_encoded_forms_differ": decoded_key != encoded_key,
        "risk_type": risk_type,
        "endpoint": endpoint,
        "base_url": base_url,
        "parameters_without_serviceKey": public_params,
        "results": results,
    }


def _diagnose_request(
    mode: str,
    url: str,
    *,
    params: dict[str, Any] | None = None,
) -> dict[str, Any]:
    try:
        response = requests.get(
            url,
            params=params,
            headers={
                "Accept": "application/json, application/xml, text/plain",
                "User-Agent": "alkong-yakong-dur-diagnostic/1.0",
            },
            timeout=TIMEOUT_SECONDS,
        )
        preview = _masked_preview(response.text)
        logger.info(
            "MFDS DUR diagnostic result mode=%s status=%s "
            "content_type=%s body=%s",
            mode,
            response.status_code,
            response.headers.get("content-type", ""),
            preview,
        )
        return {
            "mode": mode,
            "status_code": response.status_code,
            "content_type": response.headers.get("content-type", ""),
            "response_preview": preview,
        }
    except requests.RequestException as error:
        logger.warning(
            "MFDS DUR diagnostic failed mode=%s error=%s",
            mode,
            type(error).__name__,
        )
        return {
            "mode": mode,
            "error": type(error).__name__,
        }


def sync_mfds_dur(request: DurSyncRequest) -> dict[str, Any]:
    logger.info("DUR_API_KEY loaded = %s", bool(DUR_API_KEY))
    unknown = sorted(set(request.types) - set(ENDPOINTS))
    if unknown:
        raise HTTPException(
            status_code=400,
            detail=f"지원하지 않는 DUR 유형입니다: {', '.join(unknown)}",
        )

    conn = get_connection()
    try:
        cursor = conn.cursor()
        result = {
            "source": MFDS_DUR_SOURCE,
            "types": {},
            "total_fetched": 0,
            "inserted": 0,
            "updated": 0,
            "skipped": 0,
            "skipped_missing_key": 0,
        }
        for risk_type in request.types:
            if not DUR_API_KEY:
                result["types"][risk_type] = {
                    "status": "skipped_missing_key",
                    "total_fetched": 0,
                    "inserted": 0,
                    "updated": 0,
                    "skipped": 0,
                    "skipped_missing_key": 1,
                }
                result["skipped_missing_key"] += 1
                continue
            stats = _sync_type(
                cursor,
                risk_type,
                api_key=DUR_API_KEY,
                page_size=request.page_size,
                max_pages=request.max_pages,
            )
            result["types"][risk_type] = stats
            for key in (
                "total_fetched",
                "inserted",
                "updated",
                "skipped",
                "skipped_missing_key",
            ):
                result[key] += stats[key]
        conn.commit()
        return result
    except HTTPException:
        conn.rollback()
        raise
    except Exception as error:
        conn.rollback()
        logger.warning("MFDS DUR synchronization failed: %s", error, exc_info=True)
        raise HTTPException(
            status_code=502,
            detail="식약처 DUR 데이터 동기화에 실패했습니다.",
        ) from error
    finally:
        conn.close()


def _sync_type(
    cursor,
    risk_type: str,
    *,
    api_key: str,
    page_size: int,
    max_pages: int | None,
) -> dict[str, int]:
    page = 1
    stats = {
        "total_fetched": 0,
        "inserted": 0,
        "updated": 0,
        "skipped": 0,
        "skipped_missing_key": 0,
    }
    while True:
        items, total_count = _fetch_page(
            ENDPOINTS[risk_type],
            api_key=api_key,
            page=page,
            page_size=page_size,
        )
        stats["total_fetched"] += len(items)
        for item in items:
            if _is_api_deleted(item):
                _delete_taboo(cursor, risk_type, item)
                stats["skipped"] += 1
                continue
            normalized = _normalize_item(risk_type, item)
            if not normalized:
                stats["skipped"] += 1
                continue
            action = _upsert_taboo(cursor, normalized)
            stats[action] += 1

        if not items or page * page_size >= total_count:
            break
        if max_pages is not None and page >= max_pages:
            break
        page += 1
    return stats


def start_background_dur_sync() -> None:
    """서버 기동 시 dur_taboo 가 비어 있으면 식약처 기준을 백그라운드로 받는다."""
    global _BOOTSTRAP_STARTED
    if not DUR_AUTO_SYNC or not DUR_API_KEY or _BOOTSTRAP_STARTED:
        return
    if _dur_taboo_count() > 0:
        return
    _BOOTSTRAP_STARTED = True
    thread = threading.Thread(
        target=_bootstrap_dur_sync,
        name="dur-bootstrap-sync",
        daemon=True,
    )
    thread.start()
    logger.info("식약처 DUR 기준 백그라운드 동기화를 시작했습니다.")


def start_background_user_dur_refresh(user_id: str) -> bool:
    """등록 응답을 막지 않고 사용자 활성 약의 최신 DUR 자료를 갱신한다."""
    uid = str(user_id or "").strip()
    if not uid or not DUR_AUTO_SYNC or not DUR_API_KEY:
        return False
    with _USER_REFRESH_LOCK:
        if uid in _USERS_REFRESHING:
            return False
        _USERS_REFRESHING.add(uid)
    thread = threading.Thread(
        target=_refresh_user_dur,
        args=(uid,),
        name=f"dur-user-refresh-{uid[:12]}",
        daemon=True,
    )
    thread.start()
    return True


def _refresh_user_dur(user_id: str) -> None:
    try:
        from app.models.schemas import DurAnalyzeRequest
        from app.services.dur_service import analyze_dur

        analyze_dur(
            DurAnalyzeRequest(user_id=user_id, medicine_codes=[]),
            refresh=True,
        )
        logger.info("사용자 DUR 백그라운드 갱신 완료 user_id=%s", user_id)
    except Exception:
        logger.warning(
            "사용자 DUR 백그라운드 갱신 실패 user_id=%s",
            user_id,
            exc_info=True,
        )
    finally:
        with _USER_REFRESH_LOCK:
            _USERS_REFRESHING.discard(user_id)


def _bootstrap_dur_sync() -> None:
    try:
        with _SYNC_LOCK:
            if _dur_taboo_count() > 0:
                return
            sync_mfds_dur(
                DurSyncRequest(
                    page_size=100,
                    max_pages=DUR_BOOTSTRAP_MAX_PAGES,
                )
            )
            logger.info(
                "식약처 DUR 기준 동기화 완료 row_count=%s",
                _dur_taboo_count(),
            )
    except Exception:
        logger.warning("식약처 DUR 백그라운드 동기화 실패", exc_info=True)


def refresh_dur_for_ingredients(
    names: list[str],
    *,
    risk_types: set[str] | None = None,
    force_refresh: bool = False,
) -> dict[str, Any]:
    """검사에 필요한 성분만 식약처에서 받아 dur_taboo 에 넣는다."""
    queries = _ingredient_query_terms(names)
    if not queries:
        return {"status": "no_queries", "fetched": 0, "upserted": 0}
    if not DUR_API_KEY:
        return {"status": "skipped_missing_key", "fetched": 0, "upserted": 0}
    if not DUR_AUTO_SYNC:
        return {"status": "disabled", "fetched": 0, "upserted": 0}

    fetched = 0
    upserted = 0
    errors: list[str] = []
    try:
        with _SYNC_LOCK:
            conn = get_connection()
            try:
                cursor = conn.cursor()
                pending = (
                    queries
                    if force_refresh
                    else [
                        query
                        for query in queries
                        if not _has_taboo_for_ingredient(cursor, query)
                    ]
                )
                requested_types = [
                    risk_type
                    for risk_type in ENDPOINTS
                    if risk_types is None or risk_type in risk_types
                ]
                for query_variant_index, query in enumerate(pending):
                    for risk_type in requested_types:
                        stats = _sync_ingredient_type(
                            cursor,
                            risk_type,
                            query=query,
                            api_key=DUR_API_KEY,
                            query_variant_index=query_variant_index,
                        )
                        fetched += stats["fetched"]
                        upserted += stats["upserted"]
                        if stats.get("error"):
                            errors.append(str(stats["error"]))
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.close()
    except Exception as error:
        logger.warning("성분 DUR 동기화 실패: %s", error, exc_info=True)
        return {
            "status": "failed",
            "fetched": fetched,
            "upserted": upserted,
            "error": type(error).__name__,
        }
    if errors:
        status = "failed" if upserted == 0 and fetched == 0 else "partial"
        return {
            "status": status,
            "fetched": fetched,
            "upserted": upserted,
            "error": errors[0],
            "error_count": len(errors),
        }
    return {"status": "ok", "fetched": fetched, "upserted": upserted}


def _ingredient_query_terms(names: list[str]) -> list[str]:
    from app.services.pharmacist.ingredient import (
        clean_ingredient_text,
        ingredient_keys,
    )

    terms: list[str] = []
    seen: set[str] = set()
    for name in names:
        cleaned = clean_ingredient_text(name)
        cleaned_parts = [part.strip() for part in cleaned.split("|") if part.strip()]
        candidates = cleaned_parts or [cleaned]
        for candidate in (*candidates, *ingredient_keys(name)):
            text = str(candidate or "").strip()
            if len(text) < 2 or text in seen:
                continue
            seen.add(text)
            terms.append(text)
    return terms


def _dur_taboo_count() -> int:
    conn = get_connection()
    try:
        row = conn.execute("SELECT COUNT(*) FROM dur_taboo").fetchone()
        return int(row[0] if row else 0)
    except Exception:
        return 0
    finally:
        conn.close()


def _has_taboo_for_ingredient(
    cursor,
    query: str,
    *,
    risk_type: str | None = None,
) -> bool:
    from app.services.pharmacist.ingredient import normalize_ingredient

    key = normalize_ingredient(query)
    if not key:
        return False
    rows = cursor.execute(
        """
        SELECT ingredient_a, ingredient_b, taboo_type FROM dur_taboo
        """
    ).fetchall()
    for row in rows:
        if risk_type and str(row["taboo_type"] or "") != risk_type:
            continue
        a = normalize_ingredient(row["ingredient_a"])
        b = normalize_ingredient(row["ingredient_b"])
        if key == a or key == b:
            return True
    return False


def _sync_ingredient_type(
    cursor,
    risk_type: str,
    *,
    query: str,
    api_key: str,
    query_variant_index: int | None = None,
) -> dict[str, Any]:
    from app.services.pharmacist.ingredient import normalize_ingredient

    stats = {"fetched": 0, "upserted": 0, "error": None}
    ingredient_mention_pass_count = 0
    ingr_name_present_count = 0
    ingr_name_normalized_match_count = 0
    ingr_eng_name_present_count = 0
    ingr_code_present_count = 0
    whole_item_mention_match_count = 0
    deleted_item_count = 0
    normalize_success_count = 0
    normalize_rejected_missing_ingredient_count = 0
    normalize_rejected_other_count = 0
    pre_normalize_exit = False
    for param_key in (DUR_INGREDIENT_QUERY_PARAM[risk_type],):
        page = 1
        used_filter = False
        while page <= _MAX_INGREDIENT_PAGES:
            try:
                items, total_count = _fetch_page(
                    ENDPOINTS[risk_type],
                    api_key=api_key,
                    page=page,
                    page_size=100,
                    extra_params={param_key: query},
                )
            except HTTPException as error:
                stats["error"] = error.detail
                break
            stats["fetched"] += len(items)
            normalized_query = normalize_ingredient(query)
            item_matches = [
                (item, _item_mentions_ingredient(item, query)) for item in items
            ]
            for item, whole_item_match in item_matches:
                ingr_name = _first(
                    item,
                    "INGR_KOR_NAME" if risk_type == "병용금기" else "INGR_NAME",
                )
                ingr_eng_name = _first(item, "INGR_ENG_NAME")
                ingr_code = _first(item, "INGR_CODE")
                if ingr_name:
                    ingr_name_present_count += 1
                    if normalized_query and normalized_query in normalize_ingredient(
                        ingr_name
                    ):
                        ingr_name_normalized_match_count += 1
                if ingr_eng_name:
                    ingr_eng_name_present_count += 1
                if ingr_code:
                    ingr_code_present_count += 1
                if whole_item_match:
                    whole_item_mention_match_count += 1
            matched = [item for item, is_match in item_matches if is_match]
            ingredient_mention_pass_count += len(matched)
            if items and not matched:
                pre_normalize_exit = True
                _log_dur_raw_mismatch(
                    risk_type,
                    query_parameter=param_key,
                    normalized_query=normalized_query,
                    items=items,
                )
                break
            used_filter = True
            for item in matched:
                if _is_api_deleted(item):
                    deleted_item_count += 1
                    _delete_taboo(cursor, risk_type, item)
                    continue
                normalized = _normalize_item(risk_type, item)
                if not normalized:
                    missing_required_ingredient = not _first(
                        item,
                        "INGR_KOR_NAME",
                        "INGR_NAME",
                        "INGR_ENG_NAME",
                    )
                    if risk_type == "병용금기":
                        missing_required_ingredient = (
                            missing_required_ingredient
                            or not _first(
                                item,
                                "MIXTURE_INGR_KOR_NAME",
                                "MIXTURE_INGR_ENG_NAME",
                            )
                        )
                    if missing_required_ingredient:
                        normalize_rejected_missing_ingredient_count += 1
                    else:
                        normalize_rejected_other_count += 1
                    continue
                normalize_success_count += 1
                action = _upsert_taboo(cursor, normalized)
                if action in {"inserted", "updated"}:
                    stats["upserted"] += 1
            if not items or page * 100 >= total_count:
                break
            page += 1
        if used_filter:
            stats["error"] = None
            break
    logger.warning(
        "DUR sync diagnostic risk_type=%s query_variant_index=%s fetched_count=%d "
        "ingr_name_present_count=%d ingr_name_normalized_match_count=%d "
        "ingr_eng_name_present_count=%d ingr_code_present_count=%d "
        "whole_item_mention_match_count=%d "
        "ingredient_mention_pass_count=%d deleted_item_count=%d "
        "normalize_success_count=%d "
        "normalize_rejected_missing_ingredient_count=%d "
        "normalize_rejected_other_count=%d upserted_count=%d "
        "pre_normalize_exit=%s error_present=%s",
        risk_type,
        query_variant_index,
        stats["fetched"],
        ingr_name_present_count,
        ingr_name_normalized_match_count,
        ingr_eng_name_present_count,
        ingr_code_present_count,
        whole_item_mention_match_count,
        ingredient_mention_pass_count,
        deleted_item_count,
        normalize_success_count,
        normalize_rejected_missing_ingredient_count,
        normalize_rejected_other_count,
        stats["upserted"],
        pre_normalize_exit,
        bool(stats["error"]),
    )
    return stats


def _log_dur_raw_mismatch(
    risk_type: str,
    *,
    query_parameter: str,
    normalized_query: str,
    items: list[dict[str, Any]],
) -> None:
    raw_key_sample = [sorted(str(key) for key in item.keys()) for item in items[:3]]
    common_fields = {
        "ingr_name_present_count": sum(bool(_first(item, "INGR_NAME")) for item in items),
        "ingr_eng_present_count": sum(
            bool(_first(item, "INGR_ENG_NAME")) for item in items
        ),
        "ingr_code_present_count": sum(bool(_first(item, "INGR_CODE")) for item in items),
    }
    if risk_type == "병용금기":
        field_presence = {
            "primary_kor_present_count": sum(
                bool(_first(item, "INGR_KOR_NAME")) for item in items
            ),
            "primary_eng_present_count": common_fields["ingr_eng_present_count"],
            "primary_code_present_count": common_fields["ingr_code_present_count"],
            "mixture_kor_present_count": sum(
                bool(_first(item, "MIXTURE_INGR_KOR_NAME")) for item in items
            ),
            "mixture_eng_present_count": sum(
                bool(_first(item, "MIXTURE_INGR_ENG_NAME")) for item in items
            ),
            "mixture_code_present_count": sum(
                bool(_first(item, "MIXTURE_INGR_CODE")) for item in items
            ),
        }
    else:
        field_presence = dict(common_fields)
        if risk_type == "연령금기":
            field_presence["age_base_present_count"] = sum(
                bool(_first(item, "AGE_BASE")) for item in items
            )
        elif risk_type == "임부금기":
            field_presence["grade_present_count"] = sum(
                bool(_first(item, "GRADE")) for item in items
            )
        elif risk_type == "효능군중복":
            field_presence.update(
                {
                    "effect_code_present_count": sum(
                        bool(_first(item, "EFFECT_CODE")) for item in items
                    ),
                    "sers_name_present_count": sum(
                        bool(_first(item, "SERS_NAME")) for item in items
                    ),
                    "class_name_present_count": sum(
                        bool(_first(item, "CLASS_NAME")) for item in items
                    ),
                }
            )
    logger.warning(
        "DUR raw mismatch diagnostic risk_type=%s operation=%s "
        "query_parameter=%s normalized_query_present=%s "
        "normalized_query_length=%d fetched_count=%d raw_key_sample=%s "
        "field_presence=%s pre_normalize_exit=true "
        "normalize_skipped_reason=no_ingredient_mention_match",
        risk_type,
        ENDPOINTS[risk_type],
        query_parameter,
        bool(normalized_query),
        len(normalized_query),
        len(items),
        raw_key_sample,
        field_presence,
    )


def _item_mentions_ingredient(item: dict[str, Any], query: str) -> bool:
    from app.services.pharmacist.ingredient import normalize_ingredient

    needle = normalize_ingredient(query)
    if not needle:
        return False
    blob = normalize_ingredient(json.dumps(item, ensure_ascii=False))
    return needle in blob


def _fetch_page(
    endpoint: str,
    *,
    api_key: str,
    page: int,
    page_size: int,
    extra_params: dict[str, Any] | None = None,
) -> tuple[list[dict[str, Any]], int]:
    url = f"{DUR_API_BASE_URL}/{endpoint}"
    params = {
        "serviceKey": unquote(api_key.strip()),
        "pageNo": page,
        "numOfRows": page_size,
        "type": "json",
    }
    if extra_params:
        params.update({key: value for key, value in extra_params.items() if value})
    try:
        response = requests.get(
            url,
            params=params,
            timeout=TIMEOUT_SECONDS,
        )
    except requests.RequestException as error:
        logger.warning(
            "MFDS DUR request failed endpoint=%s error=%s",
            endpoint,
            type(error).__name__,
        )
        raise HTTPException(
            status_code=502,
            detail="식약처 DUR API에 연결할 수 없습니다.",
        ) from error

    if not response.ok:
        _log_external_response(endpoint, response)
        raise HTTPException(
            status_code=502,
            detail=f"식약처 DUR API 호출 실패 (외부 HTTP {response.status_code})",
        )

    try:
        payload = _parse_response(response)
    except (ValueError, ElementTree.ParseError) as error:
        _log_external_response(endpoint, response)
        raise HTTPException(
            status_code=502,
            detail="식약처 DUR API 응답 형식을 해석할 수 없습니다.",
        ) from error

    header = payload.get("header") or payload.get("response", {}).get("header", {})
    result_code = str(header.get("resultCode") or "00")
    if result_code not in {"00", "0"}:
        _log_external_response(endpoint, response)
        raise HTTPException(
            status_code=502,
            detail=f"식약처 DUR API 오류: {header.get('resultMsg') or result_code}",
        )
    body = payload.get("body") or payload.get("response", {}).get("body", {})
    items = body.get("items", {}) if isinstance(body, dict) else {}
    items = _extract_items(items)
    return (
        items,
        int(body.get("totalCount") or 0),
    )


def _extract_items(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, dict):
        value = value.get("item", value)
    if isinstance(value, dict):
        return [value]
    if not isinstance(value, list):
        return []

    result = []
    for entry in value:
        if isinstance(entry, dict) and isinstance(entry.get("item"), dict):
            result.append(entry["item"])
        elif isinstance(entry, dict):
            result.append(entry)
    return result


def _parse_response(response: requests.Response) -> dict[str, Any]:
    content_type = response.headers.get("content-type", "").lower()
    text = response.text.lstrip()
    if "json" in content_type or text.startswith(("{", "[")):
        payload = response.json()
        if not isinstance(payload, dict):
            raise ValueError("DUR response root is not an object.")
        return payload
    if "xml" in content_type or text.startswith("<"):
        return _xml_to_payload(response.text)
    raise ValueError(f"Unsupported DUR response content type: {content_type}")


def _xml_to_payload(text: str) -> dict[str, Any]:
    root = ElementTree.fromstring(text)
    error_message = root.findtext(".//returnAuthMsg") or root.findtext(
        ".//errMsg"
    )
    if error_message:
        return {
            "header": {
                "resultCode": root.findtext(".//returnReasonCode") or "ERROR",
                "resultMsg": error_message,
            },
            "body": {},
        }

    header_node = root.find(".//header")
    body_node = root.find(".//body")
    header = (
        {child.tag: child.text for child in header_node}
        if header_node is not None
        else {}
    )
    body: dict[str, Any] = {}
    if body_node is not None:
        for child in body_node:
            if child.tag == "items":
                body["items"] = {
                    "item": [
                        {field.tag: field.text for field in item}
                        for item in child.findall("item")
                    ]
                }
            else:
                body[child.tag] = child.text
    return {"header": header, "body": body}


def _log_external_response(
    endpoint: str,
    response: requests.Response,
) -> None:
    preview = _masked_preview(response.text)
    logger.warning(
        "MFDS DUR response error endpoint=%s status=%s content_type=%s body=%s",
        endpoint,
        response.status_code,
        response.headers.get("content-type", ""),
        preview,
    )


def _masked_preview(value: str) -> str:
    return re.sub(
        r"(?i)(serviceKey=)[^&\s<]+",
        r"\1***",
        value[:500].replace("\r", " ").replace("\n", " "),
    )


def _is_api_deleted(item: dict[str, Any]) -> bool:
    del_yn = str(item.get("DEL_YN") or "N").strip()
    return del_yn.upper() in {"Y", "삭제", "DELETE", "DELETED"} or del_yn == "삭제"


def _delete_taboo(cursor, risk_type: str, item: dict[str, Any]) -> None:
    external_id = _first(item, "DUR_SEQ")
    if not external_id:
        return
    cursor.execute(
        """
        DELETE FROM dur_taboo
        WHERE source = ? AND taboo_type = ? AND external_id = ?
        """,
        (MFDS_DUR_SOURCE, risk_type, external_id),
    )


def _normalize_item(
    risk_type: str,
    item: dict[str, Any],
) -> dict[str, Any] | None:
    # 식약처는 DEL_YN 에 Y/N 또는 정상/삭제를 씀. 삭제 행은 넣지 않음.
    del_yn = str(item.get("DEL_YN") or "N").strip()
    if del_yn.upper() in {"Y", "삭제", "DELETE", "DELETED"} or del_yn == "삭제":
        return None

    ingredient_a = _first(
        item,
        "INGR_KOR_NAME",
        "INGR_NAME",
        "INGR_ENG_NAME",
    )
    if not ingredient_a:
        return None

    ingredient_b = None
    ingredient_b_code = None
    if risk_type == "병용금기":
        ingredient_b = _first(
            item,
            "MIXTURE_INGR_KOR_NAME",
            "MIXTURE_INGR_ENG_NAME",
        )
        ingredient_b_code = _first(item, "MIXTURE_INGR_CODE")
        if not ingredient_b:
            return None
    elif risk_type == "효능군중복":
        # 같은 EFFECT_CODE 끼리 겹칠 때만 주의 → 분석 시 그룹 키로 사용
        ingredient_b = _first(item, "EFFECT_CODE", "SERS_NAME", "CLASS_NAME")

    min_age, max_age = _parse_age_base(
        _first(item, "AGE_BASE") if risk_type == "연령금기" else None
    )
    external_id = _first(item, "DUR_SEQ")
    if not external_id:
        external_id = "|".join(
            filter(
                None,
                (
                    risk_type,
                    _first(item, "INGR_CODE"),
                    ingredient_b_code,
                    _first(item, "NOTIFICATION_DATE"),
                ),
            )
        )

    return {
        "ingredient_a": ingredient_a,
        "ingredient_b": ingredient_b,
        "taboo_type": risk_type,
        "severity": (
            "HIGH" if risk_type in {"병용금기", "효능군중복"} else "MEDIUM"
        ),
        "description": _first(item, "PROHBT_CONTENT", "REMARK")
        or f"식약처 {risk_type} 정보입니다.",
        "source": MFDS_DUR_SOURCE,
        "external_id": external_id,
        "ingredient_a_code": _first(item, "INGR_CODE"),
        "ingredient_b_code": ingredient_b_code,
        "min_age": min_age,
        "max_age": max_age,
        "pregnancy_grade": (
            _first(item, "GRADE") if risk_type == "임부금기" else None
        ),
        "notification_date": _first(item, "NOTIFICATION_DATE"),
        "raw_json": json.dumps(item, ensure_ascii=False),
    }


def _upsert_taboo(cursor, item: dict[str, Any]) -> str:
    existing = cursor.execute(
        """
        SELECT id FROM dur_taboo
        WHERE source = ? AND taboo_type = ? AND external_id = ?
        """,
        (item["source"], item["taboo_type"], item["external_id"]),
    ).fetchone()
    cursor.execute(
        """
        INSERT INTO dur_taboo (
            ingredient_a, ingredient_b, taboo_type, severity, description,
            source, external_id, ingredient_a_code, ingredient_b_code,
            min_age, max_age, pregnancy_grade, notification_date, raw_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source, taboo_type, external_id) WHERE external_id IS NOT NULL
        DO UPDATE SET
            ingredient_a = excluded.ingredient_a,
            ingredient_b = excluded.ingredient_b,
            severity = excluded.severity,
            description = excluded.description,
            ingredient_a_code = excluded.ingredient_a_code,
            ingredient_b_code = excluded.ingredient_b_code,
            min_age = excluded.min_age,
            max_age = excluded.max_age,
            pregnancy_grade = excluded.pregnancy_grade,
            notification_date = excluded.notification_date,
            raw_json = excluded.raw_json,
            updated_at = CURRENT_TIMESTAMP
        """,
        (
            item["ingredient_a"],
            item["ingredient_b"],
            item["taboo_type"],
            item["severity"],
            item["description"],
            item["source"],
            item["external_id"],
            item["ingredient_a_code"],
            item["ingredient_b_code"],
            item["min_age"],
            item["max_age"],
            item["pregnancy_grade"],
            item["notification_date"],
            item["raw_json"],
        ),
    )
    return "updated" if existing else "inserted"


def _parse_age_base(value: str | None) -> tuple[int | None, int | None]:
    """AGE_BASE → (min_age, max_age) 금기 연령대. 파싱 불가면 (None, None)."""
    if not value:
        return None, None
    text = str(value).strip()

    # 개월/주: 연 단위로는 영아(0세)만 해당. 성인 오탐 방지.
    month_match = re.search(r"(\d+)\s*개월", text)
    week_match = re.search(r"(\d+)\s*주", text)
    if month_match or week_match:
        if "이상" in text or "초과" in text:
            months = int((month_match or week_match).group(1))
            if week_match and not month_match:
                months = max(1, int(week_match.group(1)) // 4)
            min_age = max(0, months // 12)
            if "초과" in text and months % 12 == 0:
                min_age += 1
            return min_age, None
        # 미만/이하/그 외 → 만 0세(1세 미만)만 금기로 본다
        return None, 0

    match = re.search(r"(\d+)\s*세", text)
    if not match:
        return None, None
    age = int(match.group(1))
    if "이상" in text or "초과" in text:
        return age + (1 if "초과" in text else 0), None
    if "미만" in text:
        return None, max(age - 1, 0)
    # "N세 이하" 및 숫자만 있는 경우 → max_age = N
    return None, age


def _first(item: dict[str, Any], *keys: str) -> str | None:
    for key in keys:
        value = item.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return None


def import_combination_partners_from_api(ingredient: str) -> dict[str, Any]:
    """병용금기 상대를 DUR DB에 넣고, 허가 제품 1개씩 미러·앱 medicines에 복사한다."""
    from app.services.mfds_drug_permission.client import (
        extract_items,
        fetch_permission_list_page,
    )
    from app.services.mfds_drug_permission.db import (
        get_permission_connection,
        upsert_list_item,
    )
    from app.services.mfds_drug_permission.sync import (
        ensure_detail_for_product,
        initialize_permission_db,
    )
    from app.services.pharmacist.ingredient import normalize_ingredient
    from app.services.pharmacist.retrieve import (
        retrieve_official,
        upsert_official_app_medicine,
    )

    query = (ingredient or "").strip()
    if not query or not DUR_API_KEY:
        return {"status": "skipped", "dur_upserted": 0, "products": []}

    with _SYNC_LOCK:
        conn = get_connection()
        try:
            stats = _sync_ingredient_type(
                conn.cursor(),
                "병용금기",
                query=query,
                api_key=DUR_API_KEY,
            )
            conn.commit()
        finally:
            conn.close()

    key = normalize_ingredient(query)
    conn = get_connection()
    try:
        rows = conn.execute(
            """
            SELECT ingredient_a, ingredient_b FROM dur_taboo
            WHERE taboo_type = '병용금기'
            """
        ).fetchall()
    finally:
        conn.close()

    partners: list[str] = []
    seen: set[str] = set()
    for row in rows:
        a = str(row["ingredient_a"] or "")
        b = str(row["ingredient_b"] or "")
        other = ""
        if normalize_ingredient(a) == key:
            other = b
        elif normalize_ingredient(b) == key:
            other = a
        if other and other not in seen:
            seen.add(other)
            partners.append(other)

    initialize_permission_db()
    imported: list[str] = []
    failed: list[str] = []
    for partner in partners:
        chosen = None
        for variant in _partner_search_names(partner):
            try:
                payload = fetch_permission_list_page(
                    page_no=1,
                    num_of_rows=15,
                    item_name=variant,
                    timeout=15,
                )
            except Exception:
                continue
            chosen = _prefer_oral_product(partner, extract_items(payload))
            if chosen:
                break
        if not chosen:
            failed.append(partner)
            continue
        seq = str(chosen.get("ITEM_SEQ") or "")
        name = str(chosen.get("ITEM_NAME") or "")
        perm = get_permission_connection()
        try:
            upsert_list_item(perm, chosen)
            perm.commit()
        finally:
            perm.close()
        if seq and name:
            ensure_detail_for_product(seq, name)
        official = retrieve_official(name)
        if not official:
            failed.append(partner)
            continue
        upsert_official_app_medicine(official)
        imported.append(name)

    return {
        "status": "ok",
        "dur_fetched": stats.get("fetched", 0),
        "dur_upserted": stats.get("upserted", 0),
        "partners": partners,
        "products": imported,
        "failed": failed,
    }


def _partner_search_names(partner: str) -> list[str]:
    names = [partner, f"{partner}정"]
    if partner == "시탈로프람":
        names = ["시탈로프람정", "시탈로프람"]
    if partner == "토레미펜":
        names = ["토레미펜", "토레미펜정", "패레스톤"]
    return list(dict.fromkeys(names))


def _prefer_oral_product(query: str, items: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not items:
        return None
    needle = "".join(query.split())
    ranked: list[tuple[int, int, dict[str, Any]]] = []
    for item in items:
        name = str(item.get("ITEM_NAME") or "")
        compact = "".join(name.split())
        score = 0
        idx = compact.find(needle) if needle else -1
        if idx >= 0:
            score += 8 - min(idx, 6)
        else:
            score -= 4
        if query == "시탈로프람" and "에스시탈로프람" in compact:
            score -= 12
        if "주사" in name:
            score -= 4
        if "정" in name or "캡슐" in name:
            score += 2
        ranked.append((score, len(name), item))
    ranked.sort(key=lambda row: (-row[0], row[1]))
    best = ranked[0]
    if best[0] < 0:
        return None
    return best[2]
