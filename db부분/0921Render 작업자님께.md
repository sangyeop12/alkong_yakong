# 0921 Render 작업자님께

## 1. 전달 목적

현재 아래 기능은 개발 과정에서 Flutter 앱이 로컬 FastAPI 주소를 바라보도록 연결해 확인했습니다.

- 처방전 사진 OCR
- OCR 결과 확인 및 처방 등록
- 직접 약 입력
- 등록한 약의 복용 일정 생성과 `약 있는 날` 달력
- 오늘 홈 약 목록
- 내 약 목록과 약 자세히
- 함께먹기(DUR) 분석
- 먹었어요 기록과 복약 달력

최종 목표는 이 기능을 Render의 기존 FastAPI와 기존 운영 DB에 합치고, 앱이 더 이상 개발 PC 주소를 사용하지 않게 만드는 것입니다. Polar 센서 기능을 변경하는 요청은 아닙니다.

중요한 원칙은 **로컬 `alkongyakong.db`를 운영 DB 위에 덮어쓰지 않는 것**입니다. Render의 사용자·처방·일정·복약 기록은 보존하고, 현재 코드의 스키마와 기능만 운영 DB에 추가해야 합니다.

---

## 2. 현재 로컬 연결 지점

### Flutter 서버 주소

- 파일: `lib/core/network/api_config.dart`
- `ApiConfig.baseUrl`: 기본 Render 주소
- `ApiConfig.localFeatureBaseUrl`: 현재 개발 PC 주소 `http://172.16.42.25:8000`

아래 화면과 저장소는 현재 `localFeatureBaseUrl`을 사용합니다.

| 기능 | Flutter 위치 | 사용자에게 보이는 화면/동작 |
|---|---|---|
| 처방전 OCR·결과 등록 | `lib/features/prescription/presentation/screens/prescription_screen.dart` | `처방전 찍기` → `이렇게 읽었어요` → `이대로 등록하기` |
| 직접 약 입력 | `lib/features/prescription/presentation/screens/manual_medicine_screen.dart` | 처방전 넣기에서 `직접 입력` 선택 |
| 약 있는 날 | `lib/features/prescription/presentation/screens/schedule_days_screen.dart` | 등록 완료 후 날짜별 복용 일정 확인·수정 |
| 함께먹기 | `lib/features/dur_analysis/presentation/screens/dur_analysis_screen.dart` | 실제 충돌이 있을 때 `약 함께먹기 주의` 표시 |
| 오늘 약 | `lib/features/medication/application/medication_controller.dart` | 오늘 홈의 아침·점심·저녁 약 카드 |
| 내 약 목록·상세 데이터 | `lib/features/medicines/application/user_medicines_controller.dart` | `내 약 목록`과 `약 자세히` 화면 데이터 |
| 복약 기록 | `lib/features/dashboard/application/medication_history_provider.dart` | 먹었어요 상태와 기간별 복약 이력 |
| 복약 달력 | `lib/features/dashboard/presentation/screens/month_calendar_screen.dart` | 날짜별 먹었어요·놓쳤어요 확인 |
| 기존 대시보드 | `lib/features/dashboard/presentation/screens/dashboard_screen.dart` | 약·처방·DUR·이상 이벤트 요약 |

로그인·회원가입, AI 약사 챗봇과 일부 심박 기능은 기본 `ApiConfig.baseUrl`을 사용하므로 기존 Render로 요청되고 있습니다.

---

## 3. 백엔드 폴더와 역할

### 공통 실행·DB

| 위치 | 역할 |
|---|---|
| `app/main.py` | FastAPI 라우터 등록, 서버 시작 시 DB 초기화, 운영 환경의 상세/DUR 백그라운드 작업 시작 |
| `app/database.py` | `ALKONGYAKONG_DB_PATH`로 주 DB 연결, SQLite 대기 시간을 60초로 설정 |
| `init_db.py` | 테이블·컬럼·인덱스 추가, 검토된 설명 시드, 기존 상세 데이터 보정 |

### OCR 및 처방 등록

| 위치 | 역할 |
|---|---|
| `app/routes/prescription.py` | OCR, 등록 확정, 처방 목록, 약 있는 날 API |
| `app/services/ocr/` | CLOVA 응답을 읽고 약명·1회량·횟수·일수·시간대로 구조화 |
| `app/services/prescription_service.py` | 공식 약 매칭, 중복 등록 방지, 처방·내 약·복용 일정 저장, 저장 후 DUR 결과 반환 |
| `app/services/mfds_drug_permission/` | 식약처 제품 허가정보 조회 및 별도 미러 DB 관리 |

주요 API:

- `POST /api/v1/prescriptions/ocr`
- `POST /api/v1/prescriptions/confirm`
- `GET /api/v1/users/{user_id}/prescriptions`
- `GET/POST /api/v1/users/{user_id}/prescriptions/{prescription_id}/schedule-days`
- `GET /api/v1/medicines/lookup?q=약이름`

### 오늘 홈·내 약·약 상세

| 위치 | 역할 |
|---|---|
| `app/routes/dashboard.py` | 오늘 약, 대시보드, 복약 달력, 손입력용 약 검색 API |
| `app/routes/users.py` | 내 약 목록, 약 한 건 상세, 기간별 복약 기록 API |
| `app/services/today_medication_service.py` | 오늘 일정과 복약 여부를 홈 카드로 조합 |
| `app/services/user_medicines_service.py` | 현재·과거 약 목록 및 개인 복용법과 최신 DUR을 조합 |
| `app/routes/drug_explain.py` | 공식 약 상세와 AI 약사 챗봇 API |
| `app/services/medicine_detail_service.py` | 저장된 식약처 자료를 주성분 설명·대표 치료 목적·공식 용법 구조로 변환 |
| `app/services/drug_explain_service.py` | 약 자세히 응답과 설명 카드 구성 |

주요 API:

- `GET /api/v1/users/{user_id}/today-medicines`
- `GET /api/v1/users/{user_id}/medicines`
- `GET /api/v1/users/{user_id}/medicines/{medicine_code}`
- `GET /api/v1/drug-explain/{medicine_code}`
- `GET /api/v1/users/{user_id}/medication-history`
- `GET /api/v1/users/{user_id}/medication-calendar`

`today_medication_service.py`와 `user_medicines_service.py`는 현재 사용자에게 코다론정 기준약이 없으면 `ensure_user_codarone_available()`로 한 건을 보장합니다. Render에서도 이 동작을 유지할지 먼저 합의해야 하며, 유지한다면 운영 사용자마다 코다론정이 추가되는 것이 의도된 동작입니다.

### DUR·함께먹기

| 위치 | 역할 |
|---|---|
| `app/routes/dur_analysis.py` | DUR 분석, 최신 결과 조회, 공식 자료 동기화·진단 API |
| `app/services/dur_service.py` | 현재 복용약의 성분을 병용·연령·임부·효능군 중복 자료와 비교 |
| `app/services/dur_sync_service.py` | 식약처 DUR 자료를 받아 `dur_taboo`에 저장 |

주요 API:

- `POST /api/v1/dur/analyze`
- `GET /api/v1/users/{user_id}/dur/latest`
- `POST /api/v1/dur/sync`
- `GET /api/v1/dur/sync/diagnose`

등록 API는 약과 일정을 먼저 저장한 뒤 현재 저장된 DUR 자료로 분석합니다. 외부 식약처 요청을 사용자 화면에서 기다리게 하지 않는 구조입니다.

### 복약 기록

| 위치 | 역할 |
|---|---|
| `app/routes/medication_logs.py` | 먹었어요 및 놓쳤어요 기록 API |
| `app/services/medication_service.py` | 중복 기록 방지, 일정 상태 변경, 복약 로그와 알림 저장 |
| `app/services/medication_history_service.py` | 날짜별 예정 횟수와 실제 복약 횟수 집계 |

주요 API:

- `POST /api/v1/medication-logs`
- `POST /api/v1/medication-logs/mark-missed`

---

## 4. 관련 DB 구성

### 주 운영 DB: `alkongyakong.db`

| 기능 | 주요 테이블 |
|---|---|
| 사용자 | `users`, `guardians` |
| 공식 약 기본정보 | `medicines`, `medicine_purposes`, `medicine_key_cautions` |
| OCR 처방 | `prescriptions`, `prescription_items` |
| 사용자 약과 일정 | `user_medicines`, `medication_schedules` |
| 복약 기록 | `medication_logs` |
| DUR | `dur_taboo`, `risk_results` |
| 약 상세 | `medicine_detail_profiles`, `medicine_detail_jobs`, `ingredient_explanations`, `ingredient_aliases`, `medicine_documents`, `ai_explanation_cards` |
| 심박 | `heart_rate_logs`, `baseline_heart_rate`, `abnormal_events` |

### 별도 참고 DB

- `mfds_drug_permission.db`: 식약처 제품 허가정보 미러, `products` 테이블 사용
- `easy_category_map.db`: 공식 표현을 쉬운 분류로 보여주기 위한 매핑 DB

`.env`와 로컬 `alkongyakong.db`에는 환경별 값과 개발 데이터가 있으므로 Git 또는 전달 ZIP에 포함하지 않습니다.

---

## 5. Render 반영 방향

### 1단계: 운영 DB를 먼저 백업

배포 전에 Render persistent disk의 운영 DB 파일을 날짜가 포함된 이름으로 복사합니다.

- 백업 대상: `alkongyakong.db`
- 별도 DB를 persistent disk에서 운영 중이면 `mfds_drug_permission.db`, `easy_category_map.db`도 백업
- 사용자·처방·내 약·일정·복약 기록 건수 또는 최소 샘플 사용자를 기록해 배포 후 비교

`init_db.py`는 단순 테이블 생성만 하지 않습니다. 누락 컬럼 추가, 구조가 다른 테이블의 `legacy_*` 이름 변경, 검토 설명 보정, 예전 `OCR-%` 임시 약 정리도 수행합니다. 따라서 운영 DB 복사본에 먼저 실행하고 결과를 확인한 뒤 실제 DB에 적용해야 합니다.

### 2단계: Render persistent disk 경로 지정

SQLite 파일을 프로젝트 기본 경로에 두면 Render 재배포 시 사라질 수 있습니다. Render의 persistent disk를 예를 들어 `/var/data`에 연결한 후 다음 환경변수를 사용합니다.

```text
ALKONGYAKONG_DB_PATH=/var/data/alkongyakong.db
MFDS_DRUG_PERMISSION_DB_PATH=/var/data/mfds_drug_permission.db
EASY_CATEGORY_MAP_DB_PATH=/var/data/easy_category_map.db
```

기존 Render DB가 이미 다른 경로에 있다면 새 파일을 만들지 말고 그 실제 경로를 `ALKONGYAKONG_DB_PATH`에 지정해야 합니다.

### 3단계: Render 환경변수 설정

필수 또는 기능별 환경변수:

```text
APP_ENV=production
DEMO_SEED_ENABLED=false

CLOVA_OCR_ENABLED=true
CLOVA_OCR_API_URL=<Render 환경변수로 입력>
CLOVA_OCR_SECRET_KEY=<Render 환경변수로 입력>

E_DRUG_API_KEY=<식약처 e약은요 키>
MFDS_DRUG_PERMISSION_API_KEY=<식약처 제품 허가정보 키>
DUR_API_KEY=<식약처 DUR 키>

GEMINI_API_KEY=<AI 약사 사용 시 입력>
GEMINI_MODEL=gemini-2.5-flash
```

키 값은 문서·Git·로그에 직접 적지 않습니다. Render Dashboard의 Secret 환경변수로만 등록합니다.

처음 배포할 때 대량 동기화와 사용자 요청이 동시에 SQLite를 쓰지 않도록 다음처럼 시작하는 편이 안전합니다.

```text
DUR_AUTO_SYNC=false
DUR_BOOTSTRAP_MAX_PAGES=20
```

기본 기능 확인 후 DUR 자동 갱신이 필요하면 `DUR_AUTO_SYNC=true`로 바꿉니다. `APP_ENV=production`에서는 상세정보와 DUR 백그라운드 작업이 시작되므로, 운영 DB 복사본에서 시작 시간과 DB 잠금 여부를 먼저 확인해야 합니다.

### 4단계: 코드 반영과 서버 실행

Render 시작 명령의 기준은 다음과 같습니다.

```text
uvicorn app.main:app --host 0.0.0.0 --port $PORT
```

배포할 코드는 `app/`, `init_db.py`, `requirements.txt`와 필요한 참고 DB/초기화 코드입니다. 개발 PC의 `.env`, `alkongyakong.db`, 로그, 테스트 이미지, 빌드 결과물은 배포하지 않습니다.

### 5단계: Flutter 요청 주소를 Render로 통합

백엔드 배포만 해서는 앱의 OCR·등록·약 상세 요청이 Render로 바뀌지 않습니다. 현재 해당 기능이 `ApiConfig.localFeatureBaseUrl`을 사용하기 때문입니다.

안전한 전환 방법은 둘 중 하나입니다.

#### 방법 A: 빌드 환경값으로 전환

코드 수정 없이 앱 실행·빌드 시 다음 값을 줍니다.

```text
--dart-define=LOCAL_API_BASE_URL=https://alkong-yakong.onrender.com
```

#### 방법 B: 코드에서 주소 통합

Render 검증이 끝나면 `lib/core/network/api_config.dart`에서 `localFeatureBaseUrl`이 `productionBaseUrl`을 사용하도록 바꿉니다. 이후 이름도 `featureBaseUrl`처럼 정리하면 개발 PC 전용 주소라는 오해를 줄일 수 있습니다.

전환 후 다음 화면의 모든 요청이 같은 Render 사용자와 DB를 바라봐야 합니다.

- 처방전 찍기와 OCR 결과
- 직접 약 입력
- 이대로 등록하기
- 약 있는 날
- 함께먹기 주의
- 오늘 홈
- 내 약 목록
- 약 자세히
- 먹었어요와 복약 달력

로그인만 Render이고 OCR 등록은 다른 DB를 바라보면, 로그인 사용자 ID가 OCR 서버 DB에 없어 저장·조회가 어긋납니다. 최종 운영에서는 반드시 같은 Render DB로 통합해야 합니다.

---

## 6. 배포 후 확인 순서

1. `GET /health`
   - `status=ok`
   - `environment=production`
   - `ocr_configured=true`
   - 의도한 DB 파일명이 표시되는지 확인
2. 기존 사용자로 로그인하고 기존 내 약·복약 기록이 남아 있는지 확인
3. 실제 처방전 사진으로 `POST /api/v1/prescriptions/ocr` 확인
4. `이렇게 읽었어요`에서 약명, 1회 투약량, 1일 투여 횟수, 투약 일수 확인
5. `이대로 등록하기` 후 아래 세 곳에 같은 약이 보이는지 확인
   - 오늘 홈
   - 내 약 목록
   - 약 있는 날
6. 충돌 약 조합은 빨간 `약 함께먹기 주의`, 충돌이 없으면 일반 일정 흐름으로 이동하는지 확인
7. 약 자세히에서 아래 항목 확인
   - 주성분 설명과 핵심 강조
   - 대표 치료 목적 최대 3개
   - 전체 공식 사용 목적
   - 내가 처방받은 복용 방법
   - 제품 공식 용법·용량
   - 실제 충돌이 있을 때만 함께먹기 경고
8. 먹었어요 기록 후 오늘 홈과 복약 달력에 동일하게 반영되는지 확인
9. 서버를 재시작한 뒤에도 등록한 약과 기록이 유지되는지 확인

---

## 7. 완료 기준

- 앱에 개발 PC IP 주소가 남아 있지 않음
- OCR·등록·오늘 홈·내 약·약 상세·DUR·복약 기록이 동일한 Render 사용자와 DB를 사용함
- 기존 Render 사용자와 복약 데이터가 유지됨
- Render 재시작·재배포 후에도 SQLite 데이터가 유지됨
- OCR과 공식 약 조회에 필요한 키가 Render Secret으로 설정됨
- DUR 실패를 `안전` 또는 `충돌 없음`으로 표시하지 않음
- 실제 성분 충돌이 있을 때만 함께먹기 경고가 표시됨
- 운영 DB를 로컬 개발 DB로 덮어쓰지 않음

