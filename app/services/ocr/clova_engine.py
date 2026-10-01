"""Naver CLOVA OCR (General) — 이미지 → 글자(+박스)."""

from __future__ import annotations

import base64
import time
import uuid
from dataclasses import dataclass
from typing import Any

import requests

from app.core.config import CLOVA_OCR_API_URL, CLOVA_OCR_SECRET_KEY


@dataclass(frozen=True)
class ClovaOcrResult:
    ok: bool
    raw_text: str = ""
    fields: tuple[dict[str, Any], ...] = ()
    tables: tuple[dict[str, Any], ...] = ()
    error: str | None = None
    status_code: int | None = None


def _image_format(path_or_bytes_hint: str) -> str:
    lower = (path_or_bytes_hint or "").lower()
    if lower.endswith(".png"):
        return "png"
    if lower.endswith(".gif"):
        return "gif"
    if lower.endswith(".pdf"):
        return "pdf"
    if lower.endswith(".tif") or lower.endswith(".tiff"):
        return "tiff"
    return "jpg"


def extract_with_clova(
    image_bytes: bytes,
    *,
    image_name: str = "prescription.jpg",
    lang: str = "ko",
    enable_table_detection: bool = False,
    timeout_sec: float = 60.0,
) -> ClovaOcrResult:
    if not image_bytes:
        return ClovaOcrResult(False, error="empty_image")
    if not CLOVA_OCR_API_URL or not CLOVA_OCR_SECRET_KEY:
        return ClovaOcrResult(False, error="missing_clova_credentials")

    payload = {
        "version": "V2",
        "requestId": str(uuid.uuid4()),
        "timestamp": int(time.time() * 1000),
        "lang": lang,
        "enableTableDetection": enable_table_detection,
        "images": [
            {
                "format": _image_format(image_name),
                "name": image_name,
                "data": base64.b64encode(image_bytes).decode("ascii"),
            }
        ],
    }
    headers = {
        "Content-Type": "application/json; charset=UTF-8",
        "X-OCR-SECRET": CLOVA_OCR_SECRET_KEY,
    }
    try:
        response = requests.post(
            CLOVA_OCR_API_URL,
            headers=headers,
            json=payload,
            timeout=timeout_sec,
        )
    except requests.RequestException as error:
        return ClovaOcrResult(False, error=f"request_failed:{error}")

    if response.status_code != 200:
        detail = (response.text or "")[:300]
        return ClovaOcrResult(
            False,
            error=f"http_{response.status_code}:{detail}",
            status_code=response.status_code,
        )

    try:
        data = response.json()
    except ValueError:
        return ClovaOcrResult(False, error="invalid_json", status_code=response.status_code)

    images = data.get("images") if isinstance(data, dict) else None
    if not isinstance(images, list) or not images:
        return ClovaOcrResult(False, error="empty_images", status_code=response.status_code)

    first = images[0] if isinstance(images[0], dict) else {}
    infer_result = str(first.get("inferResult") or "")
    if infer_result and infer_result.upper() not in {"SUCCESS", "OK"}:
        return ClovaOcrResult(
            False,
            error=f"infer_{infer_result}:{first.get('message')}",
            status_code=response.status_code,
        )

    fields_raw = first.get("fields") or []
    tables_raw = first.get("tables") or []
    fields: list[dict[str, Any]] = []
    text_parts: list[str] = []
    if isinstance(fields_raw, list):
        for field in fields_raw:
            if not isinstance(field, dict):
                continue
            text = str(field.get("inferText") or "").strip()
            if not text:
                continue
            text_parts.append(text)
            text_parts.append("\n" if field.get("lineBreak") else " ")
            fields.append(
                {
                    "text": text,
                    "confidence": field.get("inferConfidence"),
                    "boundingPoly": field.get("boundingPoly"),
                    "lineBreak": field.get("lineBreak"),
                }
            )

    raw_text = "".join(text_parts).strip()
    # CLOVA가 준 표·셀의 row/column/span/좌표를 가공하지 않고 추적값으로 보존한다.
    tables = tuple(table for table in tables_raw if isinstance(table, dict))
    if not raw_text:
        return ClovaOcrResult(
            False,
            error="empty_raw_text",
            status_code=response.status_code,
            fields=tuple(fields),
            tables=tables,
        )
    return ClovaOcrResult(
        True,
        raw_text=raw_text,
        fields=tuple(fields),
        tables=tables,
        status_code=response.status_code,
    )
