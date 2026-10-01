"""CLOVA OCR fields -> deterministic prescription structure."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from app.services.ocr.engine import extract_raw_text
from app.services.ocr.parser import parse_prescription_text


@dataclass
class OcrPipelineResult:
    ok: bool
    raw_text: str = ""
    structured: dict[str, Any] | None = None
    error: str | None = None
    trace: dict[str, Any] = field(default_factory=dict)


def _parse_result(raw_text: str, engine_name: str | None = None, **extra_trace: Any) -> OcrPipelineResult:
    parsed = parse_prescription_text(raw_text, tables=extra_trace.get("tables"))
    if not parsed or not parsed.get("items"):
        trace = {"stage": "parser", **extra_trace}
        if engine_name:
            trace["engine"] = engine_name
        return OcrPipelineResult(False, raw_text, error="parse_failed", trace=trace)
    trace = {
        "stage": "done",
        "parser_engine": parsed.get("parser_engine"),
        **extra_trace,
    }
    if engine_name:
        trace["engine"] = engine_name
    return OcrPipelineResult(True, raw_text, parsed, trace=trace)


def run_ocr_pipeline(image_bytes: bytes) -> OcrPipelineResult:
    engine = extract_raw_text(image_bytes)
    extra: dict[str, Any] = {}
    if not engine.ok:
        return OcrPipelineResult(
            False,
            error=engine.error,
            trace={"engine": engine.engine_name, "stage": "engine", **extra},
        )
    if engine.confidence is not None:
        extra["engine_confidence"] = engine.confidence
    if engine.fields:
        extra["fields"] = [dict(field) for field in engine.fields]
    if engine.tables:
        extra["tables"] = [dict(table) for table in engine.tables]
    return _parse_result(engine.raw_text, engine.engine_name, **extra)


def run_ocr_text_pipeline(raw_text: str) -> OcrPipelineResult:
    text = (raw_text or "").strip()
    if not text:
        return OcrPipelineResult(False, error="empty_raw_text", trace={"stage": "input"})
    return _parse_result(text)
