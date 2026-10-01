import sqlite3

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import app.database as database
from app.routes import guardians, users
from init_db import TABLE_DEFINITIONS


@pytest.fixture
def client(tmp_path, monkeypatch):
    db_path = tmp_path / "care.db"
    conn = sqlite3.connect(db_path)
    for definition in TABLE_DEFINITIONS.values():
        conn.execute(definition)
    conn.commit()
    conn.close()
    monkeypatch.setattr(database, "DB_PATH", str(db_path))
    api = FastAPI()
    api.include_router(users.router)
    api.include_router(guardians.router)
    return TestClient(api)


def _signup(client, name, phone, role):
    response = client.post(
        "/api/v1/users",
        json={"name": name, "phone": phone, "password": "abc123", "role": role},
    )
    assert response.status_code == 200
    return response.json()


def _overview(client, guardian_id):
    response = client.get(f"/api/v1/guardians/accounts/{guardian_id}/patients")
    assert response.status_code == 200
    return response.json()


def test_patient_invite_links_guardian_who_signs_up_later(client):
    patient = _signup(client, "김복자", "010-1111-2222", "patient")
    invited = client.post(
        "/api/v1/guardians",
        json={
            "user_id": patient["id"],
            "guardian_name": "김지안",
            "relationship": "딸",
            "phone": "010-3333-4444",
        },
    )
    assert invited.status_code == 200
    assert invited.json()["status"] == "ACCEPTED"

    guardian = _signup(client, "김지안", "01033334444", "guardian")
    overview = _overview(client, guardian["id"])
    assert overview["pending"] == []
    [summary] = overview["patients"]
    assert summary["name"] == "김복자"
    assert summary["patient_id"] == patient["id"]
    assert summary["total_count"] == 0
    assert summary["heart_rate"] is None
    assert summary["week_rate"] is None


def test_guardian_request_waits_for_patient_acceptance(client):
    patient = _signup(client, "김복자", "010-1111-2222", "patient")
    guardian = _signup(client, "김지안", "010-3333-4444", "guardian")

    requested = client.post(
        "/api/v1/guardians/link-requests",
        json={
            "guardian_user_id": guardian["id"],
            "patient_phone": "01011112222",
            "patient_relation": "어머니",
        },
    )
    assert requested.status_code == 200
    link_id = requested.json()["id"]

    # 수락 전에는 현황이 열리지 않는다.
    overview = _overview(client, guardian["id"])
    assert overview["patients"] == []
    assert overview["pending"][0]["patient_name"] == "김복자"

    contacts = client.get(f"/api/v1/guardians/users/{patient['id']}").json()
    assert contacts[0]["status"] == "PENDING"
    assert contacts[0]["requested_by"] == "GUARDIAN"

    assert client.patch(
        f"/api/v1/guardians/{link_id}", json={"status": "ACCEPTED"}
    ).status_code == 200
    overview = _overview(client, guardian["id"])
    assert overview["pending"] == []
    assert overview["patients"][0]["relation"] == "어머니"

    duplicate = client.post(
        "/api/v1/guardians/link-requests",
        json={"guardian_user_id": guardian["id"], "patient_phone": "010-1111-2222"},
    )
    assert duplicate.status_code == 409


def test_request_to_unknown_phone_is_rejected(client):
    guardian = _signup(client, "김지안", "010-3333-4444", "guardian")
    response = client.post(
        "/api/v1/guardians/link-requests",
        json={"guardian_user_id": guardian["id"], "patient_phone": "010-9999-9999"},
    )
    assert response.status_code == 404


def test_unlink_removes_patient_from_overview(client):
    patient = _signup(client, "김복자", "010-1111-2222", "patient")
    guardian = _signup(client, "김지안", "010-3333-4444", "guardian")
    link_id = client.post(
        "/api/v1/guardians/link-requests",
        json={"guardian_user_id": guardian["id"], "patient_phone": patient["phone"]},
    ).json()["id"]
    client.patch(f"/api/v1/guardians/{link_id}", json={"status": "ACCEPTED"})

    assert client.delete(f"/api/v1/guardians/{link_id}").status_code == 204
    assert _overview(client, guardian["id"])["patients"] == []
