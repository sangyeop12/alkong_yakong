import sqlite3

from app.models.schemas import DurAnalyzeRequest
from app.models.response_schemas import DurAnalyzeResponse
from app.services import dur_service, dur_sync_service
from app.services import external_api_service
from app.services.mfds_drug_permission import client as permission_client
from app.services.mfds_drug_permission import db as permission_db
from init_db import TABLE_DEFINITIONS


def _open_db(path):
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def _prepare_db(path):
    conn = _open_db(path)
    for table in ("users", "medicines", "dur_taboo", "user_medicines", "risk_results"):
        conn.execute(TABLE_DEFINITIONS[table])
    conn.execute(
        "INSERT INTO users (id, name, birth_date) VALUES ('patient-1', '환자', '1950-01-01')"
    )
    conn.execute(
        """
        INSERT INTO medicines (medicine_code, product_name, ingredient)
        VALUES ('MED-1', '테스트정', '테스트성분')
        """
    )
    conn.execute(
        "INSERT INTO user_medicines (user_id, medicine_code) VALUES ('patient-1', 'MED-1')"
    )
    conn.commit()
    conn.close()


def test_missing_live_dur_source_is_incomplete_not_safe(tmp_path, monkeypatch):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))
    monkeypatch.setattr(
        dur_sync_service,
        "refresh_dur_for_ingredients",
        lambda _names: {"status": "skipped_missing_key", "fetched": 0, "upserted": 0},
    )

    result = dur_service.analyze_dur(DurAnalyzeRequest(user_id="patient-1"))

    assert result["assessment_status"] == "INCOMPLETE"
    assert result["risk_level"] == "UNKNOWN"
    assert result["analysis_complete"] is False
    assert "병용금기" in result["incomplete_types"]
    api_payload = DurAnalyzeResponse.model_validate(result).model_dump()
    assert api_payload["assessment_status"] == "INCOMPLETE"
    assert api_payload["incomplete_types"]


def test_completed_live_dur_check_can_report_safe(tmp_path, monkeypatch):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))
    monkeypatch.setattr(
        dur_sync_service,
        "refresh_dur_for_ingredients",
        lambda _names: {"status": "ok", "fetched": 0, "upserted": 0},
    )

    result = dur_service.analyze_dur(DurAnalyzeRequest(user_id="patient-1"))

    assert result["assessment_status"] == "SAFE"
    assert result["risk_level"] == "LOW"
    assert result["analysis_complete"] is True
    assert result["incomplete_types"] == []


def test_explicit_two_medicine_scope_completes_with_zero_duplicate(tmp_path, monkeypatch):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    conn = _open_db(db_path)
    conn.execute(
        "INSERT INTO medicines (medicine_code, product_name, ingredient) "
        "VALUES ('MED-2', '다른약정', '다른성분')"
    )
    conn.commit()
    conn.close()
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))
    monkeypatch.setattr(
        dur_sync_service,
        "refresh_dur_for_ingredients",
        lambda _names: {"status": "ok", "fetched": 0, "upserted": 0},
    )

    result = dur_service.analyze_dur(
        DurAnalyzeRequest(
            user_id="patient-1",
            medicine_codes=["MED-1", "MED-2"],
        ),
        persist=False,
        refresh=True,
    )

    assert result["assessment_status"] == "SAFE"
    assert result["analysis_complete"] is True
    assert result["incomplete"] is False
    assert result["medicine_names"] == ["테스트정", "다른약정"]
    assert result["by_type"]["중복성분"]["count"] == 0


def test_explicit_two_medicine_scope_preserves_duplicate_warning(tmp_path, monkeypatch):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    conn = _open_db(db_path)
    conn.execute(
        "INSERT INTO medicines (medicine_code, product_name, ingredient) "
        "VALUES ('MED-2', '중복약정', '테스트성분')"
    )
    conn.commit()
    conn.close()
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))
    monkeypatch.setattr(
        dur_sync_service,
        "refresh_dur_for_ingredients",
        lambda _names: {"status": "ok", "fetched": 0, "upserted": 0},
    )

    result = dur_service.analyze_dur(
        DurAnalyzeRequest(
            user_id="patient-1",
            medicine_codes=["MED-1", "MED-2"],
        ),
        persist=False,
        refresh=True,
    )

    assert result["assessment_status"] == "RISK_FOUND"
    assert result["analysis_complete"] is True
    assert result["by_type"]["중복성분"]["count"] == 1


def test_skipped_request_sync_uses_existing_stored_dur_reference(tmp_path, monkeypatch):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    conn = _open_db(db_path)
    conn.execute(
        """
        INSERT INTO dur_taboo (
            ingredient_a, taboo_type, description, source
        ) VALUES ('저장기준성분', '병용금기', '저장된 식약처 기준', 'MFDS')
        """
    )
    conn.commit()
    conn.close()
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))

    result = dur_service.analyze_dur(
        DurAnalyzeRequest(user_id="patient-1"),
        persist=False,
        refresh=False,
    )

    assert result["dur_sync_status"] == "stored"
    assert result["assessment_status"] == "SAFE"
    assert result["analysis_complete"] is True
    assert result["incomplete"] is False


def test_skipped_request_sync_without_stored_dur_reference_is_incomplete(
    tmp_path, monkeypatch
):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))

    result = dur_service.analyze_dur(
        DurAnalyzeRequest(user_id="patient-1"),
        persist=False,
        refresh=False,
    )

    assert result["dur_sync_status"] == "skipped"
    assert result["assessment_status"] == "INCOMPLETE"
    assert result["analysis_complete"] is False
    assert result["incomplete"] is True
    assert any(
        "저장된 식약처 함께먹기 기준이 없어" in reason
        for reason in result["incomplete_reasons"]
    )


def test_no_registered_medicine_is_a_valid_incomplete_api_response(tmp_path, monkeypatch):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    conn = _open_db(db_path)
    conn.execute("DELETE FROM user_medicines")
    conn.commit()
    conn.close()
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))

    result = dur_service.analyze_dur(DurAnalyzeRequest(user_id="patient-1"))
    payload = DurAnalyzeResponse.model_validate(result).model_dump()

    assert payload["risk_result_id"] is None
    assert payload["analysis_id"] is None
    assert payload["assessment_status"] == "INCOMPLETE"


def test_explicit_official_code_is_cached_without_user_registration(
    tmp_path, monkeypatch
):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))
    monkeypatch.setattr(
        permission_db,
        "find_permission_product_by_item_seq",
        lambda code: {"item_seq": code} if code == "MED-2" else None,
    )
    monkeypatch.setattr(
        permission_db,
        "product_to_medicine",
        lambda _row: {
            "medicine_code": "MED-2",
            "product_name": "검색약정",
            "ingredient": "검색약성분",
        },
    )
    monkeypatch.setattr(
        external_api_service,
        "fetch_e_drug_info",
        lambda **_kwargs: None,
    )

    result = dur_service.analyze_dur(
        DurAnalyzeRequest(
            user_id="patient-1",
            medicine_codes=["MED-1", "MED-2"],
        ),
        persist=False,
        refresh=False,
    )

    assert result["medicine_names"] == ["테스트정", "검색약정"]
    conn = _open_db(db_path)
    try:
        assert conn.execute(
            "SELECT COUNT(*) FROM medicines WHERE medicine_code = 'MED-2'"
        ).fetchone()[0] == 1
        assert conn.execute(
            "SELECT COUNT(*) FROM user_medicines WHERE medicine_code = 'MED-2'"
        ).fetchone()[0] == 0
    finally:
        conn.close()


def test_explicit_official_name_is_used_for_exact_permission_lookup(
    tmp_path, monkeypatch
):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))
    monkeypatch.setattr(
        permission_db,
        "find_permission_product_by_item_seq",
        lambda _code: None,
    )
    permission_calls = []

    def fetch_permission_detail(**kwargs):
        permission_calls.append(kwargs)
        return {
            "ITEM_SEQ": "MED-2",
            "ITEM_NAME": "검색약정",
            "MAIN_ITEM_INGR": "검색약성분",
        }

    monkeypatch.setattr(
        permission_client,
        "fetch_permission_detail",
        fetch_permission_detail,
    )
    monkeypatch.setattr(
        external_api_service,
        "fetch_e_drug_info",
        lambda **_kwargs: None,
    )
    monkeypatch.setattr(
        dur_sync_service,
        "refresh_dur_for_ingredients",
        lambda _names: {"status": "ok", "fetched": 0, "upserted": 0},
    )

    result = dur_service.analyze_dur(
        DurAnalyzeRequest(
            user_id="patient-1",
            medicine_codes=["MED-1", "MED-2"],
            medicine_names_by_code={
                "MED-1": "테스트정",
                "MED-2": "검색약정",
            },
        ),
        persist=False,
        refresh=True,
    )

    assert permission_calls == [
        {"item_name": "검색약정", "item_seq": "MED-2"}
    ]
    assert result["medicine_names"] == ["테스트정", "검색약정"]
    assert result["assessment_status"] == "SAFE"
    assert result["analysis_complete"] is True
    assert result["by_type"]["중복성분"]["count"] == 0


def test_explicit_official_name_mismatch_is_not_cached(tmp_path, monkeypatch):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))
    monkeypatch.setattr(
        permission_db,
        "find_permission_product_by_item_seq",
        lambda _code: None,
    )
    monkeypatch.setattr(
        permission_client,
        "fetch_permission_detail",
        lambda **_kwargs: {
            "ITEM_SEQ": "MED-2",
            "ITEM_NAME": "다른약정",
            "MAIN_ITEM_INGR": "다른성분",
        },
    )
    monkeypatch.setattr(
        external_api_service,
        "fetch_e_drug_info",
        lambda **_kwargs: None,
    )

    result = dur_service.analyze_dur(
        DurAnalyzeRequest(
            user_id="patient-1",
            medicine_codes=["MED-2"],
            medicine_names_by_code={"MED-2": "검색약정"},
        ),
        persist=False,
        refresh=False,
    )

    assert result["assessment_status"] == "INCOMPLETE"
    assert result["medicine_names"] == []


def test_unverified_explicit_code_is_not_cached(tmp_path, monkeypatch):
    db_path = tmp_path / "dur.sqlite3"
    _prepare_db(db_path)
    monkeypatch.setattr(dur_service, "get_connection", lambda: _open_db(db_path))
    monkeypatch.setattr(
        permission_db,
        "find_permission_product_by_item_seq",
        lambda _code: {"item_seq": "OTHER"},
    )
    monkeypatch.setattr(
        permission_db,
        "product_to_medicine",
        lambda _row: {
            "medicine_code": "OTHER",
            "product_name": "다른약정",
            "ingredient": "다른성분",
        },
    )
    monkeypatch.setattr(
        permission_client,
        "fetch_permission_detail",
        lambda **_kwargs: None,
    )
    monkeypatch.setattr(
        external_api_service,
        "fetch_e_drug_info",
        lambda **_kwargs: None,
    )
    monkeypatch.setattr(
        dur_service,
        "_upsert_dur_catalog_medicine",
        lambda _medicine: (_ for _ in ()).throw(AssertionError("must not cache")),
    )

    result = dur_service.analyze_dur(
        DurAnalyzeRequest(user_id="patient-1", medicine_codes=["UNKNOWN"]),
        persist=False,
        refresh=False,
    )

    assert result["assessment_status"] == "INCOMPLETE"
    assert result["medicine_names"] == []
