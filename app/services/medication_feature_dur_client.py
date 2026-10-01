"""Read current medicines and DUR results from the medication-data service.

This module is used only by the team AI-pharmacist backend.  It deliberately
does not fall back to this process's SQLite database: the medication service is
the source of truth for OCR/manual registrations.
"""

from __future__ import annotations

import logging
from typing import Any
from urllib.parse import quote

import requests

from app.core.config import (
    MEDICATION_FEATURE_BASE_URL,
    MEDICATION_FEATURE_TIMEOUT_SECONDS,
)


_COMBINATION_TYPES = {"병용금기", "중복성분", "효능군중복"}
logger = logging.getLogger(__name__)


def _compact_name(value: Any) -> str:
    return "".join(str(value or "").split()).casefold()


def load_remote_current_medicines(*, user_id: str) -> dict[str, Any]:
    """Load the signed-in user's active medicines from the source-of-truth service."""

    uid = str(user_id or "").strip()
    if not uid:
        return _unavailable("missing_user_id")
    if not MEDICATION_FEATURE_BASE_URL:
        return _unavailable("medication_service_not_configured")
    try:
        response = requests.get(
            f"{MEDICATION_FEATURE_BASE_URL}/api/v1/users/{quote(uid, safe='')}/medicines",
            timeout=MEDICATION_FEATURE_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        payload = response.json()
    except (requests.RequestException, ValueError):
        return _unavailable("medication_service_unavailable")

    if not isinstance(payload, dict) or not isinstance(payload.get("medicines"), list):
        return _malformed()

    active_rows = [
        row
        for row in payload["medicines"]
        if isinstance(row, dict)
        and str(row.get("status") or "active") == "active"
    ]
    if not active_rows:
        return {"status": "empty", "items": [], "reason": "no_active_medicines"}

    items: list[dict[str, str]] = []
    names_by_code: dict[str, str] = {}
    incomplete = False
    for row in active_rows:
        code = str(row.get("medicine_code") or row.get("item_seq") or "").strip()
        name = str(
            row.get("official_product_name")
            or row.get("product_name")
            or ""
        ).strip()
        if not code or not name:
            incomplete = True
            continue
        previous_name = names_by_code.get(code)
        if previous_name is not None:
            if previous_name != name:
                incomplete = True
            continue
        names_by_code[code] = name
        items.append({"medicine_code": code, "product_name": name})

    if incomplete or len(items) != len({
        str(row.get("medicine_code") or row.get("item_seq") or "").strip()
        for row in active_rows
        if str(row.get("medicine_code") or row.get("item_seq") or "").strip()
    }):
        return {
            "status": "incomplete",
            "items": items,
            "reason": "medicine_identity_incomplete",
        }
    return {"status": "current", "items": items, "reason": None}


def load_remote_combination_context(
    *,
    user_id: str,
    selected_medicine: dict[str, Any] | None,
    additional_medicines: list[dict[str, Any]] | None = None,
    requested_types: set[str] | None = None,
    include_current_medicines: bool = True,
) -> dict[str, Any]:
    """Return prompt-ready DUR context without consulting the team DB."""

    uid = str(user_id or "").strip()
    checked_types = set(requested_types or _COMBINATION_TYPES)
    if not checked_types or not checked_types.issubset(_COMBINATION_TYPES):
        return _unavailable("unsupported_dur_check_type")
    if not uid:
        return _unavailable("missing_user_id")
    if not MEDICATION_FEATURE_BASE_URL:
        return _unavailable("medication_service_not_configured")
    medicines_context = (
        load_remote_current_medicines(user_id=uid)
        if include_current_medicines
        else {"status": "empty", "items": [], "reason": None}
    )
    if medicines_context["status"] not in {"current", "empty"}:
        return {**medicines_context, "has_risk": None}
    medicines = [dict(item) for item in medicines_context["items"]]
    names_by_code = {
        str(item.get("medicine_code") or "").strip(): str(
            item.get("product_name") or ""
        ).strip()
        for item in medicines
    }
    for medicine in additional_medicines or []:
        if not isinstance(medicine, dict):
            return _unavailable("temporary_medicine_unavailable")
        code = str(medicine.get("medicine_code") or "").strip()
        name = str(medicine.get("product_name") or "").strip()
        if not code or not name:
            return _unavailable("temporary_medicine_unavailable")
        stored_name = names_by_code.get(code)
        if stored_name is not None:
            if _compact_name(stored_name) != _compact_name(name):
                return _unavailable("temporary_medicine_identity_mismatch")
            continue
        names_by_code[code] = name
        medicines.append({"medicine_code": code, "product_name": name})

    if not medicines:
        return {**medicines_context, "has_risk": None}

    if selected_medicine is not None and not isinstance(selected_medicine, dict):
        return _unavailable("selected_medicine_unavailable")

    selected_code = str((selected_medicine or {}).get("medicine_code") or "").strip()
    selected_name = str((selected_medicine or {}).get("product_name") or "").strip()
    if selected_medicine is not None and (not selected_code or not selected_name):
        return _unavailable("selected_medicine_unavailable")

    selected_row = next(
        (
            row
            for row in medicines
            if str(row.get("medicine_code") or "").strip() == selected_code
        ),
        None,
    ) if selected_medicine is not None else None
    if selected_medicine is not None and selected_row is None:
        return _unavailable("selected_medicine_not_registered")
    stored_name = str(
        (selected_row or {}).get("product_name")
        or ""
    ).strip()
    if selected_medicine is not None and (
        not stored_name or stored_name != selected_name
    ):
        return _unavailable("selected_medicine_identity_mismatch")

    try:
        # Send the complete, already-validated scope explicitly. This lets the
        # medication service verify/cache every catalog row and perform a fresh
        # DUR lookup for this exact set instead of relying on a possibly stale
        # user-medicine join.
        requested_codes = list(names_by_code)
        dur_response = requests.post(
            f"{MEDICATION_FEATURE_BASE_URL}/api/v1/dur/analyze",
            json={
                "user_id": uid,
                "medicine_codes": requested_codes,
                "medicine_names_by_code": names_by_code,
            },
            timeout=MEDICATION_FEATURE_TIMEOUT_SECONDS,
        )
        dur_response.raise_for_status()
        payload = dur_response.json()
    except (requests.RequestException, ValueError):
        return _unavailable("dur_service_unavailable")

    if not isinstance(payload, dict):
        return _malformed()
    assessment = payload.get("assessment_status")
    analysis_complete = payload.get("analysis_complete")
    incomplete = payload.get("incomplete")
    has_risk = payload.get("has_risk")
    matches = payload.get("matches")
    incomplete_types = payload.get("incomplete_types")
    if (
        assessment not in {"SAFE", "RISK_FOUND", "INCOMPLETE"}
        or not isinstance(analysis_complete, bool)
        or not isinstance(incomplete, bool)
        or not isinstance(has_risk, bool)
        or not isinstance(matches, list)
        or any(not isinstance(item, dict) for item in matches)
        or (
            incomplete_types is not None
            and (
                not isinstance(incomplete_types, list)
                or any(not isinstance(item, str) for item in incomplete_types)
            )
        )
    ):
        return _malformed()

    analyzed_names = payload.get("medicine_names")
    scope_complete = isinstance(analyzed_names, list) and {
        _compact_name(name) for name in names_by_code.values()
    }.issubset({_compact_name(name) for name in analyzed_names})
    logger.warning(
        "Medication DUR scope diagnostic requested_count=%d analyzed_count=%d "
        "scope_complete=%s",
        len(names_by_code),
        len(analyzed_names) if isinstance(analyzed_names, list) else 0,
        scope_complete,
    )
    if not scope_complete:
        return {
            "status": "incomplete",
            "items": [],
            "has_risk": None,
            "reason": "medicine_analysis_scope_incomplete",
        }

    incomplete_type_set = set(incomplete_types or [])
    relevant_incomplete = checked_types & incomplete_type_set
    globally_incomplete = (
        assessment == "INCOMPLETE" or not analysis_complete or incomplete
    )
    logger.warning(
        "Medication DUR completion diagnostic assessment=%s "
        "analysis_complete=%s incomplete=%s incomplete_type_count=%d "
        "relevant_incomplete_type_count=%d sync_status=%s "
        "sync_fetched=%s sync_upserted=%s taboo_row_count=%s",
        assessment,
        analysis_complete,
        incomplete,
        len(incomplete_type_set),
        len(relevant_incomplete),
        str(payload.get("dur_sync_status") or "unknown"),
        payload.get("dur_sync_fetched"),
        payload.get("dur_sync_upserted"),
        payload.get("taboo_row_count"),
    )
    # The medication service evaluates age/pregnancy checks in the same response.
    # Those unrelated checks must not turn a completed combination/duplicate check
    # into a failure. If the response does not identify incomplete types, remain
    # conservative and reject it.
    if globally_incomplete and (incomplete_types is None or relevant_incomplete):
        return {
            "status": "incomplete",
            "items": [],
            "has_risk": None,
            "reason": "dur_analysis_incomplete",
        }

    items = [
        dict(item)
        for item in matches
        if item.get("type") in checked_types
    ]
    matched_types = {
        str(item.get("type") or "").strip()
        for item in items
        if str(item.get("type") or "").strip()
    }
    combination_has_risk = bool(items)
    if assessment == "SAFE" and (has_risk or matches):
        return _malformed()
    if assessment == "RISK_FOUND" and not has_risk:
        return _malformed()
    return {
        "status": "current",
        "items": items,
        "has_risk": combination_has_risk,
        "reason": None,
        "checked_types": sorted(checked_types),
        "zero_result_types": sorted(checked_types - matched_types),
    }


def _unavailable(reason: str) -> dict[str, Any]:
    return {
        "status": "missing",
        "items": [],
        "has_risk": None,
        "reason": reason,
    }


def _malformed() -> dict[str, Any]:
    return {
        "status": "malformed",
        "items": [],
        "has_risk": None,
        "reason": "invalid_medication_service_response",
    }
