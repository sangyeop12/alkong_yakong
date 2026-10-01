"""HTTP client for MFDS DrugPrdtPrmsnInfoService07."""

from __future__ import annotations

import logging
from typing import Any

import requests

from app.core.config import (
    MFDS_DRUG_PERMISSION_API_KEY,
    MFDS_DRUG_PERMISSION_BASE_URL,
    MFDS_DRUG_PERMISSION_DETAIL_PATH,
    MFDS_DRUG_PERMISSION_LIST_PATH,
)

BASE_URL = MFDS_DRUG_PERMISSION_BASE_URL
LIST_PATH = f"{BASE_URL}{MFDS_DRUG_PERMISSION_LIST_PATH}"
DETAIL_PATH = f"{BASE_URL}{MFDS_DRUG_PERMISSION_DETAIL_PATH}"
TIMEOUT = 30

logger = logging.getLogger(__name__)


def _http_error_category(status_code: object) -> str:
    if not isinstance(status_code, int):
        return "unknown"
    if status_code == 400:
        return "bad_request"
    if status_code == 401:
        return "authentication"
    if status_code == 403:
        return "authorization"
    if status_code == 404:
        return "not_found"
    if status_code == 429:
        return "rate_limit"
    if 500 <= status_code <= 599:
        return "upstream_server_error"
    if 400 <= status_code <= 499:
        return "client_error"
    return "none"


def _log_http_diagnostic(response: requests.Response) -> None:
    logger.warning(
        "MFDS permission HTTP diagnostic status=%s content_type=%s "
        "error_category=%s",
        response.status_code,
        response.headers.get("content-type", "unknown"),
        _http_error_category(response.status_code),
    )


def fetch_permission_list_page(
    *,
    page_no: int,
    num_of_rows: int = 500,
    item_name: str | None = None,
    timeout: int | None = None,
) -> dict[str, Any]:
    if not MFDS_DRUG_PERMISSION_API_KEY:
        raise RuntimeError("MFDS_DRUG_PERMISSION_API_KEY가 없습니다.")
    params: dict[str, Any] = {
        "serviceKey": MFDS_DRUG_PERMISSION_API_KEY,
        "pageNo": page_no,
        "numOfRows": num_of_rows,
        "type": "json",
    }
    if item_name:
        params["item_name"] = item_name
    response = requests.get(
        LIST_PATH,
        params=params,
        timeout=TIMEOUT if timeout is None else timeout,
    )
    response.raise_for_status()
    return response.json()


def search_permission_products(
    item_name: str,
    *,
    limit: int,
    timeout: int | None = None,
) -> list[dict[str, Any]]:
    """Search official permission products by product name."""
    payload = fetch_permission_list_page(
        page_no=1,
        num_of_rows=limit,
        item_name=item_name,
        timeout=timeout,
    )
    if not isinstance(payload, dict):
        raise TypeError("MFDS permission response root must be an object")
    return extract_items(payload)


def fetch_permission_detail(
    item_name: str | None = None,
    *,
    item_seq: str | None = None,
) -> dict[str, Any] | None:
    if not MFDS_DRUG_PERMISSION_API_KEY:
        raise RuntimeError("MFDS_DRUG_PERMISSION_API_KEY가 없습니다.")
    params: dict[str, Any] = {
        "serviceKey": MFDS_DRUG_PERMISSION_API_KEY,
        "pageNo": 1,
        "numOfRows": 100 if item_seq else 1,
        "type": "json",
    }
    if item_name:
        params["item_name"] = item_name
    elif item_seq:
        params["item_seq"] = item_seq
    else:
        raise ValueError("item_name 또는 item_seq가 필요합니다.")
    response = requests.get(
        DETAIL_PATH,
        params=params,
        timeout=TIMEOUT,
    )
    _log_http_diagnostic(response)
    response.raise_for_status()
    items = extract_items(response.json())
    if item_seq:
        expected = str(item_seq).strip()
        return next(
            (
                item
                for item in items
                if str(item.get("ITEM_SEQ") or "").strip() == expected
            ),
            None,
        )
    return items[0] if items else None


def extract_items(payload: dict[str, Any]) -> list[dict[str, Any]]:
    body = payload.get("body")
    if body is None and isinstance(payload.get("response"), dict):
        body = payload["response"].get("body")
    if not isinstance(body, dict):
        return []
    items = body.get("items")
    if isinstance(items, dict) and "item" in items:
        items = items["item"]
    if isinstance(items, dict):
        items = [items]
    return items if isinstance(items, list) else []


def extract_total_count(payload: dict[str, Any]) -> int:
    body = payload.get("body")
    if body is None and isinstance(payload.get("response"), dict):
        body = payload["response"].get("body")
    if not isinstance(body, dict):
        return 0
    try:
        return int(body.get("totalCount") or 0)
    except (TypeError, ValueError):
        return 0
