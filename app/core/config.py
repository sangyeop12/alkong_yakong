import os
from pathlib import Path

from dotenv import load_dotenv


PROJECT_ROOT = Path(__file__).resolve().parents[2]
load_dotenv(PROJECT_ROOT / ".env")

_ON_RENDER = bool(os.getenv("RENDER"))
APP_ENV = os.getenv(
    "APP_ENV",
    "production" if _ON_RENDER else "development",
).strip().lower()
APP_VERSION = os.getenv("APP_VERSION", "1.2.0").strip() or "1.2.0"
DEMO_SEED_ENABLED = os.getenv(
    "DEMO_SEED_ENABLED",
    "false",
).lower() == "true"

E_DRUG_API_KEY = os.getenv("E_DRUG_API_KEY") or os.getenv("MFDS_SERVICE_KEY")
DUR_API_KEY = os.getenv("DUR_API_KEY") or E_DRUG_API_KEY
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")

# AI 약사의 함께먹기 질문에서 실제 복용약과 DUR 결과를 읽는 약 데이터 서버.
# 팀 Render 자신의 SQLite를 fallback으로 사용하지 않도록 반드시 별도 설정한다.
MEDICATION_FEATURE_BASE_URL = os.getenv(
    "MEDICATION_FEATURE_BASE_URL",
    "",
).strip().rstrip("/")
_MEDICATION_FEATURE_TIMEOUT = os.getenv(
    "MEDICATION_FEATURE_TIMEOUT_SECONDS",
    "10",
).strip()
try:
    MEDICATION_FEATURE_TIMEOUT_SECONDS = max(
        1.0,
        min(float(_MEDICATION_FEATURE_TIMEOUT), 30.0),
    )
except ValueError:
    MEDICATION_FEATURE_TIMEOUT_SECONDS = 10.0

E_DRUG_BASE_URL = (
    "https://apis.data.go.kr/1471000/DrbEasyDrugInfoService/getDrbEasyDrugList"
)
DUR_API_BASE_URL = (
    "https://apis.data.go.kr/1471000/DURIrdntInfoService03"
)

# 식약처 의약품 제품 허가정보
MFDS_DRUG_PERMISSION_API_KEY = (
    os.getenv("MFDS_DRUG_PERMISSION_API_KEY") or E_DRUG_API_KEY
)
MFDS_DRUG_PERMISSION_BASE_URL = os.getenv(
    "MFDS_DRUG_PERMISSION_BASE_URL",
    "https://apis.data.go.kr/1471000/DrugPrdtPrmsnInfoService07",
).rstrip("/")
MFDS_DRUG_PERMISSION_LIST_PATH = os.getenv(
    "MFDS_DRUG_PERMISSION_LIST_PATH",
    "/getDrugPrdtPrmsnInq07",
)
MFDS_DRUG_PERMISSION_DETAIL_PATH = os.getenv(
    "MFDS_DRUG_PERMISSION_DETAIL_PATH",
    "/getDrugPrdtPrmsnDtlInq06",
)
MFDS_DRUG_PERMISSION_DB_PATH = os.getenv(
    "MFDS_DRUG_PERMISSION_DB_PATH",
    str(PROJECT_ROOT / "mfds_drug_permission.db"),
)

# 공식 표현 → 쉬운 분류(괄호) 대응표
EASY_CATEGORY_MAP_DB_PATH = os.getenv(
    "EASY_CATEGORY_MAP_DB_PATH",
    str(PROJECT_ROOT / "easy_category_map.db"),
)

# 네이버 CLOVA OCR
CLOVA_OCR_API_URL = os.getenv("CLOVA_OCR_API_URL", "").strip()
CLOVA_OCR_SECRET_KEY = os.getenv("CLOVA_OCR_SECRET_KEY", "").strip()
CLOVA_OCR_ENABLED = os.getenv("CLOVA_OCR_ENABLED", "true").lower() == "true"

# 식약처 DUR: 서버 기동·검사 시 자동으로 받아온다 (수동 POST /dur/sync 없이도).
DUR_AUTO_SYNC = os.getenv("DUR_AUTO_SYNC", "true").lower() == "true"
_DUR_BOOTSTRAP_PAGES = os.getenv("DUR_BOOTSTRAP_MAX_PAGES", "20").strip().lower()
if _DUR_BOOTSTRAP_PAGES in {"all", "none", "*"}:
    DUR_BOOTSTRAP_MAX_PAGES = None
elif _DUR_BOOTSTRAP_PAGES.isdigit():
    DUR_BOOTSTRAP_MAX_PAGES = max(1, int(_DUR_BOOTSTRAP_PAGES))
else:
    DUR_BOOTSTRAP_MAX_PAGES = 20

# Backward-compatible names used by the existing external route.
MFDS_SERVICE_KEY = E_DRUG_API_KEY
MFDS_E_DRUG_BASE_URL = E_DRUG_BASE_URL
