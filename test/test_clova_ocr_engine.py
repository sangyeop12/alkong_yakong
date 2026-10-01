import pytest
import requests

from app.services.ocr import clova_engine, engine
from app.services.ocr import pipeline


class _Response:
    status_code = 200
    text = ""

    def json(self):
        return {
            "images": [
                {
                    "inferResult": "SUCCESS",
                    "fields": [
                        {
                            "inferText": "아디팜정",
                            "inferConfidence": 0.98,
                            "boundingPoly": {"vertices": [{"x": 1, "y": 2}]},
                            "lineBreak": False,
                        },
                        {
                            "inferText": "0.50",
                            "inferConfidence": 0.86,
                            "boundingPoly": {"vertices": [{"x": 20, "y": 2}]},
                            "lineBreak": True,
                        },
                    ],
                    "tables": [
                        {
                            "cells": [
                                {"rowIndex": 0, "columnIndex": 1, "rowSpan": 1, "columnSpan": 1}
                            ]
                        }
                    ],
                }
            ]
        }


class _ErrorResponse:
    def __init__(self, status_code=500, text="server error", payload=None):
        self.status_code = status_code
        self.text = text
        self._payload = payload

    def json(self):
        if isinstance(self._payload, Exception):
            raise self._payload
        return self._payload


def test_clova_preserves_confidence_bounds_and_line_breaks(monkeypatch):
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_API_URL", "https://ocr.test")
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_SECRET_KEY", "secret")
    monkeypatch.setattr(clova_engine.requests, "post", lambda *args, **kwargs: _Response())

    result = clova_engine.extract_with_clova(b"image")

    assert result.ok is True
    assert result.raw_text == "아디팜정 0.50"
    assert result.fields[0]["confidence"] == 0.98
    assert result.fields[0]["boundingPoly"]["vertices"][0] == {"x": 1, "y": 2}
    assert result.fields[1]["lineBreak"] is True
    assert result.tables[0]["cells"][0]["rowIndex"] == 0
    assert result.tables[0]["cells"][0]["columnIndex"] == 1


def test_image_ocr_uses_clova_only_and_keeps_fields(monkeypatch):
    fields = (
        {"text": "아디팜정", "confidence": 0.98, "boundingPoly": {}, "lineBreak": True},
        {"text": "0.50", "confidence": 0.86, "boundingPoly": {}, "lineBreak": True},
    )
    monkeypatch.setattr(engine, "CLOVA_OCR_API_URL", "https://ocr.test")
    monkeypatch.setattr(engine, "CLOVA_OCR_SECRET_KEY", "secret")
    monkeypatch.setattr(
        clova_engine,
        "extract_with_clova",
        lambda *args, **kwargs: clova_engine.ClovaOcrResult(
            True,
            raw_text="아디팜정\n0.50",
            fields=fields,
        ),
    )

    result = engine.extract_raw_text(b"not-a-real-image")

    assert result.ok is True
    assert result.engine_name == "clova-ocr"
    assert result.fields == fields
    assert result.confidence == pytest.approx(0.92)


def test_image_ocr_fails_clearly_without_clova_configuration(monkeypatch):
    monkeypatch.setattr(engine, "CLOVA_OCR_API_URL", "")
    monkeypatch.setattr(engine, "CLOVA_OCR_SECRET_KEY", "")

    result = engine.extract_raw_text(b"image")

    assert result.ok is False
    assert result.engine_name == "clova-ocr"
    assert result.error == "missing_clova_credentials"


def test_pipeline_keeps_clova_fields_in_trace(monkeypatch):
    fields = (
        {
            "text": "아디팜정",
            "confidence": 0.94,
            "boundingPoly": {"vertices": []},
            "lineBreak": True,
        },
    )
    tables = ({"cells": [{"rowIndex": 0, "columnIndex": 0}]},)
    monkeypatch.setattr(
        pipeline,
        "extract_raw_text",
        lambda _image: engine.OcrEngineResult(
            "아디팜정 0.50 3 7",
            "clova-ocr",
            0.94,
            True,
            fields=fields,
            tables=tables,
        ),
    )

    result = pipeline.run_ocr_pipeline(b"image")

    assert result.ok is True
    assert result.trace["engine"] == "clova-ocr"
    assert result.trace["engine_confidence"] == 0.94
    assert result.trace["fields"][0]["confidence"] == 0.94
    assert result.trace["tables"][0]["cells"][0]["rowIndex"] == 0


def test_pipeline_uses_clova_table_rows_for_dosing(monkeypatch):
    def _cell(row, column, *words):
        return {
            "rowIndex": row,
            "columnIndex": column,
            "cellTextLines": [
                {"cellWords": [{"inferText": word} for word in words]}
            ],
        }

    table = {
        "cells": [
            _cell(0, 0, "약품명 및 용량"),
            _cell(0, 1, "1회 투약량"),
            _cell(0, 2, "1일 투여횟수"),
            _cell(0, 3, "투약 일수"),
            _cell(1, 0, "프리마란정", "알러지질환약"),
            _cell(1, 1, "0.50"),
            _cell(1, 2, "3"),
            _cell(1, 3, "7"),
            _cell(2, 0, "아디팜정", "항히스타민제"),
            _cell(2, 1, "0.50"),
            _cell(2, 2, "3"),
            _cell(2, 3, "7"),
            _cell(3, 0, "휴온스시메티딘정200밀리그램"),
            _cell(3, 1, "0.50"),
            _cell(3, 2, "3"),
            _cell(3, 3, "7"),
            _cell(4, 0, "프레벨액0.25%", "피부질환약"),
            _cell(4, 1, "1.00"),
            _cell(4, 2, "1"),
            _cell(4, 3, "1"),
        ]
    }
    raw_text = " ".join(
        [
            "프리마란정 0.50 3 7",
            "아디팜정 0.50 3 7",
            "휴온스시메티딘정200밀리그램 0.50 3 7",
            "프레벨액0.25% 1.00 1 1",
        ]
    )
    monkeypatch.setattr(
        pipeline,
        "extract_raw_text",
        lambda _image: engine.OcrEngineResult(
            raw_text,
            "clova-ocr",
            0.93,
            True,
            tables=(table,),
        ),
    )

    result = pipeline.run_ocr_pipeline(b"image")

    assert result.ok is True
    assert result.structured["parser_engine"] == "heuristic+clova-table"
    by_name = {item["drug_name"]: item for item in result.structured["items"]}
    assert by_name["프리마란정"]["dosage"] == "0.50"
    assert by_name["아디팜정"]["frequency_per_day"] == 3
    cimetidine = next(item for name, item in by_name.items() if "시메티딘" in name)
    assert cimetidine["dosage"] == "0.50"
    assert cimetidine["duration_days"] == 7
    prebel = next(item for name, item in by_name.items() if "프레벨" in name)
    assert prebel["dosage"] == "1.00"
    assert prebel["frequency_per_day"] == 1
    assert prebel["duration_days"] == 1


def test_clova_network_timeout_returns_request_failed(monkeypatch):
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_API_URL", "https://ocr.test")
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_SECRET_KEY", "secret")

    def _timeout(*args, **kwargs):
        raise requests.Timeout("timed out")

    monkeypatch.setattr(clova_engine.requests, "post", _timeout)

    result = clova_engine.extract_with_clova(b"image")

    assert result.ok is False
    assert result.error.startswith("request_failed:")
    assert "timed out" in result.error
    assert result.status_code is None


def test_clova_http_error_keeps_status_without_parsing_result(monkeypatch):
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_API_URL", "https://ocr.test")
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_SECRET_KEY", "secret")
    monkeypatch.setattr(
        clova_engine.requests,
        "post",
        lambda *args, **kwargs: _ErrorResponse(status_code=503, text="unavailable"),
    )

    result = clova_engine.extract_with_clova(b"image")

    assert result.ok is False
    assert result.status_code == 503
    assert result.error == "http_503:unavailable"


def test_clova_invalid_json_is_reported_clearly(monkeypatch):
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_API_URL", "https://ocr.test")
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_SECRET_KEY", "secret")
    monkeypatch.setattr(
        clova_engine.requests,
        "post",
        lambda *args, **kwargs: _ErrorResponse(
            status_code=200,
            payload=ValueError("invalid json"),
        ),
    )

    result = clova_engine.extract_with_clova(b"image")

    assert result.ok is False
    assert result.status_code == 200
    assert result.error == "invalid_json"


def test_clova_inference_failure_is_not_treated_as_success(monkeypatch):
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_API_URL", "https://ocr.test")
    monkeypatch.setattr(clova_engine, "CLOVA_OCR_SECRET_KEY", "secret")
    monkeypatch.setattr(
        clova_engine.requests,
        "post",
        lambda *args, **kwargs: _ErrorResponse(
            status_code=200,
            payload={
                "images": [
                    {"inferResult": "FAILURE", "message": "unsupported image"}
                ]
            },
        ),
    )

    result = clova_engine.extract_with_clova(b"image")

    assert result.ok is False
    assert result.status_code == 200
    assert result.error == "infer_FAILURE:unsupported image"
