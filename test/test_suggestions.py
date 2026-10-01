from app.services.pharmacist.easy_category_db import initialize_easy_category_map_db
from app.services.pharmacist import suggestions as suggestions_mod
from app.services.pharmacist.suggestions import get_chat_suggestions


def setup_module():
    initialize_easy_category_map_db(reset_seed=True)


def test_empty_query_returns_faq_chips():
    items = get_chat_suggestions("")
    labels = [item["label"] for item in items]
    assert "이 약 설명" in labels


def test_ty_prefix_returns_tylenol_related(monkeypatch):
    monkeypatch.setattr(
        suggestions_mod,
        "_official_names",
        lambda query: ["타이레놀정500밀리그램", "타이레놀8시간이알서방정"],
    )
    items = get_chat_suggestions("타이")
    labels = [item["label"] for item in items]
    assert "타이레놀정500밀리그램" in labels


def test_diarrhea_everyday_links(monkeypatch):
    monkeypatch.setattr(
        suggestions_mod,
        "_official_names",
        lambda query: ["스멕타현탁액"] if "스멕타" in query else [],
    )
    items = get_chat_suggestions("설사")
    labels = [item["label"] for item in items]
    types = {item["label"]: item["type"] for item in items}
    assert "배아픔" in labels
    assert types.get("배아픔") == "phrase"
    assert "스멕타현탁액" in labels or any("스멕타" in label for label in labels)


def test_cold_everyday_links(monkeypatch):
    monkeypatch.setattr(
        suggestions_mod,
        "_official_names",
        lambda query: ["타이레놀콜드-에스정"] if "타이레놀" in query else [],
    )
    items = get_chat_suggestions("감기")
    labels = [item["label"] for item in items]
    assert "콧물" in labels
    assert "기침" in labels


def test_senior_forgot_dose_faq():
    items = get_chat_suggestions("깜빡")
    labels = [item["label"] for item in items]
    assert "안 먹었을 때" in labels


def test_chosung_tylenol(monkeypatch):
    monkeypatch.setattr(
        suggestions_mod,
        "_official_names",
        lambda query: ["타이레놀정500밀리그램"]
        if query.replace(" ", "") in {"ㅌㄹㄴ", "ㅌㅇㄹㄴ", "타이레놀"}
        else [],
    )
    items = get_chat_suggestions("ㅌㄹㄴ")
    labels = [item["label"] for item in items]
    assert "타이레놀정500밀리그램" in labels
