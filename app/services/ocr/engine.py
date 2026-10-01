"""Prescription image to raw OCR text through CLOVA OCR only."""

from __future__ import annotations

from dataclasses import dataclass
from io import BytesIO
from typing import Any

from app.core.config import (
    CLOVA_OCR_API_URL,
    CLOVA_OCR_ENABLED,
    CLOVA_OCR_SECRET_KEY,
)

# 휴대폰 원본(수 MB)은 전송·인식이 느려져서, OCR 전에 긴 변을 줄인다.
_MAX_EDGE_PX = 1600
_JPEG_QUALITY = 85

@dataclass(frozen=True)
class OcrEngineResult:
    raw_text: str
    engine_name: str
    confidence: float | None
    ok: bool
    error: str | None = None
    fields: tuple[dict[str, Any], ...] = ()
    tables: tuple[dict[str, Any], ...] = ()


def _mime_type(image_bytes: bytes) -> str:
    if image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if image_bytes[:2] == b"\xff\xd8":
        return "image/jpeg"
    if image_bytes[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if image_bytes[:4] == b"RIFF" and image_bytes[8:12] == b"WEBP":
        return "image/webp"
    return "image/jpeg"


def _prepare_image(image_bytes: bytes) -> tuple[bytes, str]:
    """큰 사진은 줄이고, 대비·선명을 조금 올려 표 글자 인식률을 높인다."""
    try:
        from PIL import Image, ImageEnhance, ImageOps

        with Image.open(BytesIO(image_bytes)) as image:
            image = image.convert("RGB")
            image = ImageOps.exif_transpose(image)
            width, height = image.size
            longest = max(width, height)
            if longest > _MAX_EDGE_PX:
                scale = _MAX_EDGE_PX / float(longest)
                image = image.resize(
                    (max(1, int(width * scale)), max(1, int(height * scale))),
                    Image.Resampling.LANCZOS,
                )
            image = ImageEnhance.Contrast(image).enhance(1.15)
            image = ImageEnhance.Sharpness(image).enhance(1.1)
            buffer = BytesIO()
            image.save(buffer, format="JPEG", quality=_JPEG_QUALITY, optimize=True)
            return buffer.getvalue(), "image/jpeg"
    except Exception:
        return image_bytes, _mime_type(image_bytes)


def _error_code(error: Exception) -> str:
    text = f"{type(error).__name__} {error}".lower()
    if "timeout" in text or "deadline" in text:
        return "timeout"
    if "429" in text or "resource_exhausted" in text or "quota" in text:
        return "quota_exceeded"
    if "401" in text or "403" in text or "api key" in text or "unauth" in text:
        return "auth_error"
    if "503" in text or "unavailable" in text:
        return "unavailable"
    return type(error).__name__


def _clova_ready() -> bool:
    return bool(
        CLOVA_OCR_ENABLED and CLOVA_OCR_API_URL and CLOVA_OCR_SECRET_KEY
    )


def _mean_confidence(fields: tuple[dict[str, Any], ...]) -> float | None:
    values: list[float] = []
    for field in fields:
        raw = field.get("confidence")
        try:
            value = float(raw)
        except (TypeError, ValueError):
            continue
        if 0 <= value <= 1:
            values.append(value)
    if not values:
        return None
    return sum(values) / len(values)


def _extract_with_clova(image_bytes: bytes) -> OcrEngineResult:
    if not _clova_ready():
        return OcrEngineResult("", "clova-ocr", None, False, "missing_clova_credentials")
    try:
        from app.services.ocr.clova_engine import extract_with_clova

        prepared_bytes, _mime = _prepare_image(image_bytes)
        result = extract_with_clova(
            prepared_bytes,
            image_name="prescription.jpg",
            enable_table_detection=True,
        )
        if not result.ok:
            return OcrEngineResult(
                "", "clova-ocr", None, False, result.error or "clova_failed"
            )
        return OcrEngineResult(
            result.raw_text,
            "clova-ocr",
            _mean_confidence(result.fields),
            True,
            fields=result.fields,
            tables=result.tables,
        )
    except Exception as error:
        return OcrEngineResult("", "clova-ocr", None, False, _error_code(error))


def extract_raw_text(image_bytes: bytes) -> OcrEngineResult:
    """Extract text with CLOVA only; never create an untraceable fallback result."""
    if not image_bytes:
        return OcrEngineResult("", "none", None, False, "empty_image")
    if not _clova_ready():
        return OcrEngineResult(
            "",
            "clova-ocr",
            None,
            False,
            "missing_clova_credentials",
        )
    return _extract_with_clova(image_bytes)
