from app.services.pharmacist.retrieve import retrieve_official


def test_retrieve_uses_local_permission_only(monkeypatch):
    order: list[str] = []

    monkeypatch.setattr(
        "app.services.pharmacist.retrieve._find_permission_local",
        lambda name, dosage_hint=None: order.append("local")
        or {
            "source": "식약처 의약품 제품 허가정보",
            "medicine": {"product_name": name},
            "source_text": "product_name: x",
        },
    )
    monkeypatch.setattr(
        "app.services.pharmacist.retrieve._find_permission_live",
        lambda name, dosage_hint=None: order.append("live") or None,
    )

    result = retrieve_official("게보린정")
    assert order == ["local"]
    assert result["source"] == "식약처 의약품 제품 허가정보"


def test_retrieve_falls_back_to_live_when_local_misses(monkeypatch):
    order: list[str] = []

    monkeypatch.setattr(
        "app.services.pharmacist.retrieve._find_permission_local",
        lambda name, dosage_hint=None: order.append("local") or None,
    )
    monkeypatch.setattr(
        "app.services.pharmacist.retrieve._find_permission_live",
        lambda name, dosage_hint=None: order.append("live") or None,
    )

    assert retrieve_official("없는약정") is None
    assert order == ["local", "live"]


def test_refresh_query_adds_salt_variant():
    from app.services.pharmacist.retrieve import _refresh_query_variants

    variants = _refresh_query_variants("메트포르민정500밀리그램")
    assert variants[0] == "메트포르민정500밀리그램"
    assert "메트포르민염산염정500밀리그램" in variants


def test_hydrate_fetches_detail_when_efficacy_empty(monkeypatch):
    from app.services.pharmacist.retrieve import _hydrate_permission_detail

    called: dict[str, tuple[str, str]] = {}

    monkeypatch.setattr(
        "app.services.pharmacist.retrieve.ensure_detail_for_product",
        lambda seq, name: called.setdefault("args", (seq, name)) or True,
    )
    monkeypatch.setattr(
        "app.services.pharmacist.retrieve.find_permission_product",
        lambda name: {"item_name": name, "efficacy_text": "1. 고혈압"},
    )
    row = _hydrate_permission_detail(
        {"item_seq": "199601234", "item_name": "암로디핀정", "efficacy_text": ""}
    )
    assert called["args"] == ("199601234", "암로디핀정")
    assert row["efficacy_text"] == "1. 고혈압"
