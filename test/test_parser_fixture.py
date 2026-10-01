from pathlib import Path

from app.services.ocr.parser import filter_to_source, parse_prescription_text


FIXTURE = (
    Path(__file__).resolve().parent / "fixtures" / "prescription_raw.txt"
).read_text(encoding="utf-8")


def test_parser_skips_blank_text():
    assert parse_prescription_text("") is None
    assert parse_prescription_text("  ") is None


def test_fixture_keeps_only_names_in_raw_text():
    parsed = {
        "hospital_name": "중앙성모의원",
        "items": [
            {
                "drug_name": "모사피아정",
                "frequency_per_day": 2,
                "duration_days": 5,
            },
            {
                "drug_name": "프로맥정",
                "frequency_per_day": 2,
                "duration_days": 5,
            },
            {
                "drug_name": "니자액스캡슐150mg",
                "frequency_per_day": 2,
                "duration_days": 5,
            },
            {"drug_name": "타이레놀정", "duration_days": 7},
        ],
    }
    result = filter_to_source(parsed, FIXTURE)
    names = [item["drug_name"] for item in result["items"]]
    assert names == ["모사피아정", "프로맥정", "니자액스캡슐150mg"]
    assert "타이레놀정" in result["discarded_names"]


def test_fixture_drops_invented_duration_days():
    parsed = {
        "items": [
            {"drug_name": "프로맥정", "duration_days": 14},
            {"drug_name": "모사피아정", "duration_days": 5},
        ]
    }
    result = filter_to_source(parsed, FIXTURE)
    by_name = {item["drug_name"]: item for item in result["items"]}
    assert "duration_days" not in by_name["프로맥정"]
    assert by_name["모사피아정"]["duration_days"] == 5


def test_fixture_does_not_treat_date_digits_as_frequency():
    parsed = {
        "items": [
            {"drug_name": "모사피아정", "frequency_per_day": 3},
        ]
    }
    result = filter_to_source(parsed, FIXTURE)
    assert "frequency_per_day" not in result["items"][0]
