from typing import Literal, Optional

from pydantic import BaseModel, Field


ParticipantId = Literal["P01", "P02", "P03"]
Scenario = Literal[
    "REST_SITTING",
    "REST_LYING",
    "MORNING",
    "MEAL",
    "STAIRS",
    "WALK",
    "SHOWER",
    "COFFEE",
    "PHONE_AWAY",
    "SENSOR_OFF",
]


class BiosignalTestSessionStart(BaseModel):
    participant_id: ParticipantId
    scenario: Scenario
    is_synthetic: bool = False
    note: Optional[str] = None


class BiosignalTestSampleCreate(BaseModel):
    session_id: str = Field(min_length=1)
    bpm: int = Field(gt=0)
    measured_at: Optional[str] = None
    device_id: Optional[str] = None
    source: Literal["POLAR_DATASET_5S", "SYNTHETIC_TEST"]
    is_synthetic: bool
