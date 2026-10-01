import json
import logging
import sqlite3
import uuid
from collections import defaultdict
from datetime import date

from fastapi import HTTPException

from app.database import get_connection
from app.models.schemas import DurAnalyzeRequest
from app.services.pharmacist.dur_why import (
    enrich_matches,
    official_cause,
    why_easy_for,
    with_together_opener,
)
from app.services.pharmacist.efficacy_display import display_efficacy_text
from app.services.pharmacist.ingredient import (
    ingredient_keys,
    is_usable_ingredient,
    normalize_ingredient,
    primary_ingredient_keys,
)


logger = logging.getLogger(__name__)


HIGH_TYPES = {"병용금기", "중복성분", "효능군중복"}
MEDIUM_TYPES = {"연령금기", "임부금기"}
OFFICIAL_DUR_TYPES = {"병용금기", "연령금기", "임부금기", "효능군중복"}
ALL_CHECK_TYPES = OFFICIAL_DUR_TYPES | {"중복성분"}


def _official_reason(value: str | None, fallback: str) -> str:
    return display_efficacy_text(value) or (value or "").strip() or fallback


def _normalize(value: str | None) -> str:
    return normalize_ingredient(value)


def _is_usable_ingredient(medicine) -> bool:
    return is_usable_ingredient(medicine["ingredient"], medicine["product_name"])


def _grouped_hit(grouped: dict, needle: str | None) -> bool:
    """용량 정규화 후 정확 일치만. (암로디핀⊂에스암로디핀 같은 포함 오탐 방지)"""
    key = _normalize(needle)
    if not key or len(key) < 2:
        return False
    return key in grouped


def _grouped_rows(grouped: dict, needle: str | None) -> list:
    key = _normalize(needle)
    if not key or key not in grouped:
        return []
    return list(grouped[key])


def _risk_type(value: str | None) -> str:
    normalized = _normalize(value)
    mappings = {
        "병용금기": "병용금기",
        "combination": "병용금기",
        "contraindicatedcombination": "병용금기",
        "중복성분": "중복성분",
        "duplicate": "중복성분",
        "duplicateingredient": "중복성분",
        "효능군중복": "효능군중복",
        "efficacyduplicate": "효능군중복",
        "연령금기": "연령금기",
        "age": "연령금기",
        "agecontraindication": "연령금기",
        "임부금기": "임부금기",
        "pregnancy": "임부금기",
        "pregnancycontraindication": "임부금기",
    }
    return mappings.get(normalized, value or "성분주의")


def _age_from_birth_date(value: str | None) -> int | None:
    if not value:
        return None
    try:
        born = date.fromisoformat(value)
    except ValueError:
        return None
    today = date.today()
    return today.year - born.year - ((today.month, today.day) < (born.month, born.day))


def analyze_dur(
    request: DurAnalyzeRequest,
    *,
    persist: bool = True,
    refresh: bool | None = None,
) -> dict:
    if request.medicine_codes:
        _cache_missing_official_medicines(request.medicine_codes)
    conn = get_connection()
    try:
        cursor = conn.cursor()
        user = cursor.execute(
            "SELECT id, birth_date, gender, is_pregnant FROM users WHERE id = ?",
            (request.user_id,),
        ).fetchone()
        if not user:
            raise HTTPException(status_code=404, detail="사용자가 없습니다.")

        medicines = _load_medicines_with_metadata(cursor, request)
        if not medicines:
            empty_by_type = _group_by_type([])
            return {
                "risk_result_id": None,
                "analysis_id": None,
                "user_id": request.user_id,
                "risk_level": "UNKNOWN",
                "assessment_status": "INCOMPLETE",
                "analysis_complete": False,
                "has_risk": False,
                "total_matches": 0,
                "total_count": 0,
                "representative_type": None,
                "message": "살펴볼 등록 약이 아직 없어요.",
                "by_type": empty_by_type,
                "ingredients": [],
                "medicine_names": [],
                "matches": [],
                "incomplete": True,
                "incomplete_reasons": ["살펴볼 등록 약이 아직 없어요."],
                "incomplete_types": sorted(ALL_CHECK_TYPES),
                "skipped_medicine_names": [],
                "taboo_row_count": 0,
                "dur_sync_status": "no_medicines",
                "dur_sync_fetched": 0,
                "dur_sync_upserted": 0,
            }

        ingredients = [
            row["ingredient"]
            for row in medicines
            if _is_usable_ingredient(row)
        ]
        dur_sync_status = "skipped"
        dur_sync_upserted = 0
        dur_sync_fetched = 0
        do_refresh = persist if refresh is None else refresh
        if ingredients and do_refresh:
            from app.services.dur_sync_service import refresh_dur_for_ingredients

            dur_sync = refresh_dur_for_ingredients(ingredients)
            dur_sync_status = str(dur_sync.get("status") or "failed")
            dur_sync_upserted = int(dur_sync.get("upserted") or 0)
            dur_sync_fetched = int(dur_sync.get("fetched") or 0)

        lookup_grouped = defaultdict(list)
        primary_grouped = defaultdict(list)
        for medicine in medicines:
            if not _is_usable_ingredient(medicine):
                continue
            keys = ingredient_keys(medicine["ingredient"])
            if not keys:
                continue
            for primary in primary_ingredient_keys(medicine["ingredient"]):
                primary_grouped[primary].append(medicine)
            for key in keys:
                lookup_grouped[key].append(medicine)

        age = _age_from_birth_date(user["birth_date"])
        # 요청값 우선, 없으면 회원 프로필 is_pregnant
        is_pregnant = request.is_pregnant
        if is_pregnant is None:
            try:
                is_pregnant = bool(user["is_pregnant"])
            except (KeyError, IndexError, TypeError):
                is_pregnant = None
        matches = _duplicate_matches(primary_grouped)
        taboo_rows = [
            row
            for row in cursor.execute("SELECT * FROM dur_taboo").fetchall()
            if not _is_deleted_taboo(row)
        ]
        official_matches = _taboo_matches(
            taboo_rows,
            lookup_grouped,
            age=age,
            is_pregnant=is_pregnant,
            split_medicine_codes=True,
        )
        matches.extend(official_matches)
        matches.extend(
            _efficacy_duplicate_matches(taboo_rows, lookup_grouped)
        )

        # Legacy ingredient rows remain usable when no structured DUR type matched.
        if not official_matches:
            matches.extend(
                _legacy_matches(taboo_rows, lookup_grouped)
            )

        matches = _deduplicate_matches(matches)
        matches = enrich_matches(matches, medicines)
        matches = [_without_internal_match_fields(match) for match in matches]
        risk_level = _risk_level(matches)
        by_type = _group_by_type(matches)
        has_risk = len(matches) > 0
        analysis_id = str(uuid.uuid4())
        skipped_ingredient = [
            str(row["product_name"] or row["medicine_code"])
            for row in medicines
            if not _is_usable_ingredient(row)
        ]
        checkable_n = len(medicines) - len(skipped_ingredient)
        taboo_n = len(taboo_rows)
        incomplete_reasons = []
        incomplete_types: set[str] = set()
        if checkable_n == 0:
            incomplete_reasons.append("등록 약의 성분 정보가 없어 함께먹기 검사를 할 수 없어요.")
            incomplete_types.update(ALL_CHECK_TYPES)
        elif skipped_ingredient:
            incomplete_reasons.append(
                f"{len(skipped_ingredient)}개 약은 성분을 몰라 검사에서 빠졌어요."
            )
            incomplete_types.update(ALL_CHECK_TYPES)
        if checkable_n > 0:
            if dur_sync_status == "skipped" and taboo_n > 0:
                # refresh=False means this request intentionally avoided a live
                # network sync.  Existing stored DUR reference rows are still
                # usable, so the absence of an in-request sync is not itself an
                # incomplete analysis.
                dur_sync_status = "stored"
            elif dur_sync_status == "skipped":
                incomplete_reasons.append(
                    "저장된 식약처 함께먹기 기준이 없어 검사를 끝내지 못했어요."
                )
                incomplete_types.update(OFFICIAL_DUR_TYPES)
            elif dur_sync_status == "skipped_missing_key":
                incomplete_reasons.append(
                    "식약처 함께먹기 조회 키가 없어 최신 병용·금기 기준을 확인하지 못했어요."
                )
                incomplete_types.update(OFFICIAL_DUR_TYPES)
            elif dur_sync_status in {"failed", "partial"}:
                incomplete_reasons.append(
                    "식약처 함께먹기 기준을 전부 받아오지 못했어요. 잠시 후 다시 살펴봐 주세요."
                )
                incomplete_types.update(OFFICIAL_DUR_TYPES)
            elif dur_sync_status == "disabled":
                incomplete_reasons.append(
                    "최신 식약처 함께먹기 기준 조회가 꺼져 있어 검사를 끝내지 못했어요."
                )
                incomplete_types.update(OFFICIAL_DUR_TYPES)
            elif dur_sync_status == "no_queries":
                incomplete_reasons.append(
                    "약 성분을 식약처 조회용 이름으로 바꾸지 못해 검사를 끝내지 못했어요."
                )
                incomplete_types.update(OFFICIAL_DUR_TYPES)
        if age is None:
            incomplete_reasons.append("생년월일이 없어 나이 관련 주의는 살펴보지 못했어요.")
            incomplete_types.add("연령금기")
        incomplete = bool(incomplete_reasons)
        assessment_status = (
            "RISK_FOUND" if has_risk else "INCOMPLETE" if incomplete else "SAFE"
        )
        if incomplete and not has_risk:
            risk_level = "UNKNOWN"
        if has_risk:
            description = f"함께 먹을 때 주의가 {len(matches)}건 있어요."
            if incomplete:
                description += " 일부 검사는 끝까지 확인하지 못했어요."
        elif incomplete:
            description = " ".join(incomplete_reasons)
        else:
            description = "지금 등록된 약끼리, 특별한 함께먹기 주의는 없어요."
        risk_result_id = None
        if persist:
            cursor.execute(
                """
                INSERT INTO risk_results (
                    user_id, risk_level, description, analyzed_ingredients,
                    analysis_id, risk_type, total_matches, matches_json,
                    assessment_status, incomplete_reasons_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    request.user_id,
                    risk_level,
                    description,
                    json.dumps(ingredients, ensure_ascii=False),
                    analysis_id,
                    matches[0]["type"] if matches else None,
                    len(matches),
                    json.dumps(matches, ensure_ascii=False),
                    assessment_status,
                    json.dumps(incomplete_reasons, ensure_ascii=False),
                ),
            )
            risk_result_id = cursor.lastrowid
            conn.commit()
        return {
            "risk_result_id": risk_result_id,
            "analysis_id": analysis_id,
            "user_id": request.user_id,
            "risk_level": risk_level,
            "assessment_status": assessment_status,
            "analysis_complete": not incomplete,
            "has_risk": has_risk,
            "total_matches": len(matches),
            "total_count": len(matches),
            "representative_type": matches[0]["type"] if matches else None,
            "message": description,
            "by_type": by_type,
            "ingredients": ingredients,
            "medicine_names": [row["product_name"] for row in medicines],
            "matches": matches,
            "incomplete": incomplete,
            "incomplete_reasons": incomplete_reasons,
            "incomplete_types": sorted(incomplete_types),
            "skipped_medicine_names": skipped_ingredient,
            "taboo_row_count": taboo_n,
            "dur_sync_status": dur_sync_status,
            "dur_sync_fetched": dur_sync_fetched,
            "dur_sync_upserted": dur_sync_upserted,
        }
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def _cache_missing_official_medicines(medicine_codes: list[str]) -> None:
    """Cache verified catalog rows without registering them to a user."""

    codes = list(
        dict.fromkeys(
            str(code or "").strip()
            for code in medicine_codes
            if str(code or "").strip()
        )
    )
    if not codes:
        return

    conn = get_connection()
    try:
        placeholders = ",".join("?" for _ in codes)
        existing_codes = {
            str(row["medicine_code"])
            for row in conn.execute(
                f"SELECT medicine_code, product_name, ingredient FROM medicines "
                f"WHERE medicine_code IN ({placeholders})",
                codes,
            ).fetchall()
            if is_usable_ingredient(row["ingredient"], row["product_name"])
        }
    finally:
        conn.close()

    from app.services.external_api_service import fetch_e_drug_info
    from app.services.mfds_drug_permission.client import fetch_permission_detail
    from app.services.mfds_drug_permission.db import (
        find_permission_product_by_item_seq,
        product_to_medicine,
    )

    for code in codes:
        if code in existing_codes:
            continue
        try:
            def verified(candidate) -> bool:
                if not isinstance(candidate, dict):
                    return False
                official_code = str(candidate.get("medicine_code") or "").strip()
                official_name = str(
                    candidate.get("product_name")
                    or candidate.get("medicine_name")
                    or ""
                ).strip()
                return bool(
                    official_code == code
                    and official_name
                    and is_usable_ingredient(
                        candidate.get("ingredient"),
                        official_name,
                    )
                )

            permission_row = find_permission_product_by_item_seq(code)
            medicine = product_to_medicine(permission_row) if permission_row else None
            if not verified(medicine):
                try:
                    detail = fetch_permission_detail(item_seq=code)
                except Exception:
                    detail = None
                if isinstance(detail, dict):
                    medicine = product_to_medicine(
                        {
                            "item_seq": detail.get("ITEM_SEQ"),
                            "item_name": detail.get("ITEM_NAME"),
                            "entp_name": detail.get("ENTP_NAME"),
                            "main_item_ingr": detail.get("MAIN_ITEM_INGR"),
                            "item_ingr_name": detail.get("ITEM_INGR_NAME"),
                            "ingr_name": detail.get("INGR_NAME"),
                            "material_name": detail.get("MATERIAL_NAME"),
                            "ee_doc_data": detail.get("EE_DOC_DATA"),
                            "ud_doc_data": detail.get("UD_DOC_DATA"),
                            "nb_doc_data": detail.get("NB_DOC_DATA"),
                            "storage_method": detail.get("STORAGE_METHOD"),
                            "big_prdt_img_url": detail.get("BIG_PRDT_IMG_URL"),
                        }
                    )
            if not verified(medicine):
                medicine = fetch_e_drug_info(medicine_code=code)
            if not verified(medicine):
                continue
            _upsert_dur_catalog_medicine(medicine)
        except Exception as error:
            logger.warning(
                "DUR official medicine cache failed error_type=%s",
                type(error).__name__,
            )


def _upsert_dur_catalog_medicine(medicine: dict) -> None:
    """Persist verified reference data only; never create a user-medicine row."""

    code = str(medicine.get("medicine_code") or "").strip()
    name = str(
        medicine.get("product_name") or medicine.get("medicine_name") or ""
    ).strip()
    ingredient = str(medicine.get("ingredient") or "").strip()
    if not code or not name or not is_usable_ingredient(ingredient, name):
        return
    precautions = medicine.get("precautions") or medicine.get("cautions") or ""
    conn = get_connection()
    try:
        conn.execute(
            """
            INSERT INTO medicines (
                medicine_code, product_name, ingredient, manufacturer,
                efficacy, usage, precautions, image_url
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(medicine_code) DO UPDATE SET
                product_name = excluded.product_name,
                ingredient = excluded.ingredient,
                manufacturer = COALESCE(
                    NULLIF(trim(excluded.manufacturer), ''), medicines.manufacturer
                ),
                efficacy = COALESCE(
                    NULLIF(trim(excluded.efficacy), ''), medicines.efficacy
                ),
                usage = COALESCE(NULLIF(trim(excluded.usage), ''), medicines.usage),
                precautions = COALESCE(
                    NULLIF(trim(excluded.precautions), ''), medicines.precautions
                ),
                image_url = COALESCE(
                    NULLIF(trim(excluded.image_url), ''), medicines.image_url
                ),
                updated_at = CURRENT_TIMESTAMP
            """,
            (
                code,
                name,
                ingredient,
                medicine.get("manufacturer"),
                medicine.get("efficacy"),
                medicine.get("usage"),
                precautions if isinstance(precautions, str) else str(precautions),
                medicine.get("image_url"),
            ),
        )
        conn.commit()
    finally:
        conn.close()


def analyze_dur_consultation(
    *,
    user_id: str,
    selected_medicine: dict,
    risk_types: set[str],
) -> dict:
    """Run an official DUR check without persisting user medication or results."""
    conn = get_connection()
    try:
        cursor = conn.cursor()
        user = cursor.execute(
            "SELECT id, birth_date, gender, is_pregnant FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
        if not user:
            user = {
                "id": user_id,
                "birth_date": None,
                "gender": None,
                "is_pregnant": None,
            }

        medicine_code = str(selected_medicine.get("medicine_code") or "").strip()
        product_name = str(selected_medicine.get("product_name") or "").strip()
        ingredient = selected_medicine.get("ingredient")
        consultation_medicine = {
            "medicine_code": medicine_code,
            "product_name": product_name,
            "ingredient": ingredient,
        }
        ingredient_usable = _is_usable_ingredient(consultation_medicine)
        ingredient_key_count = len(ingredient_keys(ingredient))
        if not medicine_code or not product_name or not ingredient_usable:
            logger.warning(
                "DUR consultation diagnostic risk_types=%s selected=%s "
                "ingredient_usable=%s ingredient_key_count=%d "
                "active_medicine_count=not_loaded sync_status=not_started "
                "status=missing reason=official_medicine_unavailable match_count=0",
                sorted(risk_types),
                bool(medicine_code and product_name),
                ingredient_usable,
                ingredient_key_count,
            )
            return {
                "status": "missing",
                "items": [],
                "scope": "consultation",
                "reason": "official_medicine_unavailable",
            }

        pairwise_types = {"병용금기", "효능군중복", "중복성분"}
        medicines = []
        active_medicine_count = 0
        if risk_types & pairwise_types:
            medicines.extend(
                dict(row)
                for row in _load_medicines(
                    cursor,
                    DurAnalyzeRequest(user_id=user_id, medicine_codes=[]),
                )
            )
            active_medicine_count = len(medicines)
        medicines.append(consultation_medicine)
        medicines = list(
            {
                medicine["medicine_code"]: medicine
                for medicine in medicines
                if medicine.get("medicine_code")
            }.values()
        )

        age = _age_from_birth_date(user["birth_date"])
        try:
            pregnancy_value = user["is_pregnant"]
            is_pregnant = (
                bool(pregnancy_value) if pregnancy_value is not None else None
            )
        except (KeyError, IndexError, TypeError):
            is_pregnant = None

        ingredients = [
            medicine["ingredient"]
            for medicine in medicines
            if _is_usable_ingredient(medicine)
        ]
        from app.services.dur_sync_service import refresh_dur_for_ingredients

        official_risk_types = risk_types & {
            "병용금기",
            "연령금기",
            "임부금기",
            "효능군중복",
        }
        sync_result = (
            refresh_dur_for_ingredients(
                ingredients,
                risk_types=official_risk_types,
                force_refresh=True,
            )
            if official_risk_types
            else {"status": "ok", "fetched": 0, "upserted": 0}
        )
        taboo_rows = [
            row
            for row in cursor.execute("SELECT * FROM dur_taboo").fetchall()
            if not _is_deleted_taboo(row)
        ]
        if official_risk_types and sync_result.get("status") != "ok":
            logger.warning(
                "DUR consultation diagnostic risk_types=%s selected=true "
                "ingredient_usable=true ingredient_key_count=%d "
                "active_medicine_count=%d sync_status=%s "
                "status=missing reason=dur_data_unavailable match_count=0",
                sorted(risk_types),
                ingredient_key_count,
                active_medicine_count,
                sync_result.get("status"),
            )
            return {
                "status": "missing",
                "items": [],
                "scope": "consultation",
                "reason": "dur_data_unavailable",
            }

        lookup_grouped = defaultdict(list)
        primary_grouped = defaultdict(list)
        selected_lookup_grouped = defaultdict(list)
        for medicine in medicines:
            if not _is_usable_ingredient(medicine):
                continue
            keys = ingredient_keys(medicine["ingredient"])
            if not keys:
                continue
            for primary in primary_ingredient_keys(medicine["ingredient"]):
                primary_grouped[primary].append(medicine)
            for key in keys:
                lookup_grouped[key].append(medicine)
        for key in ingredient_keys(consultation_medicine["ingredient"]):
            selected_lookup_grouped[key].append(consultation_medicine)

        taboo_selected_ingredient_count = sum(
            1
            for row in taboo_rows
            if _risk_type(row["taboo_type"]) in risk_types
            and (
                _grouped_hit(selected_lookup_grouped, row["ingredient_a"])
                or _grouped_hit(selected_lookup_grouped, row["ingredient_b"])
            )
        )
        duplicate_matches = _duplicate_matches(primary_grouped)
        official_matches = _taboo_matches(
            taboo_rows,
            lookup_grouped,
            age=age,
            is_pregnant=is_pregnant,
            include_official_criteria=True,
        )
        efficacy_duplicate_matches = _efficacy_duplicate_matches(
            taboo_rows,
            lookup_grouped,
        )
        candidate_matches = [
            *duplicate_matches,
            *official_matches,
            *efficacy_duplicate_matches,
        ]
        if not official_matches:
            candidate_matches.extend(_legacy_matches(taboo_rows, lookup_grouped))
        deduplicated_matches = _deduplicate_matches(candidate_matches)
        requested_type_matches = [
            match
            for match in deduplicated_matches
            if match.get("type") in risk_types
        ]
        relevant_matches = [
            match
            for match in requested_type_matches
            if _match_involves_consultation_medicine(
                match,
                consultation_medicine,
            )
        ]
        matches = [
            _without_internal_match_fields(match)
            for match in relevant_matches
        ]
        checked_types = set(risk_types)
        if age is None:
            checked_types.discard("연령금기")
        if is_pregnant is None:
            checked_types.discard("임부금기")
        matched_types = {
            str(match.get("type") or "").strip()
            for match in matches
            if str(match.get("type") or "").strip()
        }
        logger.warning(
            "DUR consultation diagnostic risk_types=%s selected=true "
            "ingredient_usable=true ingredient_key_count=%d "
            "active_medicine_count=%d sync_status=%s "
            "sync_fetched_count=%d sync_upserted_count=%d "
            "taboo_selected_ingredient_count=%d "
            "duplicate_candidate_count=%d official_candidate_count=%d "
            "efficacy_duplicate_candidate_count=%d "
            "requested_type_filtered_count=%d "
            "consultation_relevance_before_count=%d "
            "consultation_relevance_after_count=%d "
            "status=current reason=None final_match_count=%d match_count=%d",
            sorted(risk_types),
            ingredient_key_count,
            active_medicine_count,
            sync_result.get("status"),
            int(sync_result.get("fetched") or 0),
            int(sync_result.get("upserted") or 0),
            taboo_selected_ingredient_count,
            len(duplicate_matches),
            len(official_matches),
            len(efficacy_duplicate_matches),
            len(requested_type_matches),
            len(requested_type_matches),
            len(relevant_matches),
            len(matches),
            len(matches),
        )
        return {
            "status": "current",
            "items": matches,
            "scope": "consultation",
            "reason": None,
            "checked_types": sorted(checked_types),
            "zero_result_types": sorted(checked_types - matched_types),
            "user_context": {
                "age_known": age is not None,
                "pregnancy_known": is_pregnant is not None,
                "pregnancy_status": (
                    "pregnant"
                    if is_pregnant is True
                    else "not_pregnant"
                    if is_pregnant is False
                    else "unknown"
                ),
            },
        }
    finally:
        conn.close()


def _match_involves_consultation_medicine(
    match: dict,
    medicine: dict,
) -> bool:
    medicine_code = str(medicine.get("medicine_code") or "")
    related_codes = {str(code) for code in match.get("_medicine_codes") or []}
    if related_codes:
        return medicine_code in related_codes

    product_name = str(medicine.get("product_name") or "")
    names = [
        str(name)
        for key in ("medicine_names_a", "medicine_names_b")
        for name in (match.get(key) or [])
    ]
    if product_name and product_name in names:
        return True
    consultation_keys = set(ingredient_keys(medicine.get("ingredient")))
    match_keys = set(match.get("_ingredient_keys") or [])
    if consultation_keys and match_keys:
        return bool(consultation_keys & match_keys)
    return bool(product_name and product_name in str(match.get("reason") or ""))


def _without_internal_match_fields(match: dict) -> dict:
    return {key: value for key, value in match.items() if not key.startswith("_")}


def _load_medicines(cursor, request: DurAnalyzeRequest):
    """Load only the medicine identity needed by DUR matching and consultation."""
    if request.medicine_codes:
        # 요청 코드도 중복 제거 (같은 약 여러 번 넣어도 한 번만)
        codes = list(dict.fromkeys(request.medicine_codes))
        placeholders = ",".join("?" for _ in codes)
        return cursor.execute(
            f"""
            SELECT medicine_code, product_name, ingredient
            FROM medicines WHERE medicine_code IN ({placeholders})
            """,
            codes,
        ).fetchall()
    # OCR을 여러 번 하면 같은 약이 user_medicines에 중복 쌓일 수 있음.
    # 충돌 검사에서는 약 코드당 1개만 본다 (가짜 '중복성분' 방지).
    return cursor.execute(
        """
        SELECT m.medicine_code, m.product_name, m.ingredient
        FROM medicines m
        WHERE m.medicine_code IN (
            SELECT DISTINCT um.medicine_code
            FROM user_medicines um
            WHERE um.user_id = ? AND um.is_active = 1
        )
        ORDER BY m.product_name
        """,
        (request.user_id,),
    ).fetchall()


def _load_medicines_with_metadata(cursor, request: DurAnalyzeRequest):
    """Load optional display metadata without coupling DUR matching to it."""
    try:
        if request.medicine_codes:
            codes = list(dict.fromkeys(request.medicine_codes))
            placeholders = ",".join("?" for _ in codes)
            return cursor.execute(
                f"""
                SELECT medicine_code, product_name, ingredient,
                       short_explanation, easy_category
                FROM medicines WHERE medicine_code IN ({placeholders})
                """,
                codes,
            ).fetchall()
        return cursor.execute(
            """
            SELECT m.medicine_code, m.product_name, m.ingredient,
                   m.short_explanation, m.easy_category
            FROM medicines m
            WHERE m.medicine_code IN (
                SELECT DISTINCT um.medicine_code
                FROM user_medicines um
                WHERE um.user_id = ? AND um.is_active = 1
            )
            ORDER BY m.product_name
            """,
            (request.user_id,),
        ).fetchall()
    except sqlite3.OperationalError as exc:
        logger.warning(
            "DUR medicine metadata unavailable error_type=%s",
            type(exc).__name__,
        )
        return _load_medicines(cursor, request)


def _duplicate_matches(grouped) -> list[dict]:
    matches = []
    for key, rows in grouped.items():
        if not key or len(rows) < 2:
            continue
        # 서로 다른 약 코드가 2개 이상일 때만 (같은 약 중복 등록은 제외)
        codes = {row["medicine_code"] for row in rows}
        if len(codes) < 2:
            continue
        ingredient = rows[0]["ingredient"]
        names = [row["product_name"] for row in rows]
        codes = [row["medicine_code"] for row in rows]
        matches.append(
            {
                "type": "중복성분",
                "ingredient_a": ingredient,
                "ingredient_b": ingredient,
                "medicine_names_a": names,
                "medicine_names_b": names,
                "_medicine_codes": sorted(codes),
                "_ingredient_keys": [key],
                "medicine_codes_a": codes,
                "medicine_codes_b": codes,
                "reason": (
                    f"같은 성분({ingredient})이 여러 약에 들어 있어요: {', '.join(names)}. "
                    "중복으로 드시는지 약국에 확인해 주세요."
                ),
                "source": "활성 복용약 성분 비교",
            }
        )
    return matches


def _is_deleted_taboo(row) -> bool:
    """식약처 DEL_YN=삭제/Y 행은 검사에서 제외."""
    raw = row["raw_json"] if "raw_json" in row.keys() else None
    if not raw:
        return False
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, json.JSONDecodeError):
        return False
    if not isinstance(data, dict):
        return False
    value = str(data.get("DEL_YN") or "").strip()
    upper = value.upper()
    return upper in {"Y", "삭제", "DELETE", "DELETED"} or value == "삭제"


def _effect_group_key(row) -> str | None:
    """효능군중복 그룹 키: ingredient_b(동기화 시 EFFECT_CODE) 또는 raw_json."""
    stored = row["ingredient_b"] if "ingredient_b" in row.keys() else None
    if stored and str(stored).strip():
        # 병용금기 ingredient_b 와 구분: 효능군만 이 함수를 씀
        return str(stored).strip()
    raw = row["raw_json"] if "raw_json" in row.keys() else None
    if not raw:
        return None
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    for key in ("EFFECT_CODE", "SERS_NAME", "CLASS_NAME"):
        value = data.get(key)
        if value is not None and str(value).strip():
            return str(value).strip()
    return None


def _efficacy_duplicate_matches(rows, grouped) -> list[dict]:
    """
    효능군중복: 같은 EFFECT_CODE 에 유저 약이 2개 이상 걸릴 때만 주의.
    (성분 목록 1건만 있어도 뜨던 오탐 방지)
    """
    by_group: dict[str, list] = defaultdict(list)
    for row in rows:
        if _risk_type(row["taboo_type"]) != "효능군중복":
            continue
        group = _effect_group_key(row)
        if not group:
            continue
        by_group[group].append(row)

    matches = []
    for group, taboo_rows in by_group.items():
        hit_meds = []
        seen_codes: set[str] = set()
        for taboo in taboo_rows:
            for medicine in _grouped_rows(grouped, taboo["ingredient_a"]):
                code = medicine["medicine_code"]
                if code in seen_codes:
                    continue
                seen_codes.add(code)
                hit_meds.append(medicine)
        if len(seen_codes) < 2:
            continue
        names = ", ".join(med["product_name"] for med in hit_meds)
        ingredient_names = [
            med["ingredient"] for med in hit_meds if med["ingredient"]
        ]
        reason = (
            f"{names} — 비슷한 효과({group}) 약이 겹쳐요. "
            "약국·병원에 확인해 주세요."
        )
        matches.append(
            {
                "type": "효능군중복",
                "ingredient_a": ingredient_names[0] if ingredient_names else group,
                "ingredient_b": (
                    ingredient_names[1] if len(ingredient_names) > 1 else None
                ),
                "medicine_names_a": [hit_meds[0]["product_name"]],
                "medicine_names_b": (
                    [hit_meds[1]["product_name"]] if len(hit_meds) > 1 else []
                ),
                "medicine_codes_a": [hit_meds[0]["medicine_code"]],
                "medicine_codes_b": (
                    [hit_meds[1]["medicine_code"]] if len(hit_meds) > 1 else []
                ),
                "reason": reason,
                "source": taboo_rows[0]["source"] or "식약처 DUR",
                "external_id": taboo_rows[0]["external_id"],
                "_medicine_codes": [med["medicine_code"] for med in hit_meds],
                "_ingredient_keys": sorted(
                    {
                        key
                        for med in hit_meds
                        for key in ingredient_keys(med["ingredient"])
                    }
                ),
            }
        )
    return matches


def _taboo_matches(
    rows,
    grouped,
    *,
    age: int | None,
    is_pregnant: bool | None,
    include_official_criteria: bool = False,
    split_medicine_codes: bool = False,
) -> list[dict]:
    matches = []
    for row in rows:
        risk_type = _risk_type(row["taboo_type"])
        # 효능군중복은 _efficacy_duplicate_matches 에서 그룹 단위로 처리
        if risk_type == "효능군중복":
            continue
        if risk_type not in HIGH_TYPES | MEDIUM_TYPES:
            continue
        if not _grouped_hit(grouped, row["ingredient_a"]):
            continue
        if risk_type == "병용금기":
            if not row["ingredient_b"] or not _grouped_hit(grouped, row["ingredient_b"]):
                continue
            # 한 알(복합제) 안 성분 두 개만으로 병용 오탐 나지 않게, 서로 다른 약 필요
            rows_a = _grouped_rows(grouped, row["ingredient_a"])
            rows_b = _grouped_rows(grouped, row["ingredient_b"])
            if not any(
                a["medicine_code"] != b["medicine_code"]
                for a in rows_a
                for b in rows_b
            ):
                continue
        if risk_type == "연령금기":
            min_age, max_age = _age_bounds_for_row(row)
            if not include_official_criteria and (
                age is None or not _age_is_restricted(age, min_age, max_age)
            ):
                continue
        if (
            risk_type == "임부금기"
            and not include_official_criteria
            and is_pregnant is not True
        ):
            continue
        # 사용자 약 이름을 이유에 붙여 화면에서 이해하기 쉽게
        rows_a = _grouped_rows(grouped, row["ingredient_a"])
        rows_b = _grouped_rows(grouped, row["ingredient_b"])
        products_a = [r["product_name"] for r in rows_a]
        products_b = [r["product_name"] for r in rows_b]
        official = row["description"] or "함께 먹을 때 주의가 필요해요."
        official = _official_reason(official, "함께 먹을 때 주의가 필요해요.")
        reason = official
        if products_a:
            reason = f"{', '.join(products_a)}" + (
                f" ↔ {', '.join(products_b)}" if products_b else ""
            ) + f" — {official}"
        codes_a = [r["medicine_code"] for r in rows_a]
        codes_b = [r["medicine_code"] for r in rows_b]
        medicine_codes = set(codes_a + codes_b)
        response_codes_a = codes_a if split_medicine_codes else sorted(medicine_codes)
        response_codes_b = codes_b if split_medicine_codes else sorted(medicine_codes)
        match = {
            "type": risk_type,
            "ingredient_a": row["ingredient_a"],
            "ingredient_b": row["ingredient_b"],
            "medicine_names_a": products_a,
            "medicine_names_b": products_b,
            "medicine_codes_a": response_codes_a,
            "medicine_codes_b": response_codes_b,
            "reason": reason,
            "official_reason": official,
            "source": row["source"] or "식약처 DUR",
            "external_id": row["external_id"],
            "_medicine_codes": sorted(medicine_codes),
            "_ingredient_keys": sorted(
                set(ingredient_keys(row["ingredient_a"]))
                | set(ingredient_keys(row["ingredient_b"]))
            ),
        }
        if include_official_criteria and risk_type in {"연령금기", "임부금기"}:
            criteria_min_age, criteria_max_age = _age_bounds_for_row(row)
            match["official_criteria"] = {
                "description": row["description"],
                "min_age": criteria_min_age,
                "max_age": criteria_max_age,
                "pregnancy_grade": row["pregnancy_grade"],
            }
            if risk_type == "연령금기":
                min_age, max_age = criteria_min_age, criteria_max_age
                if age is None or (min_age is None and max_age is None):
                    applicability = "unknown"
                    applicability_message = (
                        "사용자 생년월일 또는 공식 연령 범위를 확인할 수 없어 "
                        "개인 적용 여부는 판단하지 않았습니다."
                    )
                elif _age_is_restricted(age, min_age, max_age):
                    applicability = "applicable"
                    applicability_message = (
                        "등록된 생년월일 기준으로 공식 연령 조건에 해당합니다."
                    )
                else:
                    applicability = "not_applicable"
                    applicability_message = (
                        "등록된 생년월일 기준으로 공식 연령 조건에 해당하지 않습니다."
                    )
            elif is_pregnant is None:
                applicability = "unknown"
                applicability_message = (
                    "사용자 임신 정보가 없어 개인 적용 여부는 판단하지 않았습니다."
                )
            elif is_pregnant:
                applicability = "applicable"
                applicability_message = (
                    "등록된 사용자 정보상 임신 상태이므로 이 공식 기준과 관련될 수 있습니다."
                )
            else:
                applicability = "not_applicable"
                applicability_message = (
                    "등록된 사용자 정보상 임신 상태는 아니지만, "
                    "이 내용은 약 자체의 공식 임부금기 기준입니다."
                )
            match["user_applicability"] = applicability
            match["user_applicability_message"] = applicability_message
        matches.append(match)
    return matches


PERSON_CAUTION_TYPES = frozenset({"연령금기", "임부금기"})


def person_cautions_for_medicine(
    conn,
    *,
    user_id: str,
    medicine: dict,
) -> list[str]:
    """이 사람 나이·임신에 해당하는 연령금기·임부금기만 쉬운 문장으로 돌려 준다."""
    user = conn.execute(
        "SELECT birth_date, is_pregnant FROM users WHERE id = ?",
        (user_id,),
    ).fetchone()
    if user is None:
        return []
    try:
        is_pregnant = bool(user["is_pregnant"])
    except (KeyError, IndexError, TypeError):
        is_pregnant = None
    age = _age_from_birth_date(user["birth_date"])
    row = {
        "ingredient": medicine.get("ingredient"),
        "product_name": medicine.get("product_name") or medicine.get("display_name") or "",
        "medicine_code": str(medicine.get("medicine_code") or ""),
    }
    if not _is_usable_ingredient(row):
        return []
    grouped: dict[str, list] = defaultdict(list)
    for key in ingredient_keys(row["ingredient"]):
        grouped[key].append(row)
    if not grouped:
        return []
    taboo_rows = [
        item
        for item in conn.execute("SELECT * FROM dur_taboo").fetchall()
        if not _is_deleted_taboo(item)
    ]
    matches = _taboo_matches(
        taboo_rows,
        grouped,
        age=age,
        is_pregnant=is_pregnant,
    )
    lines: list[str] = []
    seen: set[str] = set()
    for match in matches:
        if match.get("type") not in PERSON_CAUTION_TYPES:
            continue
        line = why_easy_for(match).strip()
        if not line or line in seen:
            continue
        seen.add(line)
        lines.append(line)
        if len(lines) >= 3:
            break
    return lines


def _age_bounds_for_row(row) -> tuple[int | None, int | None]:
    """저장된 min/max 우선, 없으면 raw_json AGE_BASE 재파싱 (개월/주 포함)."""
    min_age = row["min_age"] if "min_age" in row.keys() else None
    max_age = row["max_age"] if "max_age" in row.keys() else None
    if min_age is not None or max_age is not None:
        return min_age, max_age
    raw = row["raw_json"] if "raw_json" in row.keys() else None
    if not raw:
        return None, None
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except (TypeError, json.JSONDecodeError):
        return None, None
    if not isinstance(data, dict):
        return None, None
    from app.services.dur_sync_service import _parse_age_base

    return _parse_age_base(data.get("AGE_BASE"))


def _age_is_restricted(
    age: int,
    min_age: int | None,
    max_age: int | None,
) -> bool:
    # 파싱 실패(둘 다 None)면 금기로 치지 않음 — 성인 전원 오탐 방지
    if min_age is None and max_age is None:
        return False
    if min_age is not None and age < min_age:
        return False
    if max_age is not None and age > max_age:
        return False
    return True


def _legacy_matches(rows, grouped) -> list[dict]:
    matches = []
    for row in rows:
        if _risk_type(row["taboo_type"]) in HIGH_TYPES | MEDIUM_TYPES:
            continue
        if not _grouped_hit(grouped, row["ingredient_a"]):
            continue
        if row["ingredient_b"] and not _grouped_hit(grouped, row["ingredient_b"]):
            continue
        matches.append(
            {
                "type": _risk_type(row["taboo_type"]),
                "ingredient_a": row["ingredient_a"],
                "ingredient_b": row["ingredient_b"],
                "reason": _official_reason(row["description"], "함께 먹을 때 주의가 필요해요."),
                "source": row["source"] or "기존 ingredient DUR",
            }
        )
    return matches


def _deduplicate_matches(matches: list[dict]) -> list[dict]:
    result = []
    seen = set()
    for match in matches:
        type_name = match["type"]
        a = _normalize(match.get("ingredient_a"))
        b = _normalize(match.get("ingredient_b"))
        if type_name == "병용금기" and a and b:
            pair = tuple(sorted((a, b)))
            key = (type_name, pair)
        else:
            key = (type_name, a, b, match.get("reason"))
        if key not in seen:
            seen.add(key)
            result.append(match)
    result.sort(key=lambda item: 0 if item["type"] in HIGH_TYPES else 1)
    return result


def _risk_level(matches: list[dict]) -> str:
    types = {match["type"] for match in matches}
    if types & HIGH_TYPES:
        return "HIGH"
    if types & MEDIUM_TYPES:
        return "MEDIUM"
    return "LOW"


# 화면에 고정으로 보여주는 유형 (설계 4종 + 같은성분 중복)
DISPLAY_TYPES = ("병용금기", "연령금기", "임부금기", "효능군중복", "중복성분")


def _group_by_type(matches: list[dict]) -> dict:
    """타입별 건수·목록. 표시용 5종 키는 항상 둔다."""
    grouped: dict[str, list] = {name: [] for name in DISPLAY_TYPES}
    for match in matches:
        risk_type = match.get("type") or "성분주의"
        # 효능군중복·중복성분은 화면에 각각 집계
        grouped.setdefault(risk_type, []).append(match)
    return {
        name: {"count": len(items), "items": items}
        for name, items in grouped.items()
    }


def get_latest_dur(user_id: str) -> dict:
    conn = get_connection()
    try:
        latest = conn.execute(
            """
            SELECT * FROM risk_results
            WHERE user_id = ?
            ORDER BY created_at DESC, id DESC
            LIMIT 1
            """,
            (user_id,),
        ).fetchone()
        if not latest:
            raise HTTPException(status_code=404, detail="DUR 분석 결과가 없습니다.")
        result = dict(latest)
        row_id = result.get("id")
        required_invalid = (
            not isinstance(row_id, int)
            or isinstance(row_id, bool)
            or not isinstance(result.get("user_id"), str)
            or not result.get("user_id", "").strip()
            or not isinstance(result.get("risk_level"), str)
            or not result.get("risk_level", "").strip()
            or not isinstance(result.get("created_at"), str)
            or not result.get("created_at", "").strip()
        )
        if required_invalid:
            logger.warning(
                "DUR latest required_field_invalid row_id=%s created_at_null=%s",
                row_id,
                result.get("created_at") is None,
            )
            raise HTTPException(
                status_code=503,
                detail="저장된 DUR 분석 결과를 해석할 수 없습니다. DUR 분석을 다시 실행해주세요.",
            )

        ingredients, ingredients_meta = _normalized_json_list(
            result.get("analyzed_ingredients"),
            item_kind="ingredient",
        )
        medicine_lookup_available = True
        try:
            active_medicines = _load_medicines_with_metadata(
                conn.cursor(),
                DurAnalyzeRequest(user_id=user_id, medicine_codes=[]),
            )
        except sqlite3.OperationalError as exc:
            medicine_lookup_available = False
            active_medicines = []
            logger.warning(
                "DUR latest medicine lookup unavailable row_id=%s error_type=%s",
                row_id,
                type(exc).__name__,
            )
        active_ingredients = [
            row["ingredient"]
            for row in active_medicines
            if _is_usable_ingredient(row)
        ]
        analyzed_keys = sorted(
            key
            for value in ingredients
            if (key := _normalize(value))
        )
        active_keys = sorted(
            key for value in active_ingredients if (key := _normalize(value))
        )
        if medicine_lookup_available and analyzed_keys != active_keys:
            raise HTTPException(
                status_code=404,
                detail="현재 등록된 약 조합의 DUR 분석 결과가 없습니다.",
            )
        matches, matches_meta = _normalized_json_list(
            result.get("matches_json"),
            item_kind="match",
        )
        matches = enrich_matches(matches, active_medicines)
        total_matches_value = result.get("total_matches")
        total_matches_invalid = (
            not isinstance(total_matches_value, int)
            or isinstance(total_matches_value, bool)
            or total_matches_value < 0
        )
        malformed = (
            ingredients_meta["malformed"]
            or matches_meta["malformed"]
            or total_matches_invalid
        )

        result["analyzed_ingredients"] = ingredients
        result["matches"] = matches
        result["total_matches"] = (
            len(matches)
            if total_matches_invalid
            else (total_matches_value or len(matches))
        )
        result["total_count"] = result["total_matches"]
        result["by_type"] = _group_by_type(matches)
        result["representative_type"] = (
            result.get("risk_type")
            or (matches[0]["type"] if matches else None)
        )
        if malformed:
            reasons = []
            if ingredients_meta["malformed"]:
                reasons.append("analyzed_ingredients")
            if matches_meta["malformed"]:
                reasons.append("matches_json")
            if total_matches_invalid:
                reasons.append("total_matches")
            logger.warning(
                "DUR latest malformed row_id=%s ingredients_type=%s matches_type=%s "
                "invalid_ingredients=%s invalid_matches=%s invalid_total_matches=%s",
                row_id,
                ingredients_meta["decoded_type"],
                matches_meta["decoded_type"],
                ingredients_meta["invalid_count"],
                matches_meta["invalid_count"],
                total_matches_invalid,
            )
            result["matches_json"] = None
            result["data_status"] = "malformed"
            result["incomplete"] = True
            result["incomplete_reasons"] = reasons
            result["has_risk"] = True if matches else None
            result["message"] = (
                "저장된 DUR 분석 데이터를 완전히 해석할 수 없어 위험 여부를 "
                "확인할 수 없습니다. DUR 분석을 다시 실행해주세요."
            )
            result["assessment_status"] = "INCOMPLETE"
        else:
            result["has_risk"] = bool(matches)
            result["message"] = result.get("description") or (
                f"함께 먹을 때 주의가 {len(matches)}건 있어요."
                if matches
                else "지금 등록된 약끼리, 특별한 함께먹기 주의는 없어요."
            )
            result["assessment_status"] = result.get("assessment_status") or (
                "RISK_FOUND"
                if matches
                else "INCOMPLETE"
                if str(result.get("risk_level") or "").upper() == "UNKNOWN"
                else "SAFE"
            )
            result["incomplete_reasons"] = _json_value(
                result.get("incomplete_reasons_json"),
                [],
            )
        result["analysis_complete"] = result["assessment_status"] != "INCOMPLETE"
        is_incomplete = result["assessment_status"] == "INCOMPLETE"
        if is_incomplete:
            result["incomplete"] = True
        else:
            result.pop("incomplete", None)
        result["incomplete_types"] = (
            sorted(ALL_CHECK_TYPES) if is_incomplete else []
        )
        result["medicine_names"] = [
            row["product_name"] for row in active_medicines
        ]
        result["ingredients"] = active_ingredients
        result["skipped_medicine_names"] = [
            str(row["product_name"] or row["medicine_code"])
            for row in active_medicines
            if not _is_usable_ingredient(row)
        ]
        try:
            result["taboo_row_count"] = conn.execute(
                "SELECT COUNT(*) FROM dur_taboo"
            ).fetchone()[0]
        except sqlite3.OperationalError:
            result["taboo_row_count"] = 0
        result["dur_sync_status"] = "stored"
        result["dur_sync_fetched"] = 0
        result["dur_sync_upserted"] = 0
        return result
    finally:
        conn.close()


def _json_value(value: str | None, fallback):
    if not value:
        return fallback
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return fallback


def _normalized_json_list(value, *, item_kind: str) -> tuple[list, dict]:
    """Decode legacy JSON lists while retaining an explicit malformed signal."""
    try:
        decoded = json.loads(value) if isinstance(value, str) else value
    except (json.JSONDecodeError, TypeError):
        return [], {"malformed": True, "decoded_type": "decode_error", "invalid_count": 0}

    decoded_type = type(decoded).__name__
    if not isinstance(decoded, list):
        return [], {"malformed": True, "decoded_type": decoded_type, "invalid_count": 0}

    normalized = []
    invalid_count = 0
    for item in decoded:
        if item_kind == "ingredient":
            valid = isinstance(item, str) and bool(item.strip())
        else:
            valid = (
                isinstance(item, dict)
                and isinstance(item.get("type"), str)
                and bool(item["type"].strip())
            )
        if valid:
            normalized.append(item)
        else:
            invalid_count += 1

    return normalized, {
        "malformed": invalid_count > 0,
        "decoded_type": decoded_type,
        "invalid_count": invalid_count,
    }
CARD_CONFLICT_TYPES = {"병용금기", "중복성분", "효능군중복"}


def _spoken_product_name(name: str | None) -> str:
    text = str(name or "").strip()
    index = text.find("(")
    if index > 0:
        return text[:index].strip()
    return text


def _cause_only(reason: str | None) -> str:
    text = str(reason or "").strip()
    sep = text.find(" — ")
    if sep >= 0:
        text = text[sep + 3 :].strip()
    return text.rstrip(" .")


def _first_code(values) -> str:
    for value in values or []:
        text = str(value or "").strip()
        if text:
            return text
    return ""


def _first_name(values) -> str:
    for value in values or []:
        text = _spoken_product_name(str(value or ""))
        if text:
            return text
    return ""


def _pair_names(match: dict) -> tuple[str, str]:
    name_a = _first_name(match.get("medicine_names_a"))
    name_b = _first_name(match.get("medicine_names_b"))
    if name_a and name_b and name_b != name_a:
        return name_a, name_b
    names = [
        _spoken_product_name(value)
        for value in [
            *(match.get("medicine_names_a") or []),
            *(match.get("medicine_names_b") or []),
        ]
        if _spoken_product_name(value)
    ]
    unique = list(dict.fromkeys(names))
    if len(unique) >= 2:
        return unique[0], unique[1]
    if unique:
        return unique[0], ""
    return "", ""


def pair_card_fields(match: dict) -> dict:
    """홈·자세히 공통. 어떤 약끼리인지, 쉬운 이유, 성분 위험요소."""
    name_a, name_b = _pair_names(match)
    why = str(match.get("why_easy") or "").strip()
    if not why:
        body = why_easy_for(match)
        if str(match.get("type") or "").strip() in CARD_CONFLICT_TYPES:
            why = with_together_opener(match, body)
        else:
            why = body
    cause = official_cause(match).strip()
    if cause and cause in why:
        cause = ""
    pair_label = f"{name_a} ↔ {name_b}" if name_a and name_b else name_a
    return {
        "name_a": name_a,
        "name_b": name_b,
        "pair_label": pair_label,
        "why_easy": why,
        "risk_factor": cause,
    }


def _key_caution_for_code(conn, code: str) -> str:
    if not code:
        return ""
    from app.services.pharmacist.easy_category import (
        load_medicine_guidance,
        medicine_guidance_from_medicine,
    )

    row = conn.execute(
        "SELECT * FROM medicines WHERE medicine_code = ?",
        (code,),
    ).fetchone()
    if not row:
        return ""
    med = dict(row)
    guidance = load_medicine_guidance(conn, med) or medicine_guidance_from_medicine(med)
    return str((guidance or {}).get("key_caution") or "").strip()


def interaction_priority_cards(matches: list, conn=None) -> list[dict]:
    """홈 맨 위에 올릴 병용 주의 카드. 약 두 개의 이름·이유·주의 문장."""
    close = False
    if conn is None:
        conn = get_connection()
        close = True
    try:
        cards: list[dict] = []
        seen: set[tuple] = set()
        for match in matches or []:
            if not isinstance(match, dict):
                continue
            if str(match.get("type") or "") not in CARD_CONFLICT_TYPES:
                continue
            fields = pair_card_fields(match)
            name_a = fields["name_a"]
            name_b = fields["name_b"]
            if not name_a or not name_b:
                continue
            key = tuple(sorted((name_a, name_b)))
            if key in seen:
                continue
            seen.add(key)
            code_a = _first_code(match.get("medicine_codes_a"))
            code_b = _first_code(match.get("medicine_codes_b"))
            if code_a and code_a == code_b:
                codes = [
                    str(value).strip()
                    for value in [
                        *(match.get("medicine_codes_a") or []),
                        *(match.get("medicine_codes_b") or []),
                    ]
                    if str(value or "").strip()
                ]
                unique_codes = list(dict.fromkeys(codes))
                code_a = unique_codes[0] if unique_codes else ""
                code_b = unique_codes[1] if len(unique_codes) > 1 else ""
            cards.append(
                {
                    "type": match.get("type"),
                    "name_a": name_a,
                    "name_b": name_b,
                    "code_a": code_a,
                    "code_b": code_b,
                    "reason": fields["why_easy"] or "함께 먹을 때 주의가 필요해요",
                    "risk_factor": fields["risk_factor"],
                }
            )
        return cards
    finally:
        if close:
            conn.close()


def preview_conflicts_for_codes(user_id: str, new_codes: list[str]) -> dict[str, list[dict]]:
    """아직 등록 전인 OCR 약과, 이미 먹는 약의 병용 주의를 약 코드별로 붙인다."""
    focus = {str(code).strip() for code in new_codes if str(code).strip()}
    if not user_id or not focus:
        return {}
    conn = get_connection()
    try:
        existing = [
            str(row["medicine_code"])
            for row in conn.execute(
                """
                SELECT DISTINCT medicine_code
                FROM user_medicines
                WHERE user_id = ? AND COALESCE(is_active, 1) = 1
                """,
                (user_id,),
            ).fetchall()
            if row["medicine_code"]
        ]
    finally:
        conn.close()
    codes = list(dict.fromkeys([*existing, *focus]))
    result = analyze_dur(
        DurAnalyzeRequest(user_id=user_id, medicine_codes=codes),
        persist=False,
        refresh=False,
    )
    by_code: dict[str, list[dict]] = {code: [] for code in focus}
    conn = get_connection()
    try:
        for match in result.get("matches") or []:
            if str(match.get("type") or "") not in CARD_CONFLICT_TYPES:
                continue
            codes_a = [str(value).strip() for value in (match.get("medicine_codes_a") or [])]
            codes_b = [str(value).strip() for value in (match.get("medicine_codes_b") or [])]
            names_a = [str(value).strip() for value in (match.get("medicine_names_a") or [])]
            names_b = [str(value).strip() for value in (match.get("medicine_names_b") or [])]
            reason = _cause_only(match.get("reason")) or "함께 먹을 때 주의가 필요해요"
            pairs = (
                (codes_a, names_b, codes_b),
                (codes_b, names_a, codes_a),
            )
            for own_codes, other_names, other_codes in pairs:
                for index, code in enumerate(own_codes):
                    if code not in focus:
                        continue
                    other_name = _first_name(other_names) or _first_name(
                        names_a if own_codes is codes_b else names_b
                    )
                    other_code = (
                        other_codes[index]
                        if index < len(other_codes)
                        else _first_code(other_codes)
                    )
                    if other_code == code:
                        other_code = next(
                            (value for value in other_codes if value and value != code),
                            "",
                        )
                    if not other_name:
                        continue
                    item = {
                        "other_name": other_name,
                        "other_code": other_code,
                        "type": match.get("type"),
                        "reason": reason,
                        "other_caution": _key_caution_for_code(conn, other_code),
                    }
                    if item not in by_code[code]:
                        by_code[code].append(item)
    finally:
        conn.close()
    return {code: items for code, items in by_code.items() if items}
