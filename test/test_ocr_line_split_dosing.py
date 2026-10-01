from pathlib import Path

from app.services.ocr.parser import parse_prescription_text


LINE_SPLIT_ENVELOPE = """
약품명및용량
1회
투약량
1일
투여횟수
투약
일수
프리마란정
(알러지질환약)
0.50
3
7
알러지유발
물질의
작용을
차단하여
알러지
증상을
개선하는
약
0.50
3
아디팜정
(항히스타민제/피부소
알러지
증상을
완화시키고
7
7
휴온스시메티딘정200밀리그램
위산
분비를
억제하는
약
0.50
3
7
프레벨액0.25%
(피부질환약
1.00
1
1
"""


def test_line_split_envelope_reads_frequency_and_days():
    result = parse_prescription_text(LINE_SPLIT_ENVELOPE)
    assert result is not None
    by_name = {item["drug_name"]: item for item in result["items"]}

    prema = by_name["프리마란정"]
    assert prema.get("dosage") == "0.50"
    assert prema.get("frequency_per_day") == 3
    assert prema.get("duration_days") == 7

    adipam = by_name["아디팜정"]
    assert adipam.get("dosage") == "0.50"
    assert adipam.get("frequency_per_day") == 3
    assert adipam.get("duration_days") == 7

    prebel = next(item for name, item in by_name.items() if "프레벨" in name)
    assert prebel.get("dosage") == "1.00"
    assert prebel.get("frequency_per_day") == 1


def test_real_clova_dump_reads_frequency_when_present():
    path = Path(__file__).resolve().parent.parent / "20260825_164345_clova.txt"
    if not path.exists():
        return
    result = parse_prescription_text(path.read_text(encoding="utf-8"))
    assert result is not None
    by_name = {item["drug_name"]: item for item in result["items"]}
    assert by_name["프리마란정"].get("frequency_per_day") == 3
    assert by_name["아디팜정"].get("frequency_per_day") == 3


def test_split_table_headers_still_bind_frequency():
    table = {
        "cells": [
            {
                "rowIndex": 0,
                "columnIndex": 0,
                "cellTextLines": [{"cellWords": [{"inferText": "약품명"}]}],
            },
            {
                "rowIndex": 0,
                "columnIndex": 1,
                "cellTextLines": [{"cellWords": [{"inferText": "투약량"}]}],
            },
            {
                "rowIndex": 0,
                "columnIndex": 2,
                "cellTextLines": [{"cellWords": [{"inferText": "투여횟수"}]}],
            },
            {
                "rowIndex": 0,
                "columnIndex": 3,
                "cellTextLines": [{"cellWords": [{"inferText": "일수"}]}],
            },
            {
                "rowIndex": 1,
                "columnIndex": 0,
                "cellTextLines": [{"cellWords": [{"inferText": "아디팜정"}]}],
            },
            {
                "rowIndex": 1,
                "columnIndex": 1,
                "cellTextLines": [{"cellWords": [{"inferText": "0.50"}]}],
            },
            {
                "rowIndex": 1,
                "columnIndex": 2,
                "cellTextLines": [{"cellWords": [{"inferText": "3"}]}],
            },
            {
                "rowIndex": 1,
                "columnIndex": 3,
                "cellTextLines": [{"cellWords": [{"inferText": "7"}]}],
            },
        ]
    }
    result = parse_prescription_text("아디팜정 0.50 3 7", tables=(table,))
    assert result is not None
    item = next(row for row in result["items"] if "아디팜" in row["drug_name"])
    assert item.get("frequency_per_day") == 3
    assert item.get("duration_days") == 7


def test_header_one_does_not_count_as_read_frequency_or_days():
    from app.services.ocr.parser import _number_in_source

    header = "1회\n투약량\n1일\n투여횟수\n투약\n일수\n아디팜정\n0.50\n3\n7\n"
    assert _number_in_source("frequency_per_day", 1, header) is False
    assert _number_in_source("duration_days", 1, header) is False
    assert _number_in_source("frequency_per_day", 3, header) is True
    assert _number_in_source("duration_days", 7, header) is True
