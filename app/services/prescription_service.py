import base64
import binascii
import hashlib
import json
import logging
import re
import uuid
from calendar import monthrange
from datetime import date, timedelta

from fastapi import HTTPException

from app.database import get_connection, purge_ocr_placeholder_rows
from app.models.schemas import (
    OCRMedicineItem,
    PrescriptionConfirmItem,
    PrescriptionConfirmRequest,
    PrescriptionOCRRequest,
)
from app.services.matching.name_matcher import compare_key
from app.services.medicine_display import (
    ingredient_strength_from,
    infer_dosage_form,
    split_take_amount,
)
from app.services.medicine_detail_service import ensure_medicine_detail
from app.services.ocr.parser import (
    _clean_drug_label,
    _is_plausible_drug_candidate,
    is_strength_dosage,
    looks_truncated_ocr_name,
    persistable_take_dosage,
)
from app.services.ocr.pipeline import run_ocr_pipeline, run_ocr_text_pipeline
from app.services.pharmacist.easy_category import (
    derive_easy_category_from_medicine,
    display_product_name,
    sync_medicine_guidance,
)
from app.services.pharmacist.efficacy_display import display_efficacy_text
from app.services.pharmacist.ingredient import clean_ingredient_text
from app.services.pharmacist.retrieve import retrieve_official


logger = logging.getLogger("uvicorn.error")


OCR_RECOGNITION_MEANING = (
    "글자 인식률은 CLOVA가 사진 속 글자를 읽은 신뢰도예요. "
    "공식 의약품 확인 여부와 복용 정보의 정확성은 별도로 확인해야 해요."
)
OFFICIAL_MATCH_MEANING = (
    "이 숫자는 사진에서 읽은 약 이름 중 공식 약으로 확인한 비율이에요. "
    "글자 인식률과 복용 정보의 정확성은 별도로 확인해야 해요."
)

DEFAULT_SCHEDULE_TIMES = {
    1: [("08:00", "MORNING")],
    2: [("08:00", "MORNING"), ("20:00", "EVENING")],
    3: [
        ("08:00", "MORNING"),
        ("13:00", "AFTERNOON"),
        ("20:00", "EVENING"),
    ],
}


def _prepare_detail_without_blocking(cursor, medicine_code: str) -> None:
    """Isolate detail preparation so its failure cannot roll back OCR registration."""
    cursor.execute("SAVEPOINT medicine_detail_prepare")
    try:
        ensure_medicine_detail(cursor, medicine_code)
        cursor.execute("RELEASE SAVEPOINT medicine_detail_prepare")
    except Exception as error:
        cursor.execute("ROLLBACK TO SAVEPOINT medicine_detail_prepare")
        cursor.execute("RELEASE SAVEPOINT medicine_detail_prepare")
        try:
            cursor.execute(
                """
                INSERT INTO medicine_detail_jobs (medicine_code, status, last_error)
                VALUES (?, 'FAILED', ?)
                ON CONFLICT(medicine_code) DO UPDATE SET
                    status='FAILED', last_error=excluded.last_error,
                    finished_at=CURRENT_TIMESTAMP, updated_at=CURRENT_TIMESTAMP
                """,
                (medicine_code, str(error)[:500]),
            )
        except Exception:
            pass


def _compact_ocr_text(value: object) -> str:
    return re.sub(r"[^0-9A-Za-z가-힣.%]", "", str(value or "")).casefold()


def _confidence_pct_for_candidates(
    fields: object,
    candidates: list[object],
) -> int | None:
    targets = [_compact_ocr_text(value) for value in candidates]
    targets = [value for value in targets if value]
    if not targets or not isinstance(fields, list):
        return None

    values: list[float] = []
    for field in fields:
        if not isinstance(field, dict):
            continue
        field_text = _compact_ocr_text(field.get("text"))
        if not field_text:
            continue
        if not any(
            field_text == target or field_text in target or target in field_text
            for target in targets
        ):
            continue
        try:
            confidence = float(field.get("confidence"))
        except (TypeError, ValueError):
            continue
        if 0 <= confidence <= 1:
            values.append(confidence)
    if not values:
        return None
    return int(round(100 * min(values)))


def _ocr_field_confidences(
    item: OCRMedicineItem,
    *,
    raw_name: str,
    ocr_trace: dict | None,
) -> dict[str, int]:
    fields = (ocr_trace or {}).get("fields")
    values: dict[str, int] = {}

    name_pct = _confidence_pct_for_candidates(fields, [raw_name, item.drug_name])
    if name_pct is not None:
        values["drug_name"] = name_pct

    dose_pct = _confidence_pct_for_candidates(fields, [item.dosage])
    if dose_pct is not None:
        values["dose_amount"] = dose_pct

    if item.frequency_per_day:
        frequency_pct = _confidence_pct_for_candidates(
            fields,
            [f"{item.frequency_per_day}회", f"{item.frequency_per_day}번"],
        )
        if frequency_pct is not None:
            values["frequency_per_day"] = frequency_pct

    if item.duration_days:
        duration_pct = _confidence_pct_for_candidates(
            fields,
            [f"{item.duration_days}일", f"{item.duration_days}일분"],
        )
        if duration_pct is not None:
            values["duration_days"] = duration_pct

    return values


def _structured_items(structured: dict) -> list[OCRMedicineItem]:
    results = []
    for item in structured.get("items", []):
        if not item.get("drug_name"):
            continue
        results.append(
            OCRMedicineItem(
                drug_name=item["drug_name"],
                ocr_drug_name_raw=item.get("ocr_drug_name_raw"),
                dosage=item.get("dosage"),
                unit=item.get("unit"),
                dose_amount=item.get("dose_amount"),
                dose_unit=item.get("dose_unit"),
                frequency_per_day=item.get("frequency_per_day"),
                times_per_take=item.get("times_per_take"),
                duration_days=item.get("duration_days"),
                easy_explanation=item.get("easy_explanation"),
                warning_note=item.get("warning_note"),
            )
        )
    return results


def _raise_ocr_fail(result) -> None:
    error = result.error or "unknown"
    payload = {"message": "처방전을 읽지 못했습니다.", "error": error}
    if error == "missing_api_key":
        raise HTTPException(status_code=503, detail=payload)
    if error == "quota_exceeded":
        raise HTTPException(status_code=503, detail=payload)
    if error in {"timeout", "DeadlineExceeded"}:
        raise HTTPException(status_code=504, detail=payload)
    if error in {"auth_error", "unavailable"} or (
        result.trace.get("stage") == "engine"
        and error not in {"empty_image", "empty_raw_text"}
    ):
        raise HTTPException(status_code=502, detail=payload)
    raise HTTPException(status_code=422, detail=payload)


def _extract_items(
    request: PrescriptionOCRRequest,
) -> tuple[list[OCRMedicineItem], str, dict, dict]:
    if request.image_data:
        try:
            encoded = request.image_data.split(",", 1)[-1]
            image_bytes = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError, TypeError) as error:
            raise HTTPException(
                status_code=422,
                detail="이미지 데이터가 올바르지 않습니다.",
            ) from error
        result = run_ocr_pipeline(image_bytes)
    elif request.ocr_text:
        result = run_ocr_text_pipeline(request.ocr_text)
    else:
        raise HTTPException(status_code=422, detail="처방전 이미지 또는 원문이 필요합니다.")

    if not result.ok or not result.structured:
        _raise_ocr_fail(result)
    items = _structured_items(result.structured)
    if not items:
        raise HTTPException(status_code=422, detail="처방전에서 약품을 찾지 못했습니다.")
    trace = dict(result.trace or {})
    coverage = result.structured.get("field_coverage")
    if coverage:
        trace["field_coverage"] = coverage
    discarded = result.structured.get("discarded_names")
    if discarded:
        trace["discarded_names"] = discarded
    return items, result.raw_text, trace, result.structured


def _upsert_official_medicine(cursor, official: dict) -> tuple[str, str]:
    med = official.get("medicine") or {}
    code = str(med.get("medicine_code") or "").strip()
    name = str(med.get("product_name") or med.get("medicine_name") or "").strip()
    if not code or not name:
        raise HTTPException(
            status_code=422,
            detail="공식 약품 코드가 없습니다.",
        )
    precautions = med.get("precautions") or med.get("cautions") or ""
    easy_category = derive_easy_category_from_medicine(
        {
            **med,
            "product_name": name,
            "source_text": official.get("source_text"),
        }
    )
    # 성분이 없거나 제품명과 같으면 DUR이 제품명으로 오탐하지 않게 빈 값/기존값 유지
    incoming_ingredient = clean_ingredient_text(med.get("ingredient"))
    if incoming_ingredient == name:
        incoming_ingredient = ""
    if not incoming_ingredient:
        prev = cursor.execute(
            "SELECT ingredient, product_name FROM medicines WHERE medicine_code = ?",
            (code,),
        ).fetchone()
        if (
            prev
            and prev["ingredient"]
            and clean_ingredient_text(prev["ingredient"])
            and clean_ingredient_text(prev["ingredient"])
            != clean_ingredient_text(prev["product_name"])
        ):
            ingredient = clean_ingredient_text(prev["ingredient"])
        else:
            ingredient = ""
    else:
        ingredient = incoming_ingredient

    cursor.execute(
        """
        INSERT INTO medicines (
            medicine_code, product_name, ingredient, manufacturer,
            efficacy, usage, precautions, image_url, easy_category
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(medicine_code) DO UPDATE SET
            product_name = excluded.product_name,
            ingredient = CASE
                WHEN excluded.ingredient IS NOT NULL
                     AND trim(excluded.ingredient) != ''
                     AND excluded.ingredient != excluded.product_name
                THEN excluded.ingredient
                ELSE medicines.ingredient
            END,
            manufacturer = COALESCE(NULLIF(trim(excluded.manufacturer), ''), medicines.manufacturer),
            efficacy = COALESCE(NULLIF(trim(excluded.efficacy), ''), medicines.efficacy),
            usage = COALESCE(NULLIF(trim(excluded.usage), ''), medicines.usage),
            precautions = COALESCE(NULLIF(trim(excluded.precautions), ''), medicines.precautions),
            image_url = COALESCE(NULLIF(trim(excluded.image_url), ''), medicines.image_url),
            easy_category = COALESCE(
                NULLIF(trim(medicines.easy_category), ''),
                excluded.easy_category
            ),
            updated_at = CURRENT_TIMESTAMP
        """,
        (
            code,
            name,
            ingredient,
            med.get("manufacturer"),
            med.get("efficacy"),
            med.get("usage"),
            precautions if isinstance(precautions, str) else str(precautions or ""),
            med.get("image_url"),
            easy_category,
        ),
    )
    # OCR로 처음 들어온 공식 약도 기존 DB 약과 같은 상세 준비 경로를 탄다.
    # 로컬 공식 정보만 사용하므로 외부 API·Gemini를 기다리지 않는다.
    _prepare_detail_without_blocking(cursor, code)
    status = "MATCHED" if official.get("source") == "local" else "MFDS"
    return code, status


def _official_efficacy_text(medicine: dict | None) -> str | None:
    if not medicine:
        return None
    return display_efficacy_text(
        medicine.get("efficacy") or medicine.get("efficacy_text")
    )


def _official_display_name(medicine: dict, fallback: str) -> str:
    return (
        str(medicine.get("product_name") or medicine.get("medicine_name") or "").strip()
        or (fallback or "").strip()
    )


def _resolve_medicine(cursor, item: OCRMedicineItem) -> tuple[str, str, str] | None:
    """공식 허가/로컬 약만 반환. 못 찾으면 None (OCR 원문은 약으로 쓰지 않음)."""
    medicine = None
    if item.medicine_code and not str(item.medicine_code).upper().startswith("OCR-"):
        medicine = cursor.execute(
            """
            SELECT * FROM medicines
            WHERE medicine_code = ? AND medicine_code NOT LIKE 'OCR-%'
            """,
            (item.medicine_code,),
        ).fetchone()
    if medicine:
        row = dict(medicine)
        _ensure_easy_category(cursor, row)
        return (
            row["medicine_code"],
            "MATCHED",
            _official_display_name(row, item.drug_name),
        )

    dosage_hint = item.dosage if is_strength_dosage(item.dosage) else None
    official = retrieve_official(
        item.drug_name,
        dosage_hint=dosage_hint,
    )
    if official:
        code, status = _upsert_official_medicine(cursor, official)
        name = _official_display_name(official.get("medicine") or {}, item.drug_name)
        return code, status, name

    return None


def _ensure_easy_category(cursor, medicine: dict) -> None:
    # 기존 값은 수동 검토/이관된 값일 수 있으므로 자동 추론으로 덮어쓰지 않는다.
    if str(medicine.get("easy_category") or "").strip():
        return
    category = derive_easy_category_from_medicine(medicine)
    if not category:
        return
    cursor.execute(
        """
        UPDATE medicines
        SET easy_category = ?, updated_at = CURRENT_TIMESTAMP
        WHERE medicine_code = ?
        """,
        (category, medicine["medicine_code"]),
    )
    medicine["easy_category"] = category


def _parse_date(value: str | None, fallback: date) -> date:
    if not value:
        return fallback
    try:
        return date.fromisoformat(value)
    except ValueError:
        return fallback


def _schedule_frequency(value) -> int | None:
    """읽은 1일 횟수만 쓴다. 없으면 1로 채우지 않는다."""
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    if number < 1:
        return None
    return number


def _clock_times_for_item(item: OCRMedicineItem) -> list[str]:
    confirmed = _confirmed_clock_times(item.administration_times)
    if confirmed:
        return confirmed
    frequency = _schedule_frequency(item.frequency_per_day)
    defaults = DEFAULT_SCHEDULE_TIMES.get(frequency) if frequency is not None else None
    if not defaults:
        return []
    return [clock for clock, _slot in defaults]


def _clock_times_from_user_medicine(row) -> list[str]:
    """저장된 횟수·시각만 쓴다. 달력에서 시각을 지어 넣지 않는다."""
    raw_times: list[str] = []
    try:
        parsed = json.loads(row["administration_times"] or "[]")
        if isinstance(parsed, list):
            raw_times = [str(value) for value in parsed]
    except (TypeError, json.JSONDecodeError, ValueError):
        raw_times = []
    confirmed = _confirmed_clock_times(raw_times)
    if confirmed:
        return confirmed
    frequency = _schedule_frequency(row["frequency_per_day"])
    defaults = DEFAULT_SCHEDULE_TIMES.get(frequency) if frequency is not None else None
    if not defaults:
        return []
    return [clock for clock, _slot in defaults]


def _schedule_dates(
    prescribed_date: str | None,
    expire_date: str | None,
    duration_days: int | None,
) -> list[date]:
    try:
        days = int(duration_days) if duration_days is not None else None
    except (TypeError, ValueError):
        days = None
    if days is None or days < 1:
        return []
    start_date = _parse_date(prescribed_date, date.today())
    duration_end = start_date + timedelta(days=days - 1)
    if expire_date:
        # 처방 유효일이 더 멀어도 OCR에서 확인한 복용 일수보다 늘리지 않는다.
        end_date = min(_parse_date(expire_date, duration_end), duration_end)
    else:
        end_date = duration_end

    if end_date < start_date:
        end_date = start_date

    day_count = min((end_date - start_date).days + 1, 365)
    return [start_date + timedelta(days=offset) for offset in range(day_count)]


def _create_medication_schedules(
    cursor,
    *,
    user_id: str,
    user_medicine_id: int,
    prescribed_date: str | None,
    expire_date: str | None,
    item: OCRMedicineItem,
) -> list[dict]:
    confirmed_times = _clock_times_for_item(item)
    if not confirmed_times:
        return []
    created_schedules = []

    for scheduled_date in _schedule_dates(
        prescribed_date,
        expire_date,
        item.duration_days,
    ):
        for scheduled_time in confirmed_times:
            time_slot = _time_slot_for_clock(scheduled_time)
            cursor.execute(
                """
                INSERT OR IGNORE INTO medication_schedules (
                    user_id, user_medicine_id, scheduled_date,
                    scheduled_time, time_slot, status
                ) VALUES (?, ?, ?, ?, ?, 'PENDING')
                """,
                (
                    user_id,
                    user_medicine_id,
                    scheduled_date.isoformat(),
                    scheduled_time,
                    time_slot,
                ),
            )
            if cursor.rowcount:
                created_schedules.append(
                    {
                        "scheduled_date": scheduled_date.isoformat(),
                        "scheduled_time": scheduled_time,
                        "time_slot": time_slot,
                        "status": "PENDING",
                    }
                )

    if created_schedules and not _confirmed_clock_times(item.administration_times):
        cursor.execute(
            """
            UPDATE user_medicines
            SET administration_times = ?
            WHERE id = ?
            """,
            (json.dumps(confirmed_times, ensure_ascii=False), user_medicine_id),
        )

    return created_schedules


_CLOCK_TIME = re.compile(r"^(?:[01]\d|2[0-3]):[0-5]\d$")
_EXPLICIT_TIME_LABELS = {
    "아침": "08:00",
    "점심": "13:00",
    "저녁": "20:00",
    "취침전": "22:00",
    "자기전": "22:00",
    "MORNING": "08:00",
    "LUNCH": "13:00",
    "AFTERNOON": "13:00",
    "EVENING": "20:00",
    "NIGHT": "22:00",
}


def _confirmed_clock_times(values: list[str] | None) -> list[str]:
    """사용자가 확인한 실제 시각만 스케줄로 쓴다."""
    result: list[str] = []
    for raw in values or []:
        value = str(raw or "").strip()
        normalized = value if _CLOCK_TIME.fullmatch(value) else _EXPLICIT_TIME_LABELS.get(
            re.sub(r"\s+", "", value).upper()
        )
        if normalized and normalized not in result:
            result.append(normalized)
    return result


def _time_slot_for_clock(value: str) -> str:
    hour = int(value.split(":", 1)[0])
    if hour < 11:
        return "MORNING"
    if hour < 16:
        return "AFTERNOON"
    return "EVENING"


def _validated_confirm_dosage(
    item: PrescriptionConfirmItem,
    official_name: str,
) -> str | None:
    """OCR이 읽은 1회 복용량을 정규화한다. 비어 있어도 등록은 막지 않는다."""
    return _normalized_confirm_take_amount(item)


_TAKE_UNIT_LABELS = {
    "T": "알",
    "TAB": "알",
    "정": "알",
    "알": "알",
    "C": "캡슐",
    "CAP": "캡슐",
    "캡슐": "캡슐",
    "PKG": "포",
    "포": "포",
    "EA": "개",
    "개": "개",
    "ML": "mL",
    "밀리리터": "mL",
    "방울": "방울",
}


def _format_take_number(value: str) -> str:
    number = float(value)
    if number.is_integer():
        return str(int(number))
    return f"{number:.3f}".rstrip("0").rstrip(".")


def _unit_from_dosage_form(dosage_form: str | None) -> str | None:
    """제형만으로 단위를 확정할 수 있는 고형제에 한해 단위를 보완한다."""
    form = str(dosage_form or "").strip()
    if "캡슐" in form:
        return "캡슐"
    if "정" in form:
        return "정"
    return None


def _preview_take_fields(
    item: OCRMedicineItem,
    *,
    dosage_form: str | None,
) -> tuple[str | None, str | None, bool]:
    """OCR의 1회량을 제품 함량과 분리해 확인 화면용 필드로 만든다."""
    raw = persistable_take_dosage(item.dose_amount or item.dosage)
    if not raw:
        if item.times_per_take is None or item.times_per_take <= 0:
            return None, None, False
        raw = str(item.times_per_take)

    compact = re.sub(r"\s+", "", raw)
    embedded = re.fullmatch(
        r"(?P<amount>\d+(?:\.\d+)?)(?P<unit>알|정|캡슐|포|개|mL|ml|방울|T|TAB|C|CAP|PKG|EA)?",
        compact,
        re.IGNORECASE,
    )
    if not embedded:
        return None, None, False

    amount = _format_take_number(embedded.group("amount"))
    raw_unit = str(embedded.group("unit") or item.dose_unit or item.unit or "").strip()
    unit = {
        "T": "정",
        "TAB": "정",
        "정": "정",
        "알": "정",
        "C": "캡슐",
        "CAP": "캡슐",
        "캡슐": "캡슐",
        "PKG": "포",
        "포": "포",
        "EA": "개",
        "개": "개",
        "ML": "mL",
        "밀리리터": "mL",
        "방울": "방울",
    }.get(raw_unit.upper())
    inferred = False
    if not unit:
        unit = _unit_from_dosage_form(dosage_form)
        inferred = unit is not None
    return amount, unit, inferred


def _normalized_confirm_take_amount(item: PrescriptionConfirmItem) -> str | None:
    raw = persistable_take_dosage(item.dose_amount or item.dosage)
    unit_from_field = _TAKE_UNIT_LABELS.get(
        str(item.dose_unit or item.unit or "").strip().upper()
    )
    if not unit_from_field:
        unit_from_field = _unit_from_dosage_form(item.dosage_form)

    if raw:
        compact = re.sub(r"\s+", "", raw)
        fraction = re.fullmatch(
            r"(?P<numerator>\d+)/(?P<denominator>\d+)(?P<unit>알|정|캡슐|포|개|mL|ml|방울|T|TAB|C|CAP|PKG|EA)",
            compact,
            re.IGNORECASE,
        )
        if fraction and int(fraction.group("denominator")) != 0:
            amount = int(fraction.group("numerator")) / int(
                fraction.group("denominator")
            )
            unit = _TAKE_UNIT_LABELS.get(fraction.group("unit").upper())
            return f"{_format_take_number(str(amount))}{unit}" if unit else None
        half = re.fullmatch(
            r"반(?P<unit>알|정|캡슐|포|개)",
            compact,
            re.IGNORECASE,
        )
        if half:
            unit = _TAKE_UNIT_LABELS.get(half.group("unit").upper())
            return f"0.5{unit}" if unit else None
        match = re.fullmatch(
            r"(?P<amount>\d+(?:\.\d+)?)(?P<unit>알|정|캡슐|포|개|mL|ml|방울|T|TAB|C|CAP|PKG|EA)",
            compact,
            re.IGNORECASE,
        )
        if match:
            amount = _format_take_number(match.group("amount"))
            unit = _TAKE_UNIT_LABELS.get(match.group("unit").upper())
            return f"{amount}{unit}" if unit else None
        if re.fullmatch(r"\d+(?:\.\d+)?", compact) and unit_from_field:
            return f"{_format_take_number(compact)}{unit_from_field}"
        # 단위가 불명확하더라도 처방전에서 읽은 숫자 자체는 버리지 않는다.
        if re.fullmatch(r"\d+(?:\.\d+)?", compact):
            return _format_take_number(compact)
        return None

    if item.times_per_take is not None and item.times_per_take > 0 and unit_from_field:
        amount = _format_take_number(str(item.times_per_take))
        return f"{amount}{unit_from_field}"
    return None


def _same_drug_name(left: str, right: str) -> bool:
    a, b = compare_key(left), compare_key(right)
    if not a or not b:
        return False
    return a == b or a in b or b in a


def _druglike_misses(names: list[str], already: list[str]) -> list[str]:
    misses: list[str] = []
    for name in names or []:
        cleaned = _clean_drug_label(name) or str(name or "").strip()
        if not cleaned:
            continue
        if not (
            _is_plausible_drug_candidate(name, cleaned)
            or _is_plausible_drug_candidate(cleaned)
        ):
            continue
        if any(_same_drug_name(cleaned, other) for other in already + misses):
            continue
        misses.append(cleaned)
    return misses


def _unique_names(values: list) -> list[str]:
    seen: set[str] = set()
    names: list[str] = []
    for value in values or []:
        name = str(value or "").strip()
        if not name or name in seen:
            continue
        seen.add(name)
        names.append(name)
    return names


def _should_retake(
    pct: int,
    unrecognized_names: list[str],
    discarded_names: list[str],
    *,
    matched_n: int = 0,
) -> bool:
    if unrecognized_names:
        return True
    if matched_n > 0 and pct >= 85:
        return False
    if pct < 60:
        return True
    return any(looks_truncated_ocr_name(name) for name in discarded_names)


def _user_readiness(items: list[dict], ocr_trace: dict | None = None) -> dict:
    """사용자용 공식 약 확인률(%). 공식 이름으로 맞춘 약만 분자로 둔다.

    병원명·약국명·처방일·횟수·일수·성분은 점수에 넣지 않는다.
    '나주' '진정'처럼 약이 아닌 조각은 호출 전에 걸러져야 한다.
    """
    _ = ocr_trace
    named = [
        item
        for item in items
        if str(item.get("drug_name") or "").strip()
    ]
    if not named:
        return {
            "pct": 0,
            "label": "poor",
            "summary": "공식 약으로 맞춘 약이 거의 없어요. 흔들리지 않게 다시 찍어 주세요.",
            "meaning": OFFICIAL_MATCH_MEANING,
            "missing_hints": ["약 이름"],
            "metric": "official_name",
        }

    matched_n = 0
    unmatched_n = 0
    hints: list[str] = []
    for item in named:
        status = str(item.get("match_status") or "").upper()
        uncertain = item.get("uncertain") is True or status == "UNMATCHED"
        if uncertain:
            unmatched_n += 1
            hints.append("약 이름 확인")
        else:
            matched_n += 1

    pct = int(max(0, min(100, round(100.0 * matched_n / len(named)))))
    found = matched_n

    if pct >= 85:
        label = "good"
        summary = f"약 {found}개를 공식 이름으로 맞췄어요."
    elif pct >= 60:
        label = "fair"
        summary = (
            f"약 {found}개는 맞췄고, {unmatched_n}개는 공식 목록에서 못 찾았어요."
            if unmatched_n
            else f"약 {found}개 공식 약 확인이 보통이에요."
        )
    else:
        label = "poor"
        summary = "공식 약으로 맞춘 비율이 낮아요. 흔들리지 않게 다시 찍어 주세요."

    unique_hints: list[str] = []
    for hint in hints:
        if hint not in unique_hints:
            unique_hints.append(hint)

    return {
        "pct": pct,
        "label": label,
        "summary": summary,
        "meaning": OFFICIAL_MATCH_MEANING,
        "missing_hints": unique_hints[:4],
        "metric": "official_name",
    }


def create_prescription_from_ocr(request: PrescriptionOCRRequest) -> dict:
    """OCR 미리보기만. user_medicines/스케줄은 넣지 않는다 (확정 API에서 등록)."""
    conn = get_connection()
    try:
        cursor = conn.cursor()
        purge_ocr_placeholder_rows(conn)
        items, raw_text, ocr_trace, structured = _extract_items(request)
        user = cursor.execute(
            "SELECT id FROM users WHERE id = ?", (request.user_id,)
        ).fetchone()
        if not user:
            cursor.execute(
                "INSERT INTO users (id, name, role) VALUES (?, ?, ?)",
                (request.user_id, "테스트유저", "PATIENT"),
            )

        preview_items = []
        unrecognized_names: list[str] = []
        readiness_seed: list[dict] = []
        for item in items:
            resolved = _resolve_medicine(cursor, item)
            if not resolved:
                if not _is_plausible_drug_candidate(item.drug_name):
                    continue
                unrecognized_names.append(item.drug_name)
                readiness_seed.append(
                    {
                        "drug_name": item.drug_name,
                        "ingredient": "",
                        "uncertain": True,
                        "match_status": "UNMATCHED",
                    }
                )
                continue
            medicine_code, match_status, official_name = resolved
            official_name = display_product_name(official_name) or official_name
            ocr_raw = (item.ocr_drug_name_raw or item.drug_name or "").strip()
            med_row = cursor.execute(
                "SELECT * FROM medicines WHERE medicine_code = ?",
                (medicine_code,),
            ).fetchone()
            med_dict = dict(med_row) if med_row else {}
            guidance = sync_medicine_guidance(cursor, med_dict)
            official_spoken = guidance["short_explanation"]
            ingredient = med_dict.get("ingredient") or ""
            dosage_form = med_dict.get("dosage_form") or infer_dosage_form(official_name)
            dose_amount, dose_unit, dose_unit_inferred = _preview_take_fields(
                item,
                dosage_form=dosage_form,
            )
            field_confidences = _ocr_field_confidences(
                item,
                raw_name=ocr_raw,
                ocr_trace=ocr_trace,
            )
            readiness_seed.append(
                {
                    "drug_name": official_name,
                    "product_name": official_name,
                    "ingredient": ingredient,
                    "uncertain": False,
                    "match_status": match_status,
                }
            )
            preview_items.append(
                {
                    "medicine_code": medicine_code,
                    "drug_name": official_name,
                    "display_name": official_name,
                    "official_product_name": str(
                        med_dict.get("product_name") or official_name
                    ),
                    "ingredient_name": ingredient,
                    "ingredient_strength": (
                        med_dict.get("ingredient_strength")
                        or ingredient_strength_from(ingredient, official_name)
                    ),
                    "dosage_form": dosage_form,
                    "administration_route": med_dict.get("administration_route") or "",
                    "ocr_drug_name_raw": ocr_raw if ocr_raw != official_name else None,
                    "match_status": match_status,
                    "dosage": persistable_take_dosage(item.dosage),
                    "unit": item.unit,
                    "dose_amount": dose_amount,
                    "dose_unit": dose_unit,
                    "dose_unit_inferred": dose_unit_inferred,
                    "dose_needs_unit_confirmation": bool(dose_amount and not dose_unit),
                    "frequency_per_day": item.frequency_per_day,
                    "times_per_take": item.times_per_take,
                    "duration_days": item.duration_days,
                    "administration_times": list(item.administration_times or []),
                    "easy_explanation": official_spoken,
                    "short_explanation": official_spoken,
                    "easy_category": guidance["purpose_label"],
                    "purpose_label": guidance["purpose_label"],
                    "easy_purposes": guidance["easy_purposes"],
                    "key_caution": guidance["key_caution"],
                    "key_cautions": guidance["key_cautions"],
                    "purpose_notice": guidance["purpose_notice"],
                    "warning_note": item.warning_note,
                    "uncertain": False,
                    "ocr_field_confidences": field_confidences,
                    "recognition_pct": field_confidences.get("drug_name"),
                    "schedules": [],
                    "interaction_conflicts": [],
                }
            )

        discarded_names = _unique_names(
            (structured or {}).get("discarded_names")
            or (ocr_trace or {}).get("discarded_names")
        )
        already = (
            unrecognized_names
            + [str(row.get("drug_name") or "") for row in preview_items]
            + [str(item.drug_name or "") for item in items]
        )
        for miss in _druglike_misses(discarded_names, already):
            unrecognized_names.append(miss)

        matched_seed = [
            row
            for row in readiness_seed
            if str(row.get("match_status") or "").upper() != "UNMATCHED"
            and row.get("uncertain") is not True
        ]
        # 공식 약으로 못 맞춘 후보도 분모에 포함해야 전체 인식률이 부풀려지지 않는다.
        score_seed = readiness_seed

        if not preview_items and not unrecognized_names:
            raise HTTPException(
                status_code=422,
                detail="처방전에서 확인할 수 있는 약을 찾지 못했습니다.",
            )

        # 약 사전(medicines) upsert 만 커밋. 복용 등록은 confirm 에서.
        conn.commit()
        try:
            from app.services.dur_service import preview_conflicts_for_codes

            conflict_map = preview_conflicts_for_codes(
                request.user_id,
                [str(row.get("medicine_code") or "") for row in preview_items],
            )
        except Exception:
            conflict_map = {}
        for row in preview_items:
            row["interaction_conflicts"] = conflict_map.get(
                str(row.get("medicine_code") or ""),
                [],
            )
        readiness = _user_readiness(score_seed, ocr_trace)
        raw_engine_confidence = (ocr_trace or {}).get("engine_confidence")
        try:
            ocr_confidence_pct = int(round(float(raw_engine_confidence) * 100))
        except (TypeError, ValueError):
            ocr_confidence_pct = None
        retake_recommended = _should_retake(
            readiness["pct"],
            unrecognized_names,
            discarded_names,
            matched_n=len(preview_items),
        )
        return {
            "prescription_id": None,
            "preview": True,
            "registered": False,
            "user_id": request.user_id,
            "ocr_status": "COMPLETED",
            "ocr_text": raw_text,
            "ocr_trace": ocr_trace,
            "unrecognized_names": unrecognized_names,
            "discarded_names": discarded_names,
            "items": preview_items,
            "hospital_name": request.hospital_name or structured.get("hospital_name"),
            "pharmacy_name": request.pharmacy_name or structured.get("pharmacy_name"),
            "prescribed_date": request.prescribed_date
            or structured.get("prescribed_date"),
            "user_readiness_pct": readiness["pct"],
            "official_match_pct": readiness["pct"],
            "readiness_label": readiness["label"],
            "readiness_summary": readiness["summary"],
            "missing_hints": readiness["missing_hints"],
            "recognition_pct": ocr_confidence_pct,
            "recognition_label": "clova_text" if ocr_confidence_pct is not None else None,
            "recognition_summary": (
                f"사진 글자 인식률은 {ocr_confidence_pct}%예요."
                if ocr_confidence_pct is not None
                else "글자 인식률 정보가 없어 직접 확인이 필요해요."
            ),
            "recognition_meaning": OCR_RECOGNITION_MEANING,
            "recognition_metric": "clova_text_confidence",
            "retake_recommended": retake_recommended,
        }
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _reactivate_duplicate_prescription(cursor, *, user_id: str, prescription_id: str) -> list[dict]:
    """같은 OCR 처방을 다시 확인하면 기존 약을 오늘 기준으로 다시 활성화한다."""
    rows = cursor.execute(
        """
        SELECT um.id AS user_medicine_id, um.medicine_code,
               pi.id AS prescription_item_id, pi.ocr_drug_name,
               pi.dosage, pi.unit, pi.frequency_per_day,
               pi.times_per_take, pi.duration_days, pi.administration_times,
               pi.easy_explanation, pi.warning_note, pi.match_status
        FROM prescription_items pi
        JOIN user_medicines um ON um.prescription_item_id = pi.id
        WHERE pi.prescription_id = ? AND um.user_id = ?
        ORDER BY pi.id
        """,
        (prescription_id, user_id),
    ).fetchall()
    today = date.today().isoformat()
    restored: list[dict] = []
    for row in rows:
        user_medicine_id = row["user_medicine_id"]
        medicine_code = row["medicine_code"]
        schedule_dates = _schedule_dates(today, None, row["duration_days"])
        end_date = schedule_dates[-1].isoformat() if schedule_dates else None
        cursor.execute(
            """
            UPDATE user_medicines
            SET is_active = 0, status = 'PAST'
            WHERE user_id = ? AND medicine_code = ? AND id <> ?
            """,
            (user_id, medicine_code, user_medicine_id),
        )
        cursor.execute(
            "DELETE FROM medication_schedules WHERE user_id = ? AND user_medicine_id = ?",
            (user_id, user_medicine_id),
        )
        cursor.execute(
            """
            UPDATE user_medicines
            SET is_active = 1, status = 'ACTIVE', start_date = ?, end_date = ?,
                last_prescribed_at = ?
            WHERE id = ?
            """,
            (today, end_date, today, user_medicine_id),
        )
        try:
            administration_times = json.loads(row["administration_times"] or "[]")
        except (TypeError, json.JSONDecodeError):
            administration_times = []
        ocr_item = OCRMedicineItem(
            drug_name=row["ocr_drug_name"],
            medicine_code=medicine_code,
            dosage=row["dosage"],
            unit=row["unit"],
            frequency_per_day=row["frequency_per_day"],
            times_per_take=row["times_per_take"],
            duration_days=row["duration_days"],
            administration_times=administration_times,
            easy_explanation=row["easy_explanation"],
            warning_note=row["warning_note"],
        )
        schedules = _create_medication_schedules(
            cursor,
            user_id=user_id,
            user_medicine_id=user_medicine_id,
            prescribed_date=today,
            expire_date=None,
            item=ocr_item,
        )
        restored.append(
            {
                "id": row["prescription_item_id"],
                "user_medicine_id": user_medicine_id,
                "medicine_code": medicine_code,
                "drug_name": row["ocr_drug_name"],
                "match_status": row["match_status"],
                "frequency_per_day": row["frequency_per_day"],
                "duration_days": row["duration_days"],
                "schedules": schedules,
            }
        )
    return restored


def _analyze_registered_medicines_locally(user_id: str) -> dict:
    """등록 응답을 막는 외부 동기화 없이 현재 로컬 DUR 기준만 검사한다."""
    try:
        from app.models.schemas import DurAnalyzeRequest
        from app.services.dur_service import analyze_dur

        return analyze_dur(
            DurAnalyzeRequest(user_id=user_id, medicine_codes=[]),
            refresh=False,
        )
    except Exception:
        # DUR 확인 실패가 이미 저장된 처방과 복용 일정을 되돌리면 안 된다.
        return {
            "risk_result_id": None,
            "analysis_id": None,
            "user_id": user_id,
            "risk_level": "UNKNOWN",
            "assessment_status": "INCOMPLETE",
            "analysis_complete": False,
            "has_risk": None,
            "total_matches": 0,
            "total_count": 0,
            "representative_type": None,
            "message": "약은 등록됐지만 함께먹기 검사를 마치지 못했어요.",
            "by_type": {},
            "ingredients": [],
            "medicine_names": [],
            "matches": [],
            "incomplete": True,
            "incomplete_reasons": ["함께먹기 검사 결과를 불러오지 못했어요."],
            "incomplete_types": ["병용금기", "연령금기", "임부금기", "효능군중복"],
            "skipped_medicine_names": [],
            "taboo_row_count": 0,
            "dur_sync_status": "local_failed",
            "dur_sync_fetched": 0,
            "dur_sync_upserted": 0,
        }


def _registration_result(
    *,
    prescription_id: str,
    user_id: str,
    items: list[dict],
    duplicate: bool = False,
) -> dict:
    dur_result = _analyze_registered_medicines_locally(user_id)
    if not isinstance(dur_result, dict):
        dur_result = {}
    matches = dur_result.get("matches")
    complete = (
        dur_result.get("analysis_complete") is True
        and dur_result.get("incomplete") is not True
        and isinstance(dur_result.get("assessment_status"), str)
        and dur_result.get("assessment_status") in {"SAFE", "RISK_FOUND"}
        and isinstance(matches, list)
        and all(isinstance(m, dict) and isinstance(m.get("type"), str) and m["type"] for m in matches)
        and isinstance(dur_result.get("has_risk"), bool)
        and dur_result["has_risk"] == bool(matches)
        and dur_result["assessment_status"] == ("RISK_FOUND" if matches else "SAFE")
    )
    if not complete:
        dur_result = {**dur_result, "analysis_complete": False,
                      "assessment_status": "INCOMPLETE", "incomplete": True,
                      "has_risk": None}
    # 최신 식약처 조회는 등록 응답과 분리해 별도 스레드에서 수행한다.
    from app.services.dur_sync_service import start_background_user_dur_refresh

    try:
        refresh_started = start_background_user_dur_refresh(user_id)
    except Exception:
        # The registration is already committed; refresh is not registration.
        refresh_started = False
    return {
        "prescription_id": prescription_id,
        "user_id": user_id,
        "registered": True,
        "duplicate": duplicate,
        "items": items,
        "medicine_codes": list(
            dict.fromkeys(
                str(item.get("medicine_code") or "").strip()
                for item in items
                if str(item.get("medicine_code") or "").strip()
            )
        ),
        "schedule_count": sum(len(item.get("schedules") or []) for item in items),
        "dur_result": dur_result,
        "dur_refresh_started": refresh_started,
    }


def _can_register_confirm_item(item: PrescriptionConfirmItem) -> bool:
    code = (item.medicine_code or "").strip()
    if not code or code.upper().startswith("OCR-"):
        return False
    if (item.match_status or "").upper() == "UNMATCHED":
        return False
    return True


def confirm_prescription(request: PrescriptionConfirmRequest) -> dict:
    """확인 화면에서 「이대로 등록하기」 할 때 실제 복용약·스케줄을 넣는다."""
    if not request.items:
        raise HTTPException(status_code=422, detail="등록할 약이 없습니다.")

    conn = get_connection()
    try:
        cursor = conn.cursor()
        purge_ocr_placeholder_rows(conn)
        user = cursor.execute(
            "SELECT id FROM users WHERE id = ?", (request.user_id,)
        ).fetchone()
        if not user:
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")

        register_items: list[tuple[PrescriptionConfirmItem, dict]] = []
        for item in request.items:
            if not _can_register_confirm_item(item):
                continue
            code = (item.medicine_code or "").strip()
            exists = cursor.execute(
                """
                SELECT medicine_code, product_name FROM medicines
                WHERE medicine_code = ? AND medicine_code NOT LIKE 'OCR-%'
                """,
                (code,),
            ).fetchone()
            if not exists:
                continue
            register_items.append((item, dict(exists)))
        if not register_items:
            raise HTTPException(
                status_code=422,
                detail="공식 목록에서 확인된 약만 등록할 수 있습니다.",
            )

        fingerprint_payload = {
            "user_id": request.user_id,
            "prescribed_date": request.prescribed_date,
            "hospital_name": request.hospital_name,
            "items": [
                {
                    "medicine_code": item.medicine_code,
                    "dosage": item.dosage,
                    "unit": item.unit,
                    "dose_amount": item.dose_amount,
                    "dose_unit": item.dose_unit,
                    "frequency_per_day": item.frequency_per_day,
                    "duration_days": item.duration_days,
                    "administration_times": list(item.administration_times or []),
                    "ocr_drug_name_raw": item.ocr_drug_name_raw,
                }
                for item, _exists in register_items
            ],
        }
        registration_fingerprint = hashlib.sha256(
            json.dumps(
                fingerprint_payload,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        duplicate = cursor.execute(
            """
            SELECT id FROM prescriptions
            WHERE user_id = ? AND registration_fingerprint = ?
            LIMIT 1
            """,
            (request.user_id, registration_fingerprint),
        ).fetchone()
        if duplicate:
            restored_items = _reactivate_duplicate_prescription(
                cursor,
                user_id=request.user_id,
                prescription_id=duplicate["id"],
            )
            conn.commit()
            return _registration_result(
                prescription_id=duplicate["id"],
                user_id=request.user_id,
                items=restored_items,
                duplicate=True,
            )

        prescription_id = str(uuid.uuid4())
        cursor.execute(
            """
            INSERT INTO prescriptions (
                id, user_id, source_type, hospital_name, pharmacy_name,
                prescribed_date, expire_date, original_image_path, ocr_text,
                registration_fingerprint
            ) VALUES (?, ?, 'OCR', ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                prescription_id,
                request.user_id,
                request.hospital_name,
                request.pharmacy_name,
                request.prescribed_date,
                request.expire_date,
                None,
                request.ocr_text,
                registration_fingerprint,
            ),
        )

        created_items = []
        for item, exists in register_items:
            code = (item.medicine_code or "").strip()
            _prepare_detail_without_blocking(cursor, code)
            official_name = str(exists["product_name"] or item.drug_name).strip()
            take_dosage = _validated_confirm_dosage(item, official_name)
            dose_amount, dose_unit = split_take_amount(take_dosage)
            registration_date = date.today().isoformat()
            schedule_dates = _schedule_dates(registration_date, None, item.duration_days)
            if schedule_dates:
                medicine_start_date = schedule_dates[0].isoformat()
                medicine_end_date = schedule_dates[-1].isoformat()
            else:
                medicine_start_date = registration_date
                medicine_end_date = None

            cursor.execute(
                """
                INSERT INTO prescription_items (
                    prescription_id, medicine_code, ocr_drug_name,
                    ocr_drug_name_raw, ocr_field_confidences,
                    dosage_form, administration_route, dosage, unit,
                    frequency_per_day, times_per_take, duration_days,
                    administration_times, match_status, easy_explanation,
                    warning_note
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    prescription_id,
                    code,
                    official_name,
                    item.ocr_drug_name_raw,
                    json.dumps(item.ocr_field_confidences, ensure_ascii=False),
                    item.dosage_form,
                    item.administration_route,
                    take_dosage,
                    item.dose_unit or item.unit,
                    item.frequency_per_day,
                    item.times_per_take,
                    item.duration_days,
                    json.dumps(item.administration_times, ensure_ascii=False),
                    item.match_status or "MATCHED",
                    item.easy_explanation,
                    item.warning_note,
                ),
            )
            item_id = cursor.lastrowid
            previous_rows = cursor.execute(
                """
                SELECT id FROM user_medicines
                WHERE user_id = ? AND medicine_code = ?
                  AND COALESCE(is_active, 1) = 1
                """,
                (request.user_id, code),
            ).fetchall()
            previous_ids = [row["id"] for row in previous_rows]
            if previous_ids:
                placeholders = ",".join("?" for _ in previous_ids)
                cursor.execute(
                    f"DELETE FROM medication_schedules WHERE user_medicine_id IN ({placeholders})",
                    previous_ids,
                )
                cursor.execute(
                    f"UPDATE user_medicines SET is_active = 0, status = 'PAST' WHERE id IN ({placeholders})",
                    previous_ids,
                )
            cursor.execute(
                """
                INSERT INTO user_medicines (
                    user_id, medicine_code, prescription_item_id, start_date,
                    end_date, dosage, dose_amount, dose_unit,
                    frequency_per_day, administration_times,
                    is_active, status, last_prescribed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'ACTIVE', ?)
                """,
                (
                    request.user_id,
                    code,
                    item_id,
                    medicine_start_date,
                    medicine_end_date,
                    take_dosage,
                    float(dose_amount) if dose_amount is not None else None,
                    dose_unit,
                    item.frequency_per_day,
                    json.dumps(item.administration_times, ensure_ascii=False),
                    registration_date,
                ),
            )
            user_medicine_id = cursor.lastrowid
            ocr_item = OCRMedicineItem(
                drug_name=official_name,
                medicine_code=code,
                dosage=take_dosage,
                unit=item.unit,
                frequency_per_day=item.frequency_per_day,
                times_per_take=item.times_per_take,
                duration_days=item.duration_days,
                administration_times=list(item.administration_times or []),
                easy_explanation=item.easy_explanation,
                warning_note=item.warning_note,
            )
            logger.warning(
                "[PRESCRIPTION_DIAG] duration_days=%s frequency_per_day=%s "
                "administration_times_count=%s",
                item.duration_days,
                item.frequency_per_day,
                len(item.administration_times or []),
            )
            schedules = _create_medication_schedules(
                cursor,
                user_id=request.user_id,
                user_medicine_id=user_medicine_id,
                prescribed_date=registration_date,
                expire_date=None,
                item=ocr_item,
            )
            logger.warning(
                "[PRESCRIPTION_DIAG] schedule_count=%s",
                len(schedules),
            )
            created_items.append(
                {
                    "id": item_id,
                    "user_medicine_id": user_medicine_id,
                    "medicine_code": code,
                    "drug_name": official_name,
                    "match_status": item.match_status or "MATCHED",
                    "frequency_per_day": item.frequency_per_day,
                    "duration_days": item.duration_days,
                    "schedules": schedules,
                }
            )

        conn.commit()
        return _registration_result(
            prescription_id=prescription_id,
            user_id=request.user_id,
            items=created_items,
        )
    except HTTPException:
        conn.rollback()
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def get_user_prescriptions(user_id: str) -> list[dict]:
    conn = get_connection()
    try:
        prescriptions = conn.execute(
            """
            SELECT * FROM prescriptions
            WHERE user_id = ?
            ORDER BY created_at DESC
            """,
            (user_id,),
        ).fetchall()
        result = []
        for prescription in prescriptions:
            data = dict(prescription)
            items = conn.execute(
                """
                SELECT pi.*, m.product_name, m.ingredient
                FROM prescription_items pi
                LEFT JOIN medicines m ON m.medicine_code = pi.medicine_code
                WHERE pi.prescription_id = ?
                ORDER BY pi.id
                """,
                (prescription["id"],),
            ).fetchall()
            data["items"] = [dict(item) for item in items]
            result.append(data)
        return result
    finally:
        conn.close()


def _prescription_user_medicines(cursor, user_id: str, prescription_id: str):
    owned = cursor.execute(
        "SELECT 1 FROM prescriptions WHERE id = ? AND user_id = ?",
        (prescription_id, user_id),
    ).fetchone()
    if not owned:
        return None
    return cursor.execute(
        """
        SELECT um.id, um.frequency_per_day, um.administration_times
        FROM user_medicines um
        JOIN prescription_items pi ON pi.id = um.prescription_item_id
        WHERE um.user_id = ?
          AND pi.prescription_id = ?
          AND COALESCE(um.is_active, 1) = 1
        """,
        (user_id, prescription_id),
    ).fetchall()


def _refresh_user_medicine_span(cursor, user_medicine_id: int) -> None:
    row = cursor.execute(
        """
        SELECT MIN(scheduled_date) AS first_day, MAX(scheduled_date) AS last_day
        FROM medication_schedules
        WHERE user_medicine_id = ?
        """,
        (user_medicine_id,),
    ).fetchone()
    first_day = row["first_day"] if row else None
    last_day = row["last_day"] if row else None
    if first_day:
        cursor.execute(
            """
            UPDATE user_medicines
            SET start_date = ?, end_date = ?
            WHERE id = ?
            """,
            (first_day, last_day, user_medicine_id),
        )
        return
    closed = (date.today() - timedelta(days=1)).isoformat()
    cursor.execute(
        "UPDATE user_medicines SET end_date = ? WHERE id = ?",
        (closed, user_medicine_id),
    )


def get_prescription_schedule_days(
    user_id: str,
    prescription_id: str,
    year: int | None = None,
    month: int | None = None,
) -> dict:
    """이번에 등록한 약의 약 있는 날만 돌려 준다. 먹었어요/빠뜨렸어요는 넣지 않는다."""
    today = date.today()
    year = int(year or today.year)
    month = int(month or today.month)
    if month < 1 or month > 12:
        raise HTTPException(status_code=422, detail="달 정보가 올바르지 않아요.")
    first = date(year, month, 1)
    last_day = monthrange(year, month)[1]

    conn = get_connection()
    try:
        user_exists = conn.execute(
            "SELECT 1 FROM users WHERE id = ?", (user_id,)
        ).fetchone() is not None
        if not user_exists:
            logger.warning("[SCHEDULE_DIAG] reason=user_not_found")
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")
        medicines = _prescription_user_medicines(conn, user_id, prescription_id)
        if medicines is None:
            logger.warning(
                "[SCHEDULE_DIAG] reason=prescription_not_found_or_not_owned"
            )
            raise HTTPException(status_code=404, detail="처방전을 찾지 못했어요.")
        um_ids = [row["id"] for row in medicines]
        on_dates: set[date] = set()
        if um_ids:
            placeholders = ",".join("?" for _ in um_ids)
            rows = conn.execute(
                f"""
                SELECT DISTINCT scheduled_date
                FROM medication_schedules
                WHERE user_id = ?
                  AND user_medicine_id IN ({placeholders})
                """,
                (user_id, *um_ids),
            ).fetchall()
            for row in rows:
                try:
                    on_dates.add(date.fromisoformat(str(row["scheduled_date"])))
                except ValueError:
                    continue
        has_times = any(_clock_times_from_user_medicine(row) for row in medicines)
        days = []
        for day_n in range(1, last_day + 1):
            current = date(year, month, day_n)
            days.append(
                {
                    "day": day_n,
                    "on": current in on_dates,
                    "is_today": current == today,
                }
            )
        total_on = len(on_dates)
        logger.warning(
            "[SCHEDULE_DIAG] user_exists=true "
            "prescription_exists_for_user=true on_count=%s",
            total_on,
        )
        headline = (
            "투약일수를 확인해 주세요"
            if total_on == 0
            else f"오늘부터 {total_on}일, 이 약을 드시는 날이에요"
        )
        return {
            "prescription_id": prescription_id,
            "year": year,
            "month": month,
            "leading_blanks": first.weekday(),
            "headline": headline,
            "has_times": has_times,
            "on_count": total_on,
            "days": days,
        }
    finally:
        conn.close()


def toggle_prescription_schedule_day(
    user_id: str,
    prescription_id: str,
    scheduled_date: str,
) -> dict:
    """표시된 날을 빼거나, 빈 날에 이 처방의 횟수·시각을 붙인다."""
    try:
        target = date.fromisoformat(str(scheduled_date or "").strip())
    except ValueError:
        raise HTTPException(status_code=422, detail="날짜가 올바르지 않아요.")

    conn = get_connection()
    try:
        if not conn.execute(
            "SELECT 1 FROM users WHERE id = ?", (user_id,)
        ).fetchone():
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")
        medicines = _prescription_user_medicines(conn, user_id, prescription_id)
        if medicines is None:
            raise HTTPException(status_code=404, detail="처방전을 찾지 못했어요.")
        um_ids = [row["id"] for row in medicines]
        if not um_ids:
            raise HTTPException(status_code=422, detail="이 처방에 고칠 약이 없어요.")
        placeholders = ",".join("?" for _ in um_ids)
        existing = conn.execute(
            f"""
            SELECT 1 FROM medication_schedules
            WHERE user_id = ?
              AND user_medicine_id IN ({placeholders})
              AND scheduled_date = ?
            LIMIT 1
            """,
            (user_id, *um_ids, target.isoformat()),
        ).fetchone()
        if existing:
            conn.execute(
                f"""
                DELETE FROM medication_schedules
                WHERE user_id = ?
                  AND user_medicine_id IN ({placeholders})
                  AND scheduled_date = ?
                """,
                (user_id, *um_ids, target.isoformat()),
            )
        else:
            added = 0
            for row in medicines:
                for scheduled_time in _clock_times_from_user_medicine(row):
                    inserted = conn.execute(
                        """
                        INSERT OR IGNORE INTO medication_schedules (
                            user_id, user_medicine_id, scheduled_date,
                            scheduled_time, time_slot, status
                        ) VALUES (?, ?, ?, ?, ?, 'PENDING')
                        """,
                        (
                            user_id,
                            row["id"],
                            target.isoformat(),
                            scheduled_time,
                            _time_slot_for_clock(scheduled_time),
                        ),
                    )
                    added += inserted.rowcount
            if added == 0:
                raise HTTPException(
                    status_code=422,
                    detail="하루 복용 횟수를 확인해 주세요.",
                )
        for um_id in um_ids:
            _refresh_user_medicine_span(conn, um_id)
        conn.commit()
    except HTTPException:
        conn.rollback()
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    return get_prescription_schedule_days(
        user_id,
        prescription_id,
        target.year,
        target.month,
    )
