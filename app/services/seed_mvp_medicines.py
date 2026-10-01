"""Seed a demo patient so the home screen can load from server medicines."""

from __future__ import annotations

from app.database import get_connection
from app.services.pharmacist.easy_category import derive_easy_category


MVP_USER_ID = "mvp-user"

# 홈 고정 체험약은 코다론정 한 개만 유지한다.
_CODARONE = {
    "medicine_code": "200701021",
    "product_name": "코다론정(아미오다론염산염)",
    "ingredient": "아미오다론염산염",
    "dosage": "1알",
    "frequency_per_day": 3,
    "administration_times": '["08:00", "13:00", "20:00"]',
    "efficacy": (
        "심방성부정맥, 심실성부정맥, 기타 다른 부정맥용제로 치료되지 않는 "
        "재발성중증 부정맥\n협심증 등 기초심질환을 수반하는 부정맥"
    ),
    "precautions": "간장애 환자에게 신중히 투여한다. 임부에 투여하지 않는다.",
}

# 홈 고정 체험약은 코다론정 한 개만 유지한다.
_SEED_MEDS: tuple[dict, ...] = (_CODARONE,)
_CATALOG_MEDS = (_CODARONE,)


def ensure_mvp_demo_medicines() -> str:
    """Create mvp-user and replace active medicines with development demo data."""
    conn = get_connection()
    try:
        conn.execute(
            """
            INSERT OR IGNORE INTO users (id, name, role, birth_date)
            VALUES (?, '체험환자', 'PATIENT', '1958-01-01')
            """,
            (MVP_USER_ID,),
        )
        conn.execute(
            """
            UPDATE users
            SET name = COALESCE(NULLIF(trim(name), ''), '체험환자'),
                birth_date = COALESCE(NULLIF(trim(birth_date), ''), '1958-01-01')
            WHERE id = ?
            """,
            (MVP_USER_ID,),
        )
        guardian = conn.execute(
            "SELECT id FROM guardians WHERE user_id = ? LIMIT 1",
            (MVP_USER_ID,),
        ).fetchone()
        if not guardian:
            conn.execute(
                """
                INSERT INTO guardians (id, user_id, guardian_name, relationship)
                VALUES (?, ?, '지안', '딸')
                """,
                (f"{MVP_USER_ID}-guardian", MVP_USER_ID),
            )
        for med in _CATALOG_MEDS:
            exists = conn.execute(
                "SELECT 1 FROM medicines WHERE medicine_code = ?",
                (med["medicine_code"],),
            ).fetchone()
            if exists:
                continue
            category = derive_easy_category(
                product_name=med["product_name"],
                ingredient=med["ingredient"],
                efficacy=med["efficacy"],
            )
            conn.execute(
                """
                INSERT INTO medicines (
                    medicine_code, product_name, ingredient, efficacy,
                    precautions, easy_category, short_explanation,
                    explanation_review_status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    med["medicine_code"],
                    med["product_name"],
                    med["ingredient"],
                    med["efficacy"],
                    med.get("precautions"),
                    category,
                    med.get("short_explanation"),
                    "REVIEWED" if med.get("short_explanation") else "UNREVIEWED",
                ),
            )
        for med in _CATALOG_MEDS:
            conn.execute(
                """
                UPDATE medicines
                SET precautions = COALESCE(NULLIF(trim(precautions), ''), ?),
                    short_explanation = CASE
                        WHEN ? IS NOT NULL THEN ?
                        ELSE short_explanation
                    END,
                    explanation_review_status = CASE
                        WHEN ? IS NOT NULL THEN 'REVIEWED'
                        ELSE explanation_review_status
                    END
                WHERE medicine_code = ?
                """,
                (
                    med.get("precautions"),
                    med.get("short_explanation"),
                    med.get("short_explanation"),
                    med.get("short_explanation"),
                    med["medicine_code"],
                ),
            )

        desired = [med["medicine_code"] for med in _SEED_MEDS]
        if desired:
            placeholders = ",".join("?" for _ in desired)
            conn.execute(
                f"""
                UPDATE user_medicines
                SET is_active = 0, status = 'PAST'
                WHERE user_id = ?
                  AND prescription_item_id IS NULL
                  AND medicine_code NOT IN ({placeholders})
                """,
                (MVP_USER_ID, *desired),
            )
        else:
            conn.execute(
                """
                UPDATE user_medicines
                SET is_active = 0, status = 'PAST'
                WHERE user_id = ?
                  AND prescription_item_id IS NULL
                """,
                (MVP_USER_ID,),
            )
        conn.execute(
            """
            DELETE FROM medication_schedules
            WHERE user_id = ?
              AND user_medicine_id IN (
                  SELECT id FROM user_medicines
                  WHERE user_id = ? AND COALESCE(is_active, 1) = 0
              )
            """,
            (MVP_USER_ID, MVP_USER_ID),
        )
        for med in _SEED_MEDS:
            active = conn.execute(
                """
                SELECT id FROM user_medicines
                WHERE user_id = ? AND medicine_code = ?
                  AND COALESCE(is_active, 1) = 1
                LIMIT 1
                """,
                (MVP_USER_ID, med["medicine_code"]),
            ).fetchone()
            if active:
                continue
            conn.execute(
                """
                INSERT INTO user_medicines (
                    user_id, medicine_code, dosage, frequency_per_day,
                    administration_times, is_active, status
                ) VALUES (?, ?, ?, ?, ?, 1, 'ACTIVE')
                """,
                (
                    MVP_USER_ID,
                    med["medicine_code"],
                    med["dosage"],
                    med["frequency_per_day"],
                    med["administration_times"],
                ),
            )
        conn.commit()
        from init_db import seed_reviewed_detail_explanations

        seed_reviewed_detail_explanations(conn)
        conn.commit()
        try:
            from app.services.pharmacist.easy_category import (
                backfill_all_medicine_guidance,
                derive_key_cautions_from_medicine,
            )

            backfill_all_medicine_guidance()
            conn2 = get_connection()
            try:
                for med in _CATALOG_MEDS:
                    row = conn2.execute(
                        "SELECT * FROM medicines WHERE medicine_code = ?",
                        (med["medicine_code"],),
                    ).fetchone()
                    if not row:
                        continue
                    if derive_key_cautions_from_medicine(dict(row)):
                        continue
                    extra = (med.get("precautions") or "").strip()
                    if not extra:
                        continue
                    current = str(row["precautions"] or "")
                    conn2.execute(
                        "UPDATE medicines SET precautions = ? WHERE medicine_code = ?",
                        ((current + "\n" + extra).strip(), med["medicine_code"]),
                    )
                conn2.commit()
            finally:
                conn2.close()
            backfill_all_medicine_guidance()
        except Exception:
            pass
        return MVP_USER_ID
    finally:
        conn.close()
