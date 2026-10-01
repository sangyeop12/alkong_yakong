from app.services.ocr.engine import extract_raw_text
from app.services.ocr.parser import parse_prescription_text
from app.services.ocr.pipeline import run_ocr_pipeline, run_ocr_text_pipeline


def test_empty_image_fails_at_engine():
    result = extract_raw_text(b"")
    assert result.ok is False
    assert result.error == "empty_image"


def test_empty_text_pipeline_fails():
    result = run_ocr_text_pipeline("   ")
    assert result.ok is False
    assert result.trace.get("stage") == "input"


def test_empty_bytes_pipeline_fails():
    result = run_ocr_pipeline(b"")
    assert result.ok is False
    assert result.trace.get("stage") == "engine"


def test_parser_skips_blank_text():
    assert parse_prescription_text("") is None
    assert parse_prescription_text("  ") is None
