from typing import Optional

from fastapi import APIRouter, Query

from app.models.schemas import (
    PrescriptionConfirmRequest,
    PrescriptionOCRRequest,
    ScheduleDayToggleRequest,
)
from app.models.response_schemas import PrescriptionResponse
from app.services.prescription_service import (
    confirm_prescription,
    create_prescription_from_ocr,
    get_prescription_schedule_days,
    get_user_prescriptions,
    toggle_prescription_schedule_day,
)


router = APIRouter(prefix="/api/v1", tags=["Prescription"])


@router.post("/prescriptions/ocr")
def preview_prescription_ocr(request: PrescriptionOCRRequest):
    """읽기 미리보기만. 복용 등록은 /prescriptions/confirm."""
    return create_prescription_from_ocr(request)


@router.post("/prescriptions/confirm")
def register_prescription_confirm(request: PrescriptionConfirmRequest):
    return confirm_prescription(request)


@router.get("/users/{user_id}/prescriptions", response_model=list[PrescriptionResponse])
def list_user_prescriptions(user_id: str):
    return get_user_prescriptions(user_id)


@router.get("/users/{user_id}/prescriptions/{prescription_id}/schedule-days")
def prescription_schedule_days(
    user_id: str,
    prescription_id: str,
    year: Optional[int] = Query(default=None),
    month: Optional[int] = Query(default=None),
):
    """이번에 등록한 약의 약 있는 날. 기록 달력(먹었어요/빠뜨렸어요)과 다르다."""
    return get_prescription_schedule_days(user_id, prescription_id, year, month)


@router.post("/users/{user_id}/prescriptions/{prescription_id}/schedule-days")
def prescription_schedule_day_toggle(
    user_id: str,
    prescription_id: str,
    request: ScheduleDayToggleRequest,
):
    """칸을 누르면 그 날 스케줄을 빼거나, 이 처방의 횟수·시각으로 붙인다."""
    return toggle_prescription_schedule_day(user_id, prescription_id, request.date)
