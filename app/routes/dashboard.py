from typing import Optional

from fastapi import APIRouter, HTTPException, Query

from app.models.response_schemas import DashboardResponse
from app.services.dashboard_service import get_dashboard, get_medication_calendar
from app.services.pharmacist.retrieve import search_official_medicine_candidates
from app.services.today_medication_service import get_today_medicines


router = APIRouter(prefix="/api/v1", tags=["Dashboard"])


@router.get("/users/{user_id}/dashboard", response_model=DashboardResponse)
def user_dashboard(
    user_id: str,
    date: Optional[str] = Query(default=None, description="YYYY-MM-DD"),
):
    return get_dashboard(user_id, date)


@router.get("/users/{user_id}/today-medicines")
def user_today_medicines(
    user_id: str,
    date: Optional[str] = Query(default=None, description="YYYY-MM-DD"),
):
    """오늘 홈에 보여줄 복약 차(아침·점심·저녁). 전체 목록은 GET /users/{id}/medicines."""
    return get_today_medicines(user_id, date)


@router.get("/users/{user_id}/medication-calendar")
def user_medication_calendar(
    user_id: str,
    year: Optional[int] = Query(default=None),
    month: Optional[int] = Query(default=None),
):
    """기록 달력. 실제 medication_schedules만 사용한다."""
    return get_medication_calendar(user_id, year, month)


@router.get("/medicines/lookup")
def lookup_medicines(
    q: str = Query(..., min_length=2, max_length=80, description="약 이름 검색"),
):
    """손입력용 공식 약 검색. 허가 코드가 있는 결과만 반환한다."""
    try:
        items = search_official_medicine_candidates(q.strip())
    except Exception as error:
        raise HTTPException(
            status_code=503,
            detail="공식 의약품 정보를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.",
        ) from error
    return {"query": q.strip(), "items": items, "count": len(items)}
