from datetime import datetime
from uuid import uuid4

from fastapi import HTTPException

from app.database import get_connection
from app.models.biosignal_test_schemas import (
    BiosignalTestSampleCreate,
    BiosignalTestSessionStart,
)


def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def start_session(request: BiosignalTestSessionStart) -> dict:
    conn = get_connection()
    try:
        if not request.is_synthetic:
            active = conn.execute(
                """
                SELECT id FROM biosignal_test_sessions
                WHERE ended_at IS NULL AND is_synthetic = 0
                """
            ).fetchone()
            if active:
                raise HTTPException(
                    status_code=409,
                    detail="An active Polar dataset session already exists.",
                )

        session_id = str(uuid4())
        started_at = _now()
        conn.execute(
            """
            INSERT INTO biosignal_test_sessions (
                id, participant_id, scenario, started_at, is_synthetic, note
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                session_id,
                request.participant_id,
                request.scenario,
                started_at,
                int(request.is_synthetic),
                request.note,
            ),
        )
        conn.commit()
        return {
            "session_id": session_id,
            "participant_id": request.participant_id,
            "scenario": request.scenario,
            "started_at": started_at,
            "is_synthetic": request.is_synthetic,
        }
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def stop_session(session_id: str) -> dict:
    conn = get_connection()
    try:
        session = conn.execute(
            "SELECT * FROM biosignal_test_sessions WHERE id = ?", (session_id,)
        ).fetchone()
        if not session:
            raise HTTPException(status_code=404, detail="Dataset session not found.")
        if session["ended_at"] is not None:
            raise HTTPException(status_code=409, detail="Dataset session already stopped.")

        ended_at = _now()
        conn.execute(
            "UPDATE biosignal_test_sessions SET ended_at = ? WHERE id = ?",
            (ended_at, session_id),
        )
        conn.commit()
        result = dict(session)
        result["session_id"] = result.pop("id")
        result["ended_at"] = ended_at
        result["is_synthetic"] = bool(result["is_synthetic"])
        return result
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def list_sessions(
    participant_id: str | None,
    scenario: str | None,
    is_synthetic: bool | None,
) -> list[dict]:
    clauses: list[str] = []
    parameters: list[object] = []
    if participant_id is not None:
        clauses.append("participant_id = ?")
        parameters.append(participant_id)
    if scenario is not None:
        clauses.append("scenario = ?")
        parameters.append(scenario)
    if is_synthetic is not None:
        clauses.append("is_synthetic = ?")
        parameters.append(int(is_synthetic))
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""

    conn = get_connection()
    try:
        rows = conn.execute(
            f"""
            SELECT * FROM biosignal_test_sessions
            {where}
            ORDER BY started_at DESC, id DESC
            """,
            parameters,
        ).fetchall()
        results = []
        for row in rows:
            item = dict(row)
            item["session_id"] = item.pop("id")
            item["is_synthetic"] = bool(item["is_synthetic"])
            results.append(item)
        return results
    finally:
        conn.close()


def get_active_polar_session() -> dict | None:
    conn = get_connection()
    try:
        row = conn.execute(
            """
            SELECT * FROM biosignal_test_sessions
            WHERE ended_at IS NULL AND is_synthetic = 0
            ORDER BY started_at DESC LIMIT 1
            """
        ).fetchone()
        if row is None:
            return None
        result = dict(row)
        result["session_id"] = result.pop("id")
        result["is_synthetic"] = False
        return result
    finally:
        conn.close()


def save_sample(request: BiosignalTestSampleCreate) -> dict:
    conn = get_connection()
    try:
        session = conn.execute(
            "SELECT * FROM biosignal_test_sessions WHERE id = ?",
            (request.session_id,),
        ).fetchone()
        if not session:
            raise HTTPException(status_code=404, detail="Dataset session not found.")
        if session["ended_at"] is not None:
            raise HTTPException(status_code=409, detail="Dataset session is not active.")

        session_is_synthetic = bool(session["is_synthetic"])
        expected_source = "SYNTHETIC_TEST" if session_is_synthetic else "POLAR_DATASET_5S"
        if request.is_synthetic != session_is_synthetic or request.source != expected_source:
            raise HTTPException(
                status_code=400,
                detail="Sample source and synthetic flag must match the session type.",
            )

        measured_at = request.measured_at or _now()
        cursor = conn.execute(
            """
            INSERT INTO biosignal_test_samples (
                session_id, bpm, measured_at, device_id, source, is_synthetic
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                request.session_id,
                request.bpm,
                measured_at,
                request.device_id,
                request.source,
                int(request.is_synthetic),
            ),
        )
        conn.commit()
        return {
            "sample_id": cursor.lastrowid,
            "session_id": request.session_id,
            "participant_id": session["participant_id"],
            "scenario": session["scenario"],
            "bpm": request.bpm,
            "measured_at": measured_at,
            "device_id": request.device_id,
            "source": request.source,
            "is_synthetic": request.is_synthetic,
        }
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def list_samples(session_id: str) -> list[dict]:
    conn = get_connection()
    try:
        session = conn.execute(
            "SELECT participant_id, scenario FROM biosignal_test_sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
        if not session:
            raise HTTPException(status_code=404, detail="Dataset session not found.")
        rows = conn.execute(
            """
            SELECT * FROM biosignal_test_samples
            WHERE session_id = ? ORDER BY measured_at, id
            """,
            (session_id,),
        ).fetchall()
        return [
            {
                **dict(row),
                "participant_id": session["participant_id"],
                "scenario": session["scenario"],
                "is_synthetic": bool(row["is_synthetic"]),
            }
            for row in rows
        ]
    finally:
        conn.close()
