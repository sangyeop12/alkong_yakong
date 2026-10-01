from app.models.schemas import OCRMedicineItem
from app.services.ocr.parser import correct_drug_names
from app.services.prescription_service import _resolve_medicine


def test_corrects_glued_dosing_without_renaming_to_official():
    result = correct_drug_names({"items": [{"drug_name": "프리마라정1정2회7일"}]})
    assert result["items"][0]["drug_name"] == "프리마라정"
    assert result["items"][0]["frequency_per_day"] == 2
    assert result["items"][0]["duration_days"] == 7
    assert result["items"][0]["times_per_take"] == 1


def test_resolve_skips_unmatched_names(monkeypatch):
    class _Cursor:
        def execute(self, *_args, **_kwargs):
            return self

        def fetchone(self):
            return None

        def fetchall(self):
            return []

    monkeypatch.setattr(
        "app.services.prescription_service.retrieve_official",
        lambda *_args, **_kwargs: None,
    )
    item = OCRMedicineItem(drug_name="없는약이름정")
    assert _resolve_medicine(_Cursor(), item) is None
