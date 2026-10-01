import hashlib
import hmac
import json
import logging
import os
import sqlite3
import uuid

from fastapi import APIRouter, Header, HTTPException, Query, Response

import app.database as database
from app.database import get_connection
from app.models.schemas import UserCreate, UserLogin, UserUpdate
from app.models.response_schemas import UserCreateResponse, UserResponse
from app.services.account_lookup import find_account_by_phone, phone_digits
from app.services.medication_history_service import get_medication_history
from app.services.user_medicines_service import get_user_medicine, get_user_medicines


router = APIRouter(prefix="/api/v1/users", tags=["Users"])
logger = logging.getLogger(__name__)

_PASSWORD_ITERATIONS = 200_000
_MIN_PASSWORD_LENGTH = 6

# 내 정보 화면에서 고칠 수 있는 칸.
_PROFILE_COLUMNS = (
    "name",
    "birth_date",
    "gender",
    "phone",
    "height_cm",
    "weight_kg",
    "blood_type",
    "smoking",
    "drinking",
    "allergies",
    "diseases",
    "past_history",
    "family_history",
    "past_illnesses",
    "family_illnesses",
)
_HISTORY_LIST_COLUMNS = ("past_illnesses", "family_illnesses")
_LIST_COLUMNS = ("allergies", "diseases", *_HISTORY_LIST_COLUMNS)
_FLAG_COLUMNS = ("past_history", "family_history")


def _hash_password(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, _PASSWORD_ITERATIONS
    )
    return f"pbkdf2_sha256${_PASSWORD_ITERATIONS}${salt.hex()}${digest.hex()}"


def _verify_password(password: str, stored: str | None) -> bool:
    try:
        algorithm, iterations, salt_hex, digest_hex = (stored or "").split("$")
        digest = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            bytes.fromhex(salt_hex),
            int(iterations),
        )
    except ValueError:
        return False
    return algorithm == "pbkdf2_sha256" and hmac.compare_digest(
        digest.hex(), digest_hex
    )


def _pregnancy_flag(
    is_pregnant: bool | None, pregnancy_status: str | None
) -> tuple[int, str | None]:
    status = (pregnancy_status or "").strip() or None
    if is_pregnant is True:
        return 1, status or "임신 중"
    if is_pregnant is False:
        return 0, status
    if status == "임신 중":
        return 1, status
    return 0, status


def _db_value(column: str, value):
    if column in _LIST_COLUMNS:
        items = [str(item).strip() for item in (value or [])]
        if column in _HISTORY_LIST_COLUMNS:
            items = [item for item in items if item != "없어요"]
        return json.dumps([item for item in items if item], ensure_ascii=False)
    if column in _FLAG_COLUMNS:
        return None if value is None else int(bool(value))
    if isinstance(value, str):
        return value.strip() or None
    return value


def _json_list(raw) -> list[str]:
    try:
        value = json.loads(raw or "[]")
    except (TypeError, ValueError):
        return []
    if not isinstance(value, list):
        return []
    return [str(item) for item in value if str(item).strip()]


def _user_payload(row) -> dict:
    """비밀번호 해시는 절대 내보내지 않는다."""
    data = dict(row)
    data.pop("password_hash", None)
    data["is_pregnant"] = bool(data.get("is_pregnant"))
    for column in _LIST_COLUMNS:
        data[column] = _json_list(data.get(column))
    for column in _FLAG_COLUMNS:
        if data.get(column) is not None:
            data[column] = bool(data[column])
    return data


def _load_user(conn: sqlite3.Connection, user_id: str):
    row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="사용자가 없습니다.")
    return row


def _validate_history_lists(values: dict) -> None:
    for column in _HISTORY_LIST_COLUMNS:
        items = [str(item).strip() for item in (values.get(column) or [])]
        if "없어요" in items and any(item and item != "없어요" for item in items):
            raise HTTPException(
                status_code=400,
                detail='병명과 "없어요"를 함께 선택할 수 없어요.',
            )


@router.post("", response_model=UserCreateResponse)
def create_user(user: UserCreate):
    if not user.name.strip():
        raise HTTPException(status_code=400, detail="이름을 입력해주세요.")
    password = user.password or ""
    if password and len(password) < _MIN_PASSWORD_LENGTH:
        raise HTTPException(status_code=400, detail="비밀번호는 6자 이상이어야 해요.")
    _validate_history_lists(user.model_dump())
    conn = get_connection()
    try:
        if password and find_account_by_phone(conn, user.phone):
            raise HTTPException(status_code=409, detail="이미 가입된 휴대폰 번호예요.")
        is_pregnant, pregnancy_status = _pregnancy_flag(
            user.is_pregnant, user.pregnancy_status
        )
        values = {
            column: _db_value(column, getattr(user, column))
            for column in _PROFILE_COLUMNS
        }
        values.update(
            id=str(uuid.uuid4()),
            role=user.role,
            is_pregnant=is_pregnant,
            pregnancy_status=pregnancy_status,
            password_hash=_hash_password(password) if password else None,
        )
        columns = ", ".join(values)
        placeholders = ", ".join("?" for _ in values)
        conn.execute(
            f"INSERT INTO users ({columns}) VALUES ({placeholders})",
            tuple(values.values()),
        )
        conn.commit()
        return _user_payload(_load_user(conn, values["id"]))
    finally:
        conn.close()


@router.post("/login", response_model=UserResponse)
def login(credentials: UserLogin):
    conn = get_connection()
    try:
        phone_matches = 0
        hash_accounts = 0
        digits = phone_digits(credentials.phone)
        if digits:
            try:
                for candidate in conn.execute(
                    "SELECT phone, password_hash FROM users"
                ):
                    if phone_digits(candidate["phone"]) != digits:
                        continue
                    phone_matches += 1
                    if candidate["password_hash"] is not None:
                        hash_accounts += 1
            except sqlite3.Error:
                logger.warning(
                    "LOGIN_DIAG account_count_unavailable exception_type=%s",
                    "SQLiteError",
                )

        row = find_account_by_phone(conn, credentials.phone)
        password_ok = row is not None and _verify_password(
            credentials.password, row["password_hash"]
        )
        logger.warning(
            "LOGIN_DIAG pid=%s db_path=%s phone_matches=%s hash_accounts=%s "
            "selected=%s password_ok=%s",
            os.getpid(),
            database.DB_PATH,
            phone_matches,
            hash_accounts,
            row is not None,
            password_ok,
        )
        if not password_ok:
            raise HTTPException(
                status_code=401, detail="휴대폰 번호나 비밀번호가 맞지 않아요."
            )
        return _user_payload(row)
    finally:
        conn.close()


# 회원 전체 목록의 열쇠를 담아 두는 환경변수 이름.
_ADMIN_KEY_ENV = "ALKONGYAKONG_ADMIN_KEY"


def _require_admin(key: str | None) -> None:
    """회원 전체 목록은 이름·번호·생년월일이 한 번에 나온다.

    앱은 이 길을 쓰지 않는다. 운영자가 열쇠를 정해 두고 그 값을 보낼 때만
    답한다. 열쇠를 정하지 않은 서버에서는 길 자체가 없는 것으로 둔다.
    """
    configured = os.getenv(_ADMIN_KEY_ENV, "").strip()
    if not configured:
        raise HTTPException(status_code=404, detail="Not Found")
    if not hmac.compare_digest(key or "", configured):
        raise HTTPException(status_code=403, detail="관리자 열쇠가 필요해요.")


@router.get("", response_model=list[UserResponse])
def get_users(x_admin_key: str | None = Header(default=None)):
    _require_admin(x_admin_key)
    conn = get_connection()
    try:
        return [
            _user_payload(row)
            for row in conn.execute(
                "SELECT * FROM users ORDER BY created_at DESC"
            ).fetchall()
        ]
    finally:
        conn.close()


@router.get("/{user_id}/medicines")
def user_medicines(user_id: str):
    """현재·과거 내 약 보관 목록 (약 종류당 1행). 오늘 차는 /today-medicines."""
    return get_user_medicines(user_id)


@router.get("/{user_id}/medicines/{medicine_code}")
def user_medicine_detail(user_id: str, medicine_code: str):
    """내 약 한 종류 상세 (쉬운말·주의 포함)."""
    return get_user_medicine(user_id, medicine_code)


@router.get("/{user_id}/medication-history")
def user_medication_history(
    user_id: str,
    start: str = Query(..., description="YYYY-MM-DD"),
    end: str = Query(..., description="YYYY-MM-DD"),
):
    """날짜별로 몇 번 중 몇 번 드셨는지. 기록 탭과 달력이 같이 쓴다."""
    return get_medication_history(user_id, start, end)


@router.get("/{user_id}", response_model=UserResponse)
def get_user(user_id: str):
    conn = get_connection()
    try:
        return _user_payload(_load_user(conn, user_id))
    finally:
        conn.close()


@router.patch("/{user_id}", response_model=UserResponse)
def update_user(user_id: str, changes: UserUpdate):
    fields = changes.model_dump(exclude_unset=True)
    _validate_history_lists(fields)
    conn = get_connection()
    try:
        row = _load_user(conn, user_id)
        if "name" in fields and not (fields["name"] or "").strip():
            raise HTTPException(status_code=400, detail="이름을 입력해주세요.")
        if (
            "phone" in fields
            and row["password_hash"]
            and find_account_by_phone(conn, fields["phone"], exclude_id=user_id)
        ):
            raise HTTPException(status_code=409, detail="이미 가입된 휴대폰 번호예요.")

        updates = {
            column: _db_value(column, fields[column])
            for column in _PROFILE_COLUMNS
            if column in fields
        }
        if "is_pregnant" in fields or "pregnancy_status" in fields:
            is_pregnant, pregnancy_status = _pregnancy_flag(
                fields.get("is_pregnant"), fields.get("pregnancy_status")
            )
            updates["is_pregnant"] = is_pregnant
            updates["pregnancy_status"] = pregnancy_status
        if updates:
            assignments = ", ".join(f"{column} = ?" for column in updates)
            conn.execute(
                f"UPDATE users SET {assignments}, updated_at = CURRENT_TIMESTAMP "
                "WHERE id = ?",
                (*updates.values(), user_id),
            )
            conn.commit()
        return _user_payload(_load_user(conn, user_id))
    finally:
        conn.close()


@router.delete("/{user_id}", status_code=204)
def delete_user(user_id: str):
    """탈퇴. 약·기록·보호자 연락처는 외래키로 함께 지워진다."""
    conn = get_connection()
    try:
        _load_user(conn, user_id)
        try:
            # 이 사람이 보호자로서 보낸 대기 요청은 지우고, 수락된 연결은
            # 계정 연결만 끊는다. 어르신 쪽 연락처 기록은 어르신 것이다.
            conn.execute(
                "DELETE FROM guardians WHERE guardian_user_id = ? AND status = 'PENDING'",
                (user_id,),
            )
            conn.execute(
                "UPDATE guardians SET guardian_user_id = NULL WHERE guardian_user_id = ?",
                (user_id,),
            )
            conn.execute("DELETE FROM users WHERE id = ?", (user_id,))
            conn.commit()
        except sqlite3.IntegrityError as error:
            conn.rollback()
            raise HTTPException(
                status_code=409, detail="남아 있는 기록 때문에 지우지 못했어요."
            ) from error
        return Response(status_code=204)
    finally:
        conn.close()
