from typing import Optional

from fastapi import APIRouter, Query

from app.models.biosignal_test_schemas import (
    BiosignalTestSampleCreate,
    BiosignalTestSessionStart,
    ParticipantId,
    Scenario,
)
from app.models.response_schemas import (
    BiosignalTestSampleCreateResponse,
    BiosignalTestSampleResponse,
    BiosignalTestSessionStartResponse,
    BiosignalTestSessionResponse,
)
from app.services.biosignal_test_service import (
    get_active_polar_session,
    list_samples,
    list_sessions,
    save_sample,
    start_session,
    stop_session,
)


router = APIRouter(prefix="/api/v1/biosignal-test", tags=["Biosignal Test Dataset"])


@router.post("/sessions/start", response_model=BiosignalTestSessionStartResponse)
def create_session(request: BiosignalTestSessionStart):
    return start_session(request)


@router.post("/sessions/{session_id}/stop", response_model=BiosignalTestSessionResponse)
def end_session(session_id: str):
    return stop_session(session_id)


@router.get("/sessions", response_model=list[BiosignalTestSessionResponse])
def get_sessions(
    participant_id: Optional[ParticipantId] = Query(default=None),
    scenario: Optional[Scenario] = Query(default=None),
    is_synthetic: Optional[bool] = Query(default=None),
):
    return list_sessions(participant_id, scenario, is_synthetic)


@router.get("/sessions/active", response_model=BiosignalTestSessionResponse | None)
def get_active_session():
    return get_active_polar_session()


@router.get(
    "/sessions/{session_id}/samples",
    response_model=list[BiosignalTestSampleResponse],
)
def get_session_samples(session_id: str):
    return list_samples(session_id)


@router.post("/samples", response_model=BiosignalTestSampleCreateResponse)
def create_sample(request: BiosignalTestSampleCreate):
    return save_sample(request)
