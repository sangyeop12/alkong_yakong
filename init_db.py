import json
import sqlite3
from datetime import datetime

from app.database import DB_PATH, purge_ocr_placeholder_rows


TABLE_DEFINITIONS = {
    "users": """
        CREATE TABLE users (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            birth_date TEXT,
            gender TEXT,
            phone TEXT,
            role TEXT NOT NULL DEFAULT 'PATIENT',
            is_pregnant INTEGER NOT NULL DEFAULT 0,
            pregnancy_status TEXT,
            password_hash TEXT,
            height_cm REAL,
            weight_kg REAL,
            blood_type TEXT,
            smoking TEXT,
            drinking TEXT,
            allergies TEXT NOT NULL DEFAULT '[]',
            diseases TEXT NOT NULL DEFAULT '[]',
            past_history INTEGER,
            family_history INTEGER,
            past_illnesses TEXT NOT NULL DEFAULT '[]',
            family_illnesses TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    """,
    "guardians": """
        CREATE TABLE guardians (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            guardian_name TEXT NOT NULL,
            relationship TEXT,
            phone TEXT,
            fcm_token TEXT,
            notification_enabled INTEGER NOT NULL DEFAULT 1,
            guardian_user_id TEXT,
            patient_relation TEXT,
            status TEXT NOT NULL DEFAULT 'ACCEPTED',
            requested_by TEXT NOT NULL DEFAULT 'PATIENT',
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        )
    """,
    "medicines": """
        CREATE TABLE medicines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            medicine_code TEXT NOT NULL UNIQUE,
            product_name TEXT NOT NULL,
            ingredient TEXT NOT NULL,
            manufacturer TEXT,
            efficacy TEXT,
            usage TEXT,
            precautions TEXT,
            image_url TEXT,
            easy_category TEXT,
            short_explanation TEXT,
            explanation_review_status TEXT NOT NULL DEFAULT 'UNREVIEWED',
            ingredient_strength TEXT,
            dosage_form TEXT,
            administration_route TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    """,
    "medicine_purposes": """
        CREATE TABLE medicine_purposes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            medicine_code TEXT NOT NULL,
            purpose_code TEXT NOT NULL,
            easy_label TEXT NOT NULL,
            easy_sentence TEXT NOT NULL,
            evidence_type TEXT NOT NULL,
            evidence_text TEXT,
            source TEXT NOT NULL,
            confidence TEXT NOT NULL DEFAULT 'MEDIUM',
            review_status TEXT NOT NULL DEFAULT 'DERIVED',
            classifier_version TEXT NOT NULL DEFAULT '2.0',
            priority INTEGER NOT NULL DEFAULT 100,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (medicine_code) REFERENCES medicines(medicine_code) ON DELETE CASCADE,
            UNIQUE (medicine_code, purpose_code)
        )
    """,
    "medicine_key_cautions": """
        CREATE TABLE medicine_key_cautions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            medicine_code TEXT NOT NULL,
            caution_code TEXT NOT NULL,
            short_sentence TEXT NOT NULL,
            evidence_text TEXT,
            source TEXT NOT NULL,
            severity TEXT NOT NULL DEFAULT 'CAUTION',
            review_status TEXT NOT NULL DEFAULT 'DERIVED',
            classifier_version TEXT NOT NULL DEFAULT '2.0',
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (medicine_code) REFERENCES medicines(medicine_code) ON DELETE CASCADE,
            UNIQUE (medicine_code, caution_code)
        )
    """,
    "dur_taboo": """
        CREATE TABLE dur_taboo (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ingredient_a TEXT NOT NULL,
            ingredient_b TEXT,
            taboo_type TEXT NOT NULL,
            severity TEXT NOT NULL DEFAULT 'CAUTION',
            description TEXT NOT NULL,
            source TEXT,
            external_id TEXT,
            ingredient_a_code TEXT,
            ingredient_b_code TEXT,
            min_age INTEGER,
            max_age INTEGER,
            pregnancy_grade TEXT,
            notification_date TEXT,
            raw_json TEXT,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    """,
    "prescriptions": """
        CREATE TABLE prescriptions (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            source_type TEXT NOT NULL DEFAULT 'OCR',
            hospital_name TEXT,
            pharmacy_name TEXT,
            prescribed_date TEXT,
            expire_date TEXT,
            original_image_path TEXT,
            ocr_text TEXT,
            registration_fingerprint TEXT,
            ocr_status TEXT NOT NULL DEFAULT 'COMPLETED',
            status TEXT NOT NULL DEFAULT 'ACTIVE',
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        )
    """,
    "prescription_items": """
        CREATE TABLE prescription_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            prescription_id TEXT NOT NULL,
            medicine_code TEXT,
            ocr_drug_name TEXT NOT NULL,
            dosage TEXT,
            unit TEXT,
            frequency_per_day INTEGER,
            times_per_take INTEGER,
            duration_days INTEGER,
            administration_times TEXT,
            warning_note TEXT,
            easy_explanation TEXT,
            ocr_drug_name_raw TEXT,
            ocr_field_confidences TEXT,
            dosage_form TEXT,
            administration_route TEXT,
            match_status TEXT NOT NULL DEFAULT 'UNMATCHED',
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (prescription_id) REFERENCES prescriptions(id) ON DELETE CASCADE,
            FOREIGN KEY (medicine_code) REFERENCES medicines(medicine_code) ON DELETE SET NULL
        )
    """,
    "user_medicines": """
        CREATE TABLE user_medicines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            medicine_code TEXT NOT NULL,
            prescription_item_id INTEGER,
            start_date TEXT,
            end_date TEXT,
            dosage TEXT,
            dose_amount REAL,
            dose_unit TEXT,
            frequency_per_day INTEGER,
            administration_times TEXT,
            is_active INTEGER NOT NULL DEFAULT 1,
            status TEXT NOT NULL DEFAULT 'ACTIVE',
            last_prescribed_at TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
            FOREIGN KEY (medicine_code) REFERENCES medicines(medicine_code),
            FOREIGN KEY (prescription_item_id) REFERENCES prescription_items(id) ON DELETE SET NULL
        )
    """,
    "medication_schedules": """
        CREATE TABLE medication_schedules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            user_medicine_id INTEGER NOT NULL,
            scheduled_date TEXT NOT NULL,
            scheduled_time TEXT NOT NULL,
            time_slot TEXT,
            status TEXT NOT NULL DEFAULT 'PENDING',
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
            FOREIGN KEY (user_medicine_id) REFERENCES user_medicines(id) ON DELETE CASCADE,
            UNIQUE (user_medicine_id, scheduled_date, scheduled_time)
        )
    """,
    "medication_logs": """
        CREATE TABLE medication_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            schedule_id INTEGER,
            user_medicine_id INTEGER,
            taken_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            status TEXT NOT NULL DEFAULT 'TAKEN',
            image_path TEXT,
            verification_result TEXT,
            confidence_score REAL,
            details_json TEXT,
            note TEXT,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
            FOREIGN KEY (schedule_id) REFERENCES medication_schedules(id) ON DELETE SET NULL,
            FOREIGN KEY (user_medicine_id) REFERENCES user_medicines(id) ON DELETE SET NULL
        )
    """,
    "risk_results": """
        CREATE TABLE risk_results (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            risk_level TEXT NOT NULL,
            taboo_id INTEGER,
            ingredient_a TEXT,
            ingredient_b TEXT,
            description TEXT,
            analyzed_ingredients TEXT NOT NULL,
            analysis_id TEXT,
            risk_type TEXT,
            total_matches INTEGER NOT NULL DEFAULT 0,
            matches_json TEXT,
            assessment_status TEXT,
            incomplete_reasons_json TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
            FOREIGN KEY (taboo_id) REFERENCES dur_taboo(id) ON DELETE SET NULL
        )
    """,
    "heart_rate_logs": """
        CREATE TABLE heart_rate_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            bpm INTEGER NOT NULL CHECK (bpm > 0),
            measured_at TEXT NOT NULL,
            device_id TEXT,
            source TEXT NOT NULL DEFAULT 'POLAR',
            measurement_context TEXT NOT NULL DEFAULT 'general'
                CHECK (measurement_context IN ('general', 'before_medication', 'after_medication')),
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        )
    """,
    "biosignal_test_sessions": """
        CREATE TABLE biosignal_test_sessions (
            id TEXT PRIMARY KEY,
            participant_id TEXT NOT NULL CHECK (participant_id IN ('P01', 'P02', 'P03')),
            scenario TEXT NOT NULL CHECK (scenario IN ('REST_SITTING', 'REST_LYING', 'MORNING', 'MEAL', 'STAIRS', 'WALK', 'SHOWER', 'COFFEE', 'PHONE_AWAY', 'SENSOR_OFF')),
            started_at TEXT NOT NULL,
            ended_at TEXT,
            is_synthetic INTEGER NOT NULL DEFAULT 0 CHECK (is_synthetic IN (0, 1)),
            note TEXT
        )
    """,
    "biosignal_test_samples": """
        CREATE TABLE biosignal_test_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            bpm INTEGER NOT NULL CHECK (bpm > 0),
            measured_at TEXT NOT NULL,
            device_id TEXT,
            source TEXT NOT NULL CHECK (source IN ('POLAR_DATASET_5S', 'SYNTHETIC_TEST')),
            is_synthetic INTEGER NOT NULL DEFAULT 0 CHECK (is_synthetic IN (0, 1)),
            FOREIGN KEY (session_id) REFERENCES biosignal_test_sessions(id) ON DELETE CASCADE
        )
    """,
    "baseline_heart_rate": """
        CREATE TABLE baseline_heart_rate (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL UNIQUE,
            resting_bpm REAL NOT NULL,
            min_normal_bpm INTEGER NOT NULL,
            max_normal_bpm INTEGER NOT NULL,
            sample_count INTEGER NOT NULL DEFAULT 1,
            calculated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        )
    """,
    "abnormal_events": """
        CREATE TABLE abnormal_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            heart_rate_log_id INTEGER,
            event_type TEXT NOT NULL,
            bpm INTEGER NOT NULL,
            baseline_bpm REAL,
            severity TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'OPEN',
            occurred_at TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
            FOREIGN KEY (heart_rate_log_id) REFERENCES heart_rate_logs(id) ON DELETE SET NULL
        )
    """,
    "notifications": """
        CREATE TABLE notifications (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            guardian_id TEXT,
            abnormal_event_id INTEGER,
            schedule_id INTEGER,
            medication_log_id INTEGER,
            notification_type TEXT NOT NULL,
            title TEXT NOT NULL,
            message TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'RECORDED',
            sent_at TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
            FOREIGN KEY (guardian_id) REFERENCES guardians(id) ON DELETE SET NULL,
            FOREIGN KEY (abnormal_event_id) REFERENCES abnormal_events(id) ON DELETE SET NULL,
            FOREIGN KEY (schedule_id) REFERENCES medication_schedules(id) ON DELETE SET NULL,
            FOREIGN KEY (medication_log_id) REFERENCES medication_logs(id) ON DELETE SET NULL
        )
    """,
    "ai_explanation_cards": """
        CREATE TABLE ai_explanation_cards (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            medicine_code TEXT NOT NULL,
            summary TEXT NOT NULL,
            what_it_does TEXT,
            how_to_take TEXT,
            warnings TEXT,
            cautions TEXT,
            side_effects TEXT,
            storage TEXT,
            ask_doctor_when TEXT,
            source_based INTEGER NOT NULL DEFAULT 0,
            official_raw_summary TEXT,
            source_document_ids TEXT,
            model_name TEXT NOT NULL DEFAULT 'mock',
            generated_by TEXT NOT NULL DEFAULT 'mock',
            source TEXT NOT NULL DEFAULT 'local',
            is_verified INTEGER NOT NULL DEFAULT 0,
            ingredient_explanation TEXT,
            approved_use_summary TEXT,
            approved_uses TEXT,
            review_status TEXT NOT NULL DEFAULT 'DRAFT',
            source_verified INTEGER NOT NULL DEFAULT 0,
            content_generated_by TEXT,
            source_url TEXT,
            content_version INTEGER NOT NULL DEFAULT 1,
            reviewed_at TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (medicine_code) REFERENCES medicines(medicine_code) ON DELETE CASCADE
        )
    """,
    "ingredient_explanations": """
        CREATE TABLE ingredient_explanations (
            normalized_key TEXT PRIMARY KEY,
            ingredient_name TEXT NOT NULL,
            explanation TEXT NOT NULL,
            role_explanation TEXT,
            use_help TEXT,
            role_group TEXT,
            group_explanation TEXT,
            review_status TEXT NOT NULL DEFAULT 'DRAFT',
            source TEXT NOT NULL DEFAULT 'local',
            source_verified INTEGER NOT NULL DEFAULT 0,
            generated_by TEXT NOT NULL DEFAULT 'manual',
            content_version INTEGER NOT NULL DEFAULT 1,
            reviewed_at TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    """,
    "medicine_detail_profiles": """
        CREATE TABLE medicine_detail_profiles (
            medicine_code TEXT PRIMARY KEY,
            status TEXT NOT NULL DEFAULT 'PENDING',
            ingredient_keys TEXT NOT NULL DEFAULT '[]',
            ingredient_explanation TEXT,
            approved_use_summary TEXT,
            approved_uses TEXT NOT NULL DEFAULT '[]',
            all_approved_uses TEXT NOT NULL DEFAULT '[]',
            official_usage TEXT,
            key_cautions TEXT NOT NULL DEFAULT '[]',
            possible_side_effects TEXT NOT NULL DEFAULT '[]',
            ask_doctor_when TEXT NOT NULL DEFAULT '[]',
            source_name TEXT NOT NULL DEFAULT '식약처 의약품 허가정보',
            source_url TEXT,
            source_verified INTEGER NOT NULL DEFAULT 0,
            review_status TEXT NOT NULL DEFAULT 'UNREVIEWED',
            generated_by TEXT NOT NULL DEFAULT 'official-parser',
            source_hash TEXT,
            quality_flags TEXT NOT NULL DEFAULT '[]',
            parser_version TEXT NOT NULL DEFAULT '2.0',
            content_version INTEGER NOT NULL DEFAULT 1,
            prepared_at TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (medicine_code) REFERENCES medicines(medicine_code) ON DELETE CASCADE
        )
    """,
    "medicine_detail_jobs": """
        CREATE TABLE medicine_detail_jobs (
            medicine_code TEXT PRIMARY KEY,
            status TEXT NOT NULL DEFAULT 'PENDING',
            attempts INTEGER NOT NULL DEFAULT 0,
            source_hash TEXT,
            last_error TEXT,
            requested_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            started_at TEXT,
            finished_at TEXT,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (medicine_code) REFERENCES medicines(medicine_code) ON DELETE CASCADE
        )
    """,
    "medicine_documents": """
        CREATE TABLE medicine_documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            medicine_code TEXT NOT NULL,
            document_type TEXT NOT NULL,
            title TEXT,
            content TEXT NOT NULL,
            source_url TEXT,
            embedding TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (medicine_code) REFERENCES medicines(medicine_code) ON DELETE CASCADE
        )
    """,
}

REQUIRED_COLUMNS = {
    table: {
        line.strip().split()[0]
        for line in definition.splitlines()
        if line.strip()
        and not line.strip().upper().startswith(("CREATE ", "FOREIGN ", "UNIQUE ", "CHECK ", ")"))
    }
    for table, definition in TABLE_DEFINITIONS.items()
}

INDEXES = [
    "CREATE INDEX IF NOT EXISTS idx_guardians_user_id ON guardians(user_id)",
    "CREATE INDEX IF NOT EXISTS idx_medicines_ingredient ON medicines(ingredient)",
    "CREATE INDEX IF NOT EXISTS idx_medicine_purposes_code ON medicine_purposes(medicine_code, priority)",
    "CREATE INDEX IF NOT EXISTS idx_medicine_cautions_code ON medicine_key_cautions(medicine_code)",
    "CREATE INDEX IF NOT EXISTS idx_dur_taboo_ingredients ON dur_taboo(ingredient_a, ingredient_b)",
    """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_dur_taboo_source_external
    ON dur_taboo(source, taboo_type, external_id)
    WHERE external_id IS NOT NULL
    """,
    "CREATE INDEX IF NOT EXISTS idx_prescriptions_user_id ON prescriptions(user_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_prescriptions_registration_fingerprint ON prescriptions(user_id, registration_fingerprint) WHERE registration_fingerprint IS NOT NULL",
    "CREATE INDEX IF NOT EXISTS idx_prescription_items_prescription_id ON prescription_items(prescription_id)",
    "CREATE INDEX IF NOT EXISTS idx_user_medicines_user_id ON user_medicines(user_id, is_active)",
    "CREATE INDEX IF NOT EXISTS idx_schedules_user_date ON medication_schedules(user_id, scheduled_date)",
    "CREATE INDEX IF NOT EXISTS idx_medication_logs_user_taken ON medication_logs(user_id, taken_at)",
    "CREATE INDEX IF NOT EXISTS idx_risk_results_user_created ON risk_results(user_id, created_at)",
    "CREATE INDEX IF NOT EXISTS idx_heart_rate_user_measured ON heart_rate_logs(user_id, measured_at)",
    "CREATE INDEX IF NOT EXISTS idx_biosignal_test_sessions_filter ON biosignal_test_sessions(participant_id, scenario, is_synthetic, started_at)",
    "CREATE INDEX IF NOT EXISTS idx_biosignal_test_samples_session_measured ON biosignal_test_samples(session_id, measured_at)",
    "CREATE INDEX IF NOT EXISTS idx_abnormal_events_user_occurred ON abnormal_events(user_id, occurred_at)",
    "CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON notifications(user_id, created_at)",
    "CREATE INDEX IF NOT EXISTS idx_notifications_schedule ON notifications(schedule_id, notification_type)",
    "CREATE INDEX IF NOT EXISTS idx_ingredient_explanations_review ON ingredient_explanations(review_status, normalized_key)",
    "CREATE INDEX IF NOT EXISTS idx_medicine_detail_profiles_status ON medicine_detail_profiles(status, updated_at)",
    "CREATE INDEX IF NOT EXISTS idx_medicine_detail_jobs_status ON medicine_detail_jobs(status, requested_at)",
]

OBSOLETE_TABLES = ("prescription_drugs",)

ADDITIVE_COLUMNS = {
    "dur_taboo": {
        "external_id": "TEXT",
        "ingredient_a_code": "TEXT",
        "ingredient_b_code": "TEXT",
        "min_age": "INTEGER",
        "max_age": "INTEGER",
        "pregnancy_grade": "TEXT",
        "notification_date": "TEXT",
        "raw_json": "TEXT",
        "updated_at": "TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP",
    },
    "risk_results": {
        "analysis_id": "TEXT",
        "risk_type": "TEXT",
        "total_matches": "INTEGER NOT NULL DEFAULT 0",
        "matches_json": "TEXT",
        "assessment_status": "TEXT",
        "incomplete_reasons_json": "TEXT",
    },
    "notifications": {
        "schedule_id": "INTEGER",
        "medication_log_id": "INTEGER",
    },
    "ai_explanation_cards": {
        "cautions": "TEXT",
        "side_effects": "TEXT",
        "what_it_does": "TEXT",
        "storage": "TEXT",
        "ask_doctor_when": "TEXT",
        "source_based": "INTEGER NOT NULL DEFAULT 0",
        "official_raw_summary": "TEXT",
        "generated_by": "TEXT NOT NULL DEFAULT 'mock'",
        "source": "TEXT NOT NULL DEFAULT 'local'",
        "is_verified": "INTEGER NOT NULL DEFAULT 0",
        "ingredient_explanation": "TEXT",
        "approved_use_summary": "TEXT",
        "approved_uses": "TEXT",
        "review_status": "TEXT NOT NULL DEFAULT 'DRAFT'",
        "source_verified": "INTEGER NOT NULL DEFAULT 0",
        "content_generated_by": "TEXT",
        "source_url": "TEXT",
        "content_version": "INTEGER NOT NULL DEFAULT 1",
        "reviewed_at": "TEXT",
    },
    "prescription_items": {
        "easy_explanation": "TEXT",
        "ocr_drug_name_raw": "TEXT",
        "ocr_field_confidences": "TEXT",
        "dosage_form": "TEXT",
        "administration_route": "TEXT",
    },
    "prescriptions": {
        "registration_fingerprint": "TEXT",
    },
    "medicines": {
        "easy_category": "TEXT",
        "usage": "TEXT",
        "short_explanation": "TEXT",
        "explanation_review_status": "TEXT NOT NULL DEFAULT 'UNREVIEWED'",
        "ingredient_strength": "TEXT",
        "dosage_form": "TEXT",
        "administration_route": "TEXT",
    },
    "user_medicines": {
        "dose_amount": "REAL",
        "dose_unit": "TEXT",
        "status": "TEXT NOT NULL DEFAULT 'ACTIVE'",
        "last_prescribed_at": "TEXT",
    },
    "medicine_detail_profiles": {
        "all_approved_uses": "TEXT NOT NULL DEFAULT '[]'",
        "quality_flags": "TEXT NOT NULL DEFAULT '[]'",
        "parser_version": "TEXT NOT NULL DEFAULT '2.0'",
    },
    "ingredient_explanations": {
        "role_explanation": "TEXT",
        "use_help": "TEXT",
        "role_group": "TEXT",
        "group_explanation": "TEXT",
    },
    "guardians": {
        "guardian_user_id": "TEXT",
        "patient_relation": "TEXT",
        "status": "TEXT NOT NULL DEFAULT 'ACCEPTED'",
        "requested_by": "TEXT NOT NULL DEFAULT 'PATIENT'",
    },
    "users": {
        "is_pregnant": "INTEGER NOT NULL DEFAULT 0",
        "pregnancy_status": "TEXT",
        "password_hash": "TEXT",
        "height_cm": "REAL",
        "weight_kg": "REAL",
        "blood_type": "TEXT",
        "smoking": "TEXT",
        "drinking": "TEXT",
        "allergies": "TEXT NOT NULL DEFAULT '[]'",
        "diseases": "TEXT NOT NULL DEFAULT '[]'",
        "past_history": "INTEGER",
        "family_history": "INTEGER",
        "past_illnesses": "TEXT NOT NULL DEFAULT '[]'",
        "family_illnesses": "TEXT NOT NULL DEFAULT '[]'",
    },
    "heart_rate_logs": {
        "measurement_context": "TEXT NOT NULL DEFAULT 'general' CHECK (measurement_context IN ('general', 'before_medication', 'after_medication'))",
    },
}


def _existing_columns(cursor: sqlite3.Cursor, table: str) -> set[str]:
    return {row[1] for row in cursor.execute(f"PRAGMA table_info({table})")}


def ensure_additive_columns(cursor: sqlite3.Cursor) -> None:
    """기존 행을 건드리지 않고 빠진 열만 더한다."""
    for table, columns in ADDITIVE_COLUMNS.items():
        existing = _existing_columns(cursor, table)
        for column, definition in columns.items():
            if existing and column not in existing:
                cursor.execute(
                    f"ALTER TABLE {table} ADD COLUMN {column} {definition}"
                )
                existing.add(column)


_REVIEWED_HOME_EXPLANATIONS = {
    "197800210": "가려움 또는 불안·긴장을 완화할 목적으로 처방될 수 있어요.",
    "200403137": "위산을 줄여 속쓰림과 위산 역류를 완화하는 약이에요.",
}


def _seed_reviewed_home_explanations(cursor: sqlite3.Cursor) -> None:
    for medicine_code, sentence in _REVIEWED_HOME_EXPLANATIONS.items():
        cursor.execute(
            """
            UPDATE medicines
            SET short_explanation = ?, explanation_review_status = 'REVIEWED',
                updated_at = CURRENT_TIMESTAMP
            WHERE medicine_code = ?
              AND COALESCE(explanation_review_status, 'UNREVIEWED') != 'REVIEWED'
            """,
            (sentence, medicine_code),
        )


def _deactivate_legacy_demo_medicines(cursor: sqlite3.Cursor) -> None:
    """예전 MVP 가짜 품목은 기록은 남기고 사용자 복용약에서는 비활성화한다."""
    cursor.execute(
        """
        UPDATE user_medicines
        SET is_active = 0, status = 'PAST'
        WHERE medicine_code IN ('MVP-ASP', 'MVP-AMLO', 'MVP-MET')
        """
    )


_REVIEWED_INGREDIENT_EXPLANATIONS = {
    "아미오다론염산염": {
        "explanation": "아미오다론염산염은 심장 박동을 만드는 전기 신호가 지나치게 빠르거나 불규칙해지는 것을 조절하는 성분이에요.",
        "role_explanation": "심장 박동을 만드는 전기 신호를 조절해요.",
        "use_help": "지나치게 빠르거나 불규칙한 심장 박동을 조절하는 데 도움을 줘요.",
    },
    "이부프로펜": {
        "explanation": "이부프로펜은 몸에서 통증과 열, 염증 반응에 관여하는 물질이 만들어지는 것을 줄이는 성분이에요.",
        "role_explanation": "통증과 열, 염증 반응에 관여하는 물질이 만들어지는 것을 줄여요.",
        "use_help": "열과 통증, 염증을 줄이는 데 도움을 줘요.",
    },
    "에스시탈로프람옥살산염": {
        "explanation": "에스시탈로프람옥살산염은 뇌에서 세로토닌의 작용을 조절해 우울감과 불안 증상을 완화하는 데 도움을 주는 성분이에요.",
        "role_explanation": "뇌에서 세로토닌의 작용을 조절해요.",
        "use_help": "우울감과 불안 증상을 완화하는 데 도움을 줘요.",
    },
    "탄산마그네슘": {
        "explanation": "탄산마그네슘은 위산을 중화해 속쓰림과 위 불편감을 줄이는 데 도움을 주는 성분이에요.",
        "role_explanation": "위산을 중화해요.",
        "use_help": "속쓰림과 위 불편감을 줄이는 데 도움을 줘요.",
        "role_group": "antacid-neutralizer",
        "group_explanation": "이 약의 여러 주성분은 위산을 중화해 속쓰림과 위 불편감을 줄이는 데 함께 도움을 줘요.",
    },
    "침강탄산칼슘": {
        "explanation": "침강탄산칼슘은 위산을 중화해 속쓰림과 위 불편감을 줄이는 데 도움을 주는 성분이에요.",
        "role_explanation": "위산을 중화해요.",
        "use_help": "속쓰림과 위 불편감을 줄이는 데 도움을 줘요.",
        "role_group": "antacid-neutralizer",
        "group_explanation": "이 약의 여러 주성분은 위산을 중화해 속쓰림과 위 불편감을 줄이는 데 함께 도움을 줘요.",
    },
    "탄산수소나트륨": {
        "explanation": "탄산수소나트륨은 위산을 중화해 속쓰림과 위 불편감을 줄이는 데 도움을 주는 성분이에요.",
        "role_explanation": "위산을 중화해요.",
        "use_help": "속쓰림과 위 불편감을 줄이는 데 도움을 줘요.",
        "role_group": "antacid-neutralizer",
        "group_explanation": "이 약의 여러 주성분은 위산을 중화해 속쓰림과 위 불편감을 줄이는 데 함께 도움을 줘요.",
    },
    "건조수산화알루미늄 겔": {
        "explanation": "건조수산화알루미늄 겔은 위산을 중화해 속쓰림과 위 불편감을 줄이는 데 도움을 주는 성분이에요.",
        "role_explanation": "위산을 중화해요.",
        "use_help": "속쓰림과 위 불편감을 줄이는 데 도움을 줘요.",
        "role_group": "antacid-neutralizer",
        "group_explanation": "이 약의 여러 주성분은 위산을 중화해 속쓰림과 위 불편감을 줄이는 데 함께 도움을 줘요.",
    },
}


def _invalidate_unusable_ingredient_explanations(cursor: sqlite3.Cursor) -> None:
    """Keep reviewed copy, but quarantine old drafts that end mid-sentence."""
    from app.services.medicine_detail_providers import (
        is_displayable_ingredient_explanation,
    )

    rows = cursor.execute(
        """
        SELECT normalized_key, explanation
        FROM ingredient_explanations
        WHERE review_status='REVIEWED'
        """
    ).fetchall()
    for normalized_key, explanation in rows:
        if is_displayable_ingredient_explanation(explanation):
            continue
        cursor.execute(
            """
            UPDATE ingredient_explanations
            SET review_status='DRAFT', source_verified=0,
                updated_at=CURRENT_TIMESTAMP
            WHERE normalized_key=?
            """,
            (normalized_key,),
        )


def _seed_reviewed_ingredient_explanations(cursor: sqlite3.Cursor) -> None:
    """Seed reusable ingredient-level copy without product-specific branches."""
    from app.services.medicine_detail_service import normalize_ingredient_key

    for ingredient_name, content in _REVIEWED_INGREDIENT_EXPLANATIONS.items():
        cursor.execute(
            """
            INSERT INTO ingredient_explanations (
                normalized_key, ingredient_name, explanation,
                role_explanation, use_help, role_group, group_explanation,
                review_status, source, source_verified, generated_by,
                content_version, reviewed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'REVIEWED',
                      '식약처 허가정보·성분 검토본', 1,
                      'reviewed-ingredient-seed-v2', 2, CURRENT_TIMESTAMP)
            ON CONFLICT(normalized_key) DO UPDATE SET
                ingredient_name=excluded.ingredient_name,
                explanation=CASE
                    WHEN ingredient_explanations.review_status='REVIEWED'
                         AND ingredient_explanations.source_verified=1
                    THEN ingredient_explanations.explanation
                    ELSE excluded.explanation
                END,
                role_explanation=COALESCE(
                    ingredient_explanations.role_explanation,
                    excluded.role_explanation
                ),
                use_help=COALESCE(
                    ingredient_explanations.use_help,
                    excluded.use_help
                ),
                role_group=COALESCE(
                    ingredient_explanations.role_group,
                    excluded.role_group
                ),
                group_explanation=COALESCE(
                    ingredient_explanations.group_explanation,
                    excluded.group_explanation
                ),
                review_status='REVIEWED', source_verified=1,
                source=CASE
                    WHEN ingredient_explanations.review_status='REVIEWED'
                    THEN ingredient_explanations.source
                    ELSE excluded.source
                END,
                generated_by=CASE
                    WHEN ingredient_explanations.review_status='REVIEWED'
                    THEN ingredient_explanations.generated_by
                    ELSE excluded.generated_by
                END,
                content_version=MAX(
                    ingredient_explanations.content_version,
                    excluded.content_version
                ),
                reviewed_at=COALESCE(
                    ingredient_explanations.reviewed_at,
                    CURRENT_TIMESTAMP
                ),
                updated_at=CURRENT_TIMESTAMP
            """,
            (
                normalize_ingredient_key(ingredient_name),
                ingredient_name,
                content["explanation"],
                content.get("role_explanation"),
                content.get("use_help"),
                content.get("role_group"),
                content.get("group_explanation"),
            ),
        )


def seed_reviewed_detail_explanations(cursor: sqlite3.Cursor) -> None:
    """개발 화면에서 사용할, 출처와 문장을 검토한 상세 설명."""
    medicine_code = "200701021"
    exists = cursor.execute(
        """
        SELECT 1 FROM ai_explanation_cards
        WHERE medicine_code = ? AND review_status = 'REVIEWED'
        LIMIT 1
        """,
        (medicine_code,),
    ).fetchone()
    if exists:
        return
    medicine = cursor.execute(
        "SELECT usage FROM medicines WHERE medicine_code = ?",
        (medicine_code,),
    ).fetchone()
    if medicine is None:
        return
    cautions = [
        "숨이 차거나 마른기침이 계속되면 의사나 약사에게 알려주세요.",
        "시야가 흐려지거나 시력이 떨어지면 의료진에게 알려주세요.",
        "복용 중에는 의료진의 안내에 따라 심장·간·갑상선 검사가 필요할 수 있어요.",
    ]
    ask_doctor_when = [
        "숨쉬기 어렵거나 마른기침이 계속될 때",
        "시야가 흐려지거나 피부에 심한 발진이나 물집이 생길 때",
    ]
    cursor.execute(
        """
        INSERT INTO ai_explanation_cards (
            medicine_code, summary, what_it_does, how_to_take,
            warnings, cautions, side_effects, storage, ask_doctor_when,
            source_based, official_raw_summary, source_document_ids,
            model_name, generated_by, source, is_verified,
            ingredient_explanation, approved_use_summary, approved_uses,
            review_status, source_verified, content_generated_by,
            source_url, content_version, reviewed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, '', '[]', ?, ?, ?, 1,
                  ?, ?, ?, 'REVIEWED', 1, ?, ?, 1, CURRENT_TIMESTAMP)
        """,
        (
            medicine_code,
            "심장 박동을 고르게 하는 약이에요.",
            "다른 치료로 잘 조절되지 않는 부정맥 치료에 사용될 수 있어요.",
            str(medicine[0] or ""),
            json.dumps(cautions, ensure_ascii=False),
            json.dumps(cautions, ensure_ascii=False),
            "[]",
            "실온(30℃ 이하)에서 어린이의 손이 닿지 않는 곳에 보관하세요.",
            json.dumps(ask_doctor_when, ensure_ascii=False),
            "reviewed-seed-v1",
            "reviewed-seed-v1",
            "식약처 의약품 허가정보",
            "아미오다론염산염은 심장 박동을 만드는 전기 신호가 지나치게 빠르거나 불규칙해지는 것을 조절하는 성분이에요.",
            "다른 치료로 잘 조절되지 않는 부정맥 치료에 사용될 수 있어요.",
            json.dumps(
                ["재발하는 중증 부정맥", "심장 질환을 동반한 부정맥"],
                ensure_ascii=False,
            ),
            "reviewed-seed-v1",
            "https://nedrug.mfds.go.kr",
        ),
    )


def initialize_database() -> None:
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA foreign_keys = ON")
    cursor = conn.cursor()
    suffix = datetime.now().strftime("%Y%m%d%H%M%S")

    for table in OBSOLETE_TABLES:
        if _existing_columns(cursor, table):
            cursor.execute(f"ALTER TABLE {table} RENAME TO legacy_{table}_{suffix}")

    ensure_additive_columns(cursor)

    for table, definition in TABLE_DEFINITIONS.items():
        existing = _existing_columns(cursor, table)
        if existing and not REQUIRED_COLUMNS[table].issubset(existing):
            cursor.execute(f"ALTER TABLE {table} RENAME TO legacy_{table}_{suffix}")
        cursor.execute(definition.replace(f"CREATE TABLE {table}", f"CREATE TABLE IF NOT EXISTS {table}"))

    for statement in INDEXES:
        cursor.execute(statement)

    _seed_reviewed_home_explanations(cursor)
    _invalidate_unusable_ingredient_explanations(cursor)
    _seed_reviewed_ingredient_explanations(cursor)
    seed_reviewed_detail_explanations(cursor)
    _deactivate_legacy_demo_medicines(cursor)
    conn.commit()
    purge_ocr_placeholder_rows(conn)
    # 기존 의약품도 새 복수 목적/핵심 주의 구조로 채운다.
    # REVIEWED 행은 동기화 함수가 보존하므로 운영 검토값이 다시 덮이지 않는다.
    from app.services.pharmacist.easy_category import sync_medicine_guidance

    rows = cursor.execute("SELECT * FROM medicines").fetchall()
    columns = [item[0] for item in cursor.description] if cursor.description else []
    for row in rows:
        sync_medicine_guidance(cursor, dict(zip(columns, row)))
    # 기존 DB 약 전체를 같은 상세 구조로 준비한다. 네트워크·AI 호출은 하지 않는다.
    from app.services.medicine_detail_service import prepare_all_medicine_details

    prepare_all_medicine_details(cursor)
    conn.commit()
    conn.close()


if __name__ == "__main__":
    initialize_database()
    print(f"알콩약콩 MVP {len(TABLE_DEFINITIONS)}개 테이블 생성 완료: {DB_PATH}")
