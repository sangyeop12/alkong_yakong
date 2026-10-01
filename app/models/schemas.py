from typing import List, Literal, Optional

from pydantic import BaseModel, Field, field_validator


class UserCreate(BaseModel):
    name: str
    birth_date: Optional[str] = None
    gender: Optional[str] = None
    phone: Optional[str] = None
    role: str = "PATIENT"
    password: Optional[str] = None
    is_pregnant: Optional[bool] = None
    pregnancy_status: Optional[str] = None
    height_cm: Optional[float] = None
    weight_kg: Optional[float] = None
    blood_type: Optional[str] = None
    smoking: Optional[str] = None
    drinking: Optional[str] = None
    allergies: List[str] = Field(default_factory=list)
    diseases: List[str] = Field(default_factory=list)
    past_history: Optional[bool] = None
    family_history: Optional[bool] = None
    past_illnesses: List[str] = Field(default_factory=list)
    family_illnesses: List[str] = Field(default_factory=list)

    @field_validator("past_illnesses", "family_illnesses", mode="before")
    @classmethod
    def empty_history_lists_for_null(cls, value):
        return [] if value is None else value


class UserUpdate(BaseModel):
    """보낸 칸만 고친다. 값을 지우려면 null을 보낸다."""

    name: Optional[str] = None
    birth_date: Optional[str] = None
    gender: Optional[str] = None
    phone: Optional[str] = None
    is_pregnant: Optional[bool] = None
    pregnancy_status: Optional[str] = None
    height_cm: Optional[float] = None
    weight_kg: Optional[float] = None
    blood_type: Optional[str] = None
    smoking: Optional[str] = None
    drinking: Optional[str] = None
    allergies: Optional[List[str]] = None
    diseases: Optional[List[str]] = None
    past_history: Optional[bool] = None
    family_history: Optional[bool] = None
    past_illnesses: Optional[List[str]] = None
    family_illnesses: Optional[List[str]] = None

    @field_validator("past_illnesses", "family_illnesses", mode="before")
    @classmethod
    def empty_history_lists_for_null(cls, value):
        return [] if value is None else value


class UserLogin(BaseModel):
    phone: str
    password: str


class GuardianCreate(BaseModel):
    user_id: str
    guardian_name: str
    relationship: Optional[str] = None
    phone: Optional[str] = None
    fcm_token: Optional[str] = None
    notification_enabled: bool = True


class GuardianLinkRequest(BaseModel):
    """보호자가 어르신 전화번호로 함께 보기를 요청한다."""

    guardian_user_id: str
    patient_phone: str
    patient_relation: Optional[str] = None


class GuardianStatusUpdate(BaseModel):
    status: str


class OCRMedicineItem(BaseModel):
    drug_name: str
    ocr_drug_name_raw: Optional[str] = None
    medicine_code: Optional[str] = None
    ingredient: Optional[str] = None
    dosage: Optional[str] = None
    unit: Optional[str] = None
    dose_amount: Optional[str] = None
    dose_unit: Optional[str] = None
    frequency_per_day: Optional[int] = None
    times_per_take: Optional[int] = None
    duration_days: Optional[int] = None
    easy_explanation: Optional[str] = None
    warning_note: Optional[str] = None

    administration_times: List[str] = Field(default_factory=list)


class PrescriptionOCRRequest(BaseModel):
    user_id: str
    image_path: Optional[str] = None
    image_data: Optional[str] = None  # Base64 encoded image string
    ocr_text: Optional[str] = None
    hospital_name: Optional[str] = None
    pharmacy_name: Optional[str] = None
    prescribed_date: Optional[str] = None
    expire_date: Optional[str] = None
    mock_items: List[OCRMedicineItem] = Field(default_factory=list)


class PrescriptionConfirmItem(BaseModel):
    medicine_code: str
    drug_name: str
    ocr_drug_name_raw: Optional[str] = None
    ocr_field_confidences: dict = Field(default_factory=dict)
    dosage_form: Optional[str] = None
    administration_route: Optional[str] = None
    dosage: Optional[str] = None
    unit: Optional[str] = None
    dose_amount: Optional[str] = None
    dose_unit: Optional[str] = None
    frequency_per_day: Optional[int] = None
    times_per_take: Optional[int] = None
    duration_days: Optional[int] = None
    administration_times: List[str] = Field(default_factory=list)
    match_status: Optional[str] = None
    easy_explanation: Optional[str] = None
    short_explanation: Optional[str] = None
    warning_note: Optional[str] = None


class PrescriptionConfirmRequest(BaseModel):
    user_id: str
    items: List[PrescriptionConfirmItem] = Field(default_factory=list)
    hospital_name: Optional[str] = None
    pharmacy_name: Optional[str] = None
    prescribed_date: Optional[str] = None
    expire_date: Optional[str] = None
    ocr_text: Optional[str] = None


class DurAnalyzeRequest(BaseModel):
    user_id: str
    medicine_codes: List[str] = Field(default_factory=list)
    is_pregnant: Optional[bool] = None


class DurSyncRequest(BaseModel):
    types: List[str] = Field(
        default_factory=lambda: [
            "병용금기",
            "연령금기",
            "임부금기",
            "효능군중복",
        ]
    )
    page_size: int = Field(default=100, ge=1, le=1000)
    max_pages: Optional[int] = Field(default=None, ge=1)


class MedicationLogCreate(BaseModel):
    user_id: str
    schedule_id: int = Field(gt=0)


class MedicationReminderRequest(BaseModel):
    user_id: str
    target_date: Optional[str] = None


class MarkMissedRequest(BaseModel):
    user_id: str
    grace_hours: int = Field(default=2, ge=0, le=24)
    current_time: Optional[str] = None


class HeartRateCreate(BaseModel):
    user_id: str
    bpm: int = Field(gt=0)
    measured_at: Optional[str] = None
    device_id: Optional[str] = None
    source: str = "POLAR"
    measurement_context: Literal[
        "general", "before_medication", "after_medication"
    ] = "general"


class SelectedMedicine(BaseModel):
    medicine_code: str
    product_name: str


class DrugExplainChatRequest(BaseModel):
    user_id: str
    message: str
    selected_medicine: Optional[SelectedMedicine] = None
    selected_medicines: List[SelectedMedicine] = Field(
        default_factory=list,
        max_length=20,
    )
    temporary_medicines: List[SelectedMedicine] = Field(
        default_factory=list,
        max_length=20,
    )
    intent: Optional[
        Literal[
            "overview",
            "efficacy",
            "dosage",
            "precautions",
            "side_effects",
            "combination",
            "age",
            "pregnancy",
            "duplicate",
        ]
    ] = None


class ScheduleDayToggleRequest(BaseModel):
    date: str
