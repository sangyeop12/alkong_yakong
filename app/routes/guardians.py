import uuid

from fastapi import APIRouter, HTTPException, Response

from app.database import get_connection
from app.models.schemas import GuardianCreate, GuardianLinkRequest, GuardianStatusUpdate
from app.models.response_schemas import GuardianCreateResponse, GuardianResponse
from app.services.account_lookup import find_account_by_phone, phone_digits
from app.services.care_service import get_care_overview


router = APIRouter(prefix="/api/v1/guardians", tags=["Guardians"])


def _load_link(conn, guardian_id: str):
    row = conn.execute("SELECT * FROM guardians WHERE id = ?", (guardian_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="연결을 찾지 못했어요.")
    return row


@router.post("", response_model=GuardianCreateResponse)
def create_guardian(guardian: GuardianCreate):
    """어르신이 가족을 등록한다. 어르신 본인이 넣은 것이라 바로 연결된다."""
    conn = get_connection()
    try:
        if not conn.execute(
            "SELECT 1 FROM users WHERE id = ?", (guardian.user_id,)
        ).fetchone():
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")
        account = find_account_by_phone(
            conn, guardian.phone, exclude_id=guardian.user_id
        )
        guardian_id = str(uuid.uuid4())
        conn.execute(
            """
            INSERT INTO guardians (
                id, user_id, guardian_name, relationship, phone,
                fcm_token, notification_enabled, guardian_user_id,
                status, requested_by
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ACCEPTED', 'PATIENT')
            """,
            (
                guardian_id,
                guardian.user_id,
                guardian.guardian_name,
                guardian.relationship,
                guardian.phone,
                guardian.fcm_token,
                int(guardian.notification_enabled),
                account["id"] if account else None,
            ),
        )
        conn.commit()
        return dict(_load_link(conn, guardian_id))
    finally:
        conn.close()


@router.get("/users/{user_id}", response_model=list[GuardianResponse])
def get_user_guardians(user_id: str):
    conn = get_connection()
    try:
        rows = conn.execute(
            "SELECT * FROM guardians WHERE user_id = ? ORDER BY created_at",
            (user_id,),
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


@router.post("/link-requests")
def request_link(request: GuardianLinkRequest):
    """보호자가 어르신 번호로 함께 보기를 요청한다. 어르신이 수락해야 열린다."""
    conn = get_connection()
    try:
        guardian = conn.execute(
            "SELECT * FROM users WHERE id = ?", (request.guardian_user_id,)
        ).fetchone()
        if not guardian:
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")
        patient = find_account_by_phone(
            conn, request.patient_phone, exclude_id=guardian["id"]
        )
        if patient is None:
            raise HTTPException(
                status_code=404,
                detail="그 번호로 가입한 어르신이 없어요. 번호를 다시 확인해 주세요.",
            )
        digits = phone_digits(guardian["phone"])
        for row in conn.execute(
            "SELECT * FROM guardians WHERE user_id = ?", (patient["id"],)
        ):
            same_guardian = row["guardian_user_id"] == guardian["id"] or (
                digits and phone_digits(row["phone"]) == digits
            )
            if same_guardian:
                pending = str(row["status"] or "").upper() == "PENDING"
                raise HTTPException(
                    status_code=409,
                    detail="이미 연결을 요청했어요." if pending else "이미 연결된 분이에요.",
                )

        link_id = str(uuid.uuid4())
        relation = (request.patient_relation or "").strip() or None
        conn.execute(
            """
            INSERT INTO guardians (
                id, user_id, guardian_name, phone, guardian_user_id,
                patient_relation, status, requested_by
            ) VALUES (?, ?, ?, ?, ?, ?, 'PENDING', 'GUARDIAN')
            """,
            (
                link_id,
                patient["id"],
                guardian["name"],
                guardian["phone"],
                guardian["id"],
                relation,
            ),
        )
        conn.commit()
        return {
            "id": link_id,
            "patient_name": patient["name"],
            "patient_phone": patient["phone"],
            "patient_relation": relation,
            "status": "PENDING",
        }
    finally:
        conn.close()


@router.patch("/{guardian_id}", response_model=GuardianResponse)
def update_link_status(guardian_id: str, update: GuardianStatusUpdate):
    """어르신이 보호자의 요청을 수락한다."""
    if update.status.upper() != "ACCEPTED":
        raise HTTPException(status_code=422, detail="수락만 할 수 있어요. 거절은 삭제로 합니다.")
    conn = get_connection()
    try:
        _load_link(conn, guardian_id)
        conn.execute(
            "UPDATE guardians SET status = 'ACCEPTED' WHERE id = ?", (guardian_id,)
        )
        conn.commit()
        return dict(_load_link(conn, guardian_id))
    finally:
        conn.close()


@router.delete("/{guardian_id}", status_code=204)
def delete_link(guardian_id: str):
    """연결 해제 · 요청 취소 · 요청 거절이 모두 이것이다."""
    conn = get_connection()
    try:
        _load_link(conn, guardian_id)
        conn.execute("DELETE FROM guardians WHERE id = ?", (guardian_id,))
        conn.commit()
        return Response(status_code=204)
    finally:
        conn.close()


@router.get("/accounts/{guardian_user_id}/patients")
def care_overview(guardian_user_id: str):
    """보호자가 돌보는 어르신들의 오늘 현황과 수락을 기다리는 요청."""
    return get_care_overview(guardian_user_id)
