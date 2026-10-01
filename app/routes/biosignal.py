from fastapi import APIRouter, Query

from app.models.schemas import HeartRateCreate
from app.models.response_schemas import AbnormalEventResponse, HeartRateResponse
from app.services.biosignal_service import (
    get_abnormal_events,
    get_heart_summary,
    save_heart_rate,
)


router = APIRouter(prefix="/api/v1", tags=["Biosignal"])


@router.post("/biosignal/heart-rate", response_model=HeartRateResponse)
def create_heart_rate(request: HeartRateCreate):
    return save_heart_rate(request)


@router.get("/users/{user_id}/biosignal/events", response_model=list[AbnormalEventResponse])
def list_abnormal_events(user_id: str):
    return get_abnormal_events(user_id)


@router.get("/users/{user_id}/biosignal/heart-summary")
def read_heart_summary(
    user_id: str,
    include_readings: bool = False,
    utc_offset_minutes: int = Query(default=0, ge=-840, le=840),
):
    """심박수 화면 하나가 쓰는 것을 한 번에 돌려준다.

    오늘·이번 주·한 달을 따로 부르면 그 사이 날짜가 바뀔 때 서로 다른
    기준의 숫자가 한 화면에 놓인다.
    """
    return get_heart_summary(
        user_id, include_readings=include_readings,
        utc_offset_minutes=utc_offset_minutes,
    )
