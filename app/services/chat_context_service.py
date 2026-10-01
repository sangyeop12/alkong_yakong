import json
import re
from collections import Counter
from typing import Any

from app.database import get_connection
from app.services.pharmacist.ingredient import (
    is_usable_ingredient,
    normalize_ingredient,
)


OFFICIAL_FIELDS_BY_INTENT = {
    "overview": (
        "product_name",
        "ingredient",
        "manufacturer",
        "efficacy",
        "cautions",
    ),
    "efficacy": ("product_name", "ingredient", "efficacy"),
    "dosage": ("product_name", "usage"),
    "usage": ("product_name", "usage"),
    "precautions": ("product_name", "cautions"),
    "side_effects": ("product_name", "side_effects"),
    "interaction": ("product_name", "ingredient", "interaction"),
    "combination": ("product_name", "ingredient", "interaction"),
    "age": ("product_name", "ingredient", "cautions"),
    "pregnancy": ("product_name", "ingredient", "cautions"),
    "duplicate": ("product_name", "ingredient", "efficacy"),
    "safety": ("product_name", "ingredient", "cautions", "interaction"),
    "storage": ("product_name", "storage"),
}

DUR_TYPES_BY_INTENT = {
    "interaction": {"병용금기"},
    "combination": {"병용금기", "중복성분", "효능군중복"},
    "age": {"연령금기"},
    "pregnancy": {"임부금기"},
    "duplicate": {"효능군중복", "중복성분"},
    "safety": {"병용금기", "연령금기", "임부금기", "효능군중복", "중복성분"},
}

SAFETY_INTENTS = frozenset(DUR_TYPES_BY_INTENT)
EXPLICIT_QUESTION_INTENTS = frozenset(
    {
        "overview",
        "efficacy",
        "dosage",
        "precautions",
        "side_effects",
        "combination",
        "age",
        "pregnancy",
        "duplicate",
    }
)

UNRELATED_QUESTION_REPLY = (
    "저는 약에 관한 질문을 도와드려요. "
    "복용법이나 주의사항을 물어봐 주세요."
)
AMBIGUOUS_QUESTION_REPLY = (
    "약에 관한 질문인지 한 번만 더 알려주세요. "
    "궁금한 약 이름이나 복용법·주의사항 중 무엇을 묻는지 적어 주세요."
)
MEDICINE_SELECTION_REQUIRED_REPLY = (
    "약마다 답이 달라요. "
    "물어볼 약을 선택하거나 제품명·성분명을 알려주세요."
)


def classify_question_scope(message: str) -> str:
    """Classify an unselected free-text question before any medicine lookup."""
    normalized = "".join(str(message or "").lower().split())
    if not normalized:
        return "ambiguous"

    product_identity = bool(
        re.search(
            r"[0-9a-z가-힣]{2,}(?:정|캡슐|연질|시럽|주사|액|패치|크림|산)"
            r"(?=과|와|은|는|이|가|을|를|에|의|도|만|,|\s|$)",
            normalized,
        )
    )
    medicine_terms = (
        "약",
        "복용",
        "투여",
        "처방",
        "성분",
        "부작용",
        "이상반응",
        "용량",
        "금기",
        "상호작용",
        "같이먹",
        "함께먹",
        "알약",
        "캡슐",
        "연고",
        "주사",
        "보관",
    )
    has_medicine_topic = product_identity or any(
        term in normalized for term in medicine_terms
    )
    if not has_medicine_topic:
        unrelated_terms = (
            "날씨",
            "기온",
            "우산",
            "맛집",
            "뉴스",
            "축구",
            "야구",
            "영화",
            "음악",
        )
        return (
            "unrelated"
            if any(term in normalized for term in unrelated_terms)
            else "ambiguous"
        )

    if any(term in normalized for term in ("깜빡", "잊었", "놓쳐", "보관", "저장")):
        return "general_medication"

    medicine_specific_terms = (
        "부작용",
        "이상반응",
        "몇번",
        "용량",
        "어떻게먹",
        "복용법",
        "사용법",
        "같이먹",
        "함께먹",
        "먹어도돼",
        "무슨약",
        "어디에쓰",
        "커피",
        "카페인",
        "음료",
        "음식",
        "우유",
        "자몽",
        "술",
        "음주",
    )
    matched_specific_terms = [
        term for term in medicine_specific_terms if term in normalized
    ]
    beverage_terms = ("커피", "카페인", "음료", "우유", "자몽", "술", "음주")
    has_beverage_term = any(term in normalized for term in beverage_terms)
    if matched_specific_terms and not product_identity:
        first_term_index = min(normalized.find(term) for term in matched_specific_terms)
        prefix = normalized[:first_term_index]
        generic_prefixes = ("약", "이약", "일반약", "보통약", "먹는약", "복용중인약")
        product_identity = len(prefix) >= 2 and not prefix.startswith(
            generic_prefixes
        )
    if matched_specific_terms:
        if has_beverage_term and not product_identity:
            return "general_medication"
        return "medicine_specific" if product_identity else "needs_medicine"

    if product_identity:
        return "medicine_specific"

    return "general_medication"


def build_general_medication_prompt(message: str) -> str:
    return f"""
당신은 고령 사용자를 위한 의약품 일반 질문 도우미입니다.
질문의 답을 첫 문장에 쓰고 보통 2~3문장으로 마치세요.
특정 약의 제품명·성분·처방 정보가 없으므로 개인 복용량, 복용 시점, 안전 여부를 추정하지 마세요.
특정 제품에 따라 답이 달라지면 약을 선택하거나 이름을 알려 달라고 짧게 물으세요.
음식이나 커피·카페인·음료와 약을 함께 사용하는 일반 질문은, 약마다 다를 수 있다는
짧은 일반 안내를 먼저 제공한 뒤 구체적인 확인을 위해 약 이름을 알려 달라고 요청하세요.
이 경우 답변 전체를 약 이름 요청 한 문장만으로 대체하지 마세요.
복용량을 두 배로 늘리거나 임의로 중단하라는 지시를 하지 마세요.
반복되는 서론·인사·맺음말은 쓰지 마세요.

[사용자 질문]
{message}
""".strip()


def general_conversation_reply(message: str) -> str | None:
    normalized = "".join(ch for ch in str(message or "").lower() if ch.isalnum())
    if normalized in {"안녕", "안녕하세요"}:
        return (
            "안녕하세요. 사용 중인 약의 효과, 사용 방법, 주의할 점이나 "
            "약끼리 서로 영향을 주는 경우에 대해 질문해 주세요."
        )
    if normalized in {"고마워", "고마워요", "감사", "감사합니다"}:
        return "도움이 되어 기뻐요. 다른 약 정보가 궁금하면 편하게 물어보세요."
    if normalized in {"너는뭐야", "무슨기능이있어"}:
        return (
            "식약처 공식정보와 약을 함께 사용할 때의 주의 정보를 확인한 결과를 "
            "바탕으로 약의 효과, 사용 방법, 주의할 점, 사용 뒤 나타날 수 있는 증상, "
            "약끼리 서로 영향을 주는 경우를 쉽게 설명해 드릴 수 있어요."
        )
    return None


def classify_question(message: str) -> set[str]:
    normalized = "".join(str(message or "").lower().split())
    intents: set[str] = set()
    if any(term in normalized for term in ("같이먹", "함께먹", "병용", "조합")):
        intents.add("combination")
    if any(term in normalized for term in ("상호작용", "다른약", "충돌")):
        intents.add("interaction")
    if any(term in normalized for term in ("나이", "연령", "몇살", "고령", "어린이")):
        intents.add("age")
    if any(term in normalized for term in ("임신", "임부", "임산부", "태아")):
        intents.add("pregnancy")
    if any(term in normalized for term in ("중복", "비슷한효과", "효능군")):
        intents.add("duplicate")
    if any(term in normalized for term in ("안전", "금기", "먹어도돼", "복용해도돼")):
        intents.add("safety")
    if any(term in normalized for term in ("부작용", "이상반응")):
        intents.add("side_effects")
    if any(term in normalized for term in ("주의", "경고", "조심")):
        intents.add("precautions")
    if any(
        term in normalized
        for term in ("커피", "카페인", "음료", "음식", "우유", "자몽", "술", "음주")
    ):
        intents.add("precautions")
    if any(term in normalized for term in ("어떻게먹", "복용법", "사용법", "용법", "몇번")):
        intents.add("usage")
    if any(term in normalized for term in ("효능", "효과", "어디에좋")):
        intents.add("efficacy")
    if any(term in normalized for term in ("보관", "저장")):
        intents.add("storage")
    if not intents or any(term in normalized for term in ("무슨약", "뭐야", "설명")):
        intents.add("overview")
    return intents


def resolve_question_intents(
    message: str,
    explicit_intent: str | None = None,
) -> set[str]:
    if explicit_intent in EXPLICIT_QUESTION_INTENTS:
        return {explicit_intent}
    return classify_question(message)


def is_safety_question(intents: set[str]) -> bool:
    return bool(intents & SAFETY_INTENTS)


def select_official_context(
    official_info: dict[str, Any],
    intents: set[str],
) -> dict[str, Any]:
    fields = {"medicine_code", "source"}
    for intent in intents:
        fields.update(OFFICIAL_FIELDS_BY_INTENT.get(intent, ()))
    return {
        field: official_info[field]
        for field in fields
        if official_info.get(field) not in (None, "", [])
    }


def load_latest_dur_context(user_id: str, intents: set[str]) -> dict[str, Any]:
    wanted_types = set().union(
        *(DUR_TYPES_BY_INTENT.get(intent, set()) for intent in intents)
    )
    if not wanted_types:
        return {"status": "not_required", "items": []}
    if not user_id:
        return {"status": "missing", "items": []}

    conn = get_connection()
    try:
        row = conn.execute(
            """
            SELECT analyzed_ingredients, matches_json FROM risk_results
            WHERE user_id = ?
            ORDER BY created_at DESC, id DESC LIMIT 1
            """,
            (user_id,),
        ).fetchone()
        if not row:
            return {"status": "missing", "items": []}

        current_rows = conn.execute(
            """
            SELECT m.*
            FROM medicines m
            WHERE m.medicine_code IN (
                SELECT DISTINCT um.medicine_code
                FROM user_medicines um
                WHERE um.user_id = ? AND um.is_active = 1
            )
            ORDER BY m.medicine_code
            """,
            (user_id,),
        ).fetchall()
        current = [
            item["ingredient"]
            for item in current_rows
            if is_usable_ingredient(
                item["ingredient"],
                item["product_name"] if "product_name" in item.keys() else None,
            )
        ]
        analyzed = _json_list(row["analyzed_ingredients"])
        if _ingredient_signature(current) != _ingredient_signature(analyzed):
            return {"status": "stale", "items": []}

        matches = _json_list(row["matches_json"])

        result = []
        for match in matches if isinstance(matches, list) else []:
            if not isinstance(match, dict) or match.get("type") not in wanted_types:
                continue
            result.append(_enrich_dur_match(conn, match))
        return {"status": "current", "items": result}
    finally:
        conn.close()


def _json_list(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if not value:
        return []
    try:
        parsed = json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return []
    return parsed if isinstance(parsed, list) else []


def _ingredient_signature(values: list[Any]) -> Counter:
    return Counter(
        normalized
        for value in values
        if (normalized := normalize_ingredient(str(value or "")))
    )


def _enrich_dur_match(conn, match: dict[str, Any]) -> dict[str, Any]:
    context = {
        "analysis_type": match.get("type"),
        "ingredient_a": match.get("ingredient_a"),
        "ingredient_b": match.get("ingredient_b"),
        "prohibition_or_caution": match.get("reason"),
        "source": match.get("source"),
    }
    external_id = match.get("external_id")
    if not external_id:
        return {key: value for key, value in context.items() if value not in (None, "")}

    row = conn.execute(
        """
        SELECT min_age, max_age, pregnancy_grade, notification_date, raw_json
        FROM dur_taboo WHERE external_id = ?
        ORDER BY updated_at DESC, id DESC LIMIT 1
        """,
        (external_id,),
    ).fetchone()
    if not row:
        return {key: value for key, value in context.items() if value not in (None, "")}

    raw = {}
    try:
        raw = json.loads(row["raw_json"] or "{}")
    except (TypeError, json.JSONDecodeError):
        pass
    context.update(
        {
            "prohibition_or_caution": raw.get("PROHBT_CONTENT")
            or context.get("prohibition_or_caution"),
            "age_base": raw.get("AGE_BASE"),
            "min_age": row["min_age"],
            "max_age": row["max_age"],
            "pregnancy_grade": row["pregnancy_grade"],
            "additional_remark": raw.get("REMARK"),
            "notification_date": row["notification_date"],
            "external_id": external_id,
        }
    )
    return {key: value for key, value in context.items() if value not in (None, "")}


def enrich_dur_matches(matches: list[dict[str, Any]]) -> list[dict[str, Any]]:
    conn = get_connection()
    try:
        return [_enrich_dur_match(conn, match) for match in matches]
    finally:
        conn.close()


def build_grounded_chat_prompt(
    *,
    message: str,
    intents: set[str],
    official_contexts: list[dict[str, Any]],
    dur_result: dict[str, Any],
) -> str:
    official_text = (
        json.dumps(official_contexts, ensure_ascii=False, indent=2)
        if official_contexts
        else "현재 질문에 사용할 수 있는 식약처 공식정보가 없습니다."
    )
    dur_text = (
        json.dumps(dur_result["items"], ensure_ascii=False, indent=2)
        if dur_result["items"]
        else "현재 서버가 확인한 해당 유형의 DUR 분석 결과가 없습니다."
    )
    confirmed_zero_messages = [
        str(value).strip()
        for value in dur_result.get("confirmed_zero_messages") or []
        if str(value).strip()
    ]
    confirmed_zero_text = (
        "\n".join(confirmed_zero_messages)
        if confirmed_zero_messages
        else "정상 완료된 0건 항목으로 확정된 안내가 없습니다."
    )
    return f"""
당신은 고령 사용자를 위한 알콩약콩 의약품 설명 도우미입니다.

반드시 지킬 규칙:
- 아래에 제공된 식약처 공식정보를 최우선 근거로 사용하세요. e약은요 정보가 있으면 우선하고, 없을 때는 정확한 품목으로 검증된 의약품 허가정보만 사용하세요.
- DUR 위험 여부를 새로 추론하거나 판정하지 마세요.
- 병용금기, 연령금기, 임부금기, 효능군중복 여부는 서버가 전달한 DUR 분석 결과만 설명하세요.
- 연령금기와 임부금기는 official_criteria를 약 자체의 공식 기준으로 먼저 설명하세요.
- user_applicability는 사용자 프로필 기준 참고 정보입니다. unknown이면 개인 적용 여부를 판단하지 말고, not_applicable이어도 약 자체의 공식 기준을 생략하지 마세요.
- user_applicability가 applicable이어도 복용 금지나 위험을 새로 단정하지 말고, 공식 기준과 관련될 수 있으므로 의료진 또는 약사에게 확인하도록 안내하세요.
- 서버 DUR 결과가 없다는 사실을 안전하다는 뜻으로 해석하지 마세요.
- 공식 근거가 없는 안전성 질문에는 "현재 확인된 식약처 정보만으로는 확인하기 어렵습니다."라고 한계를 밝히세요.
- 공식정보에 없는 내용을 사실처럼 만들지 마세요.
- 질문에 대한 핵심 답을 첫 문장에 쉬운 말로 쓰세요. 한 문장에는 한 가지 내용만 담고, 짧은 문장과 짧은 문단을 쓰세요. 선택한 제품명은 필요할 때만 쓰고 보통은 "이 약"이라고 하세요.
- 최종 답변은 일반 텍스트로만 쓰세요. Markdown 제목(#), 굵게(**), 기울임(*), 목록 기호(- 또는 *), 백틱, 표, HTML 태그를 쓰지 마세요. 구분이 꼭 필요하면 평범한 제목과 줄바꿈만 쓰세요.
- 기본 답변은 필요한 내용만 짧은 문장과 짧은 문단으로 간결하게 쓰세요. 같은 뜻의 반복, 일반적인 인사, 질문과 관련 없는 공식정보, 긴 맺음말은 쓰지 마세요. 다만 공식 조건·금지·심각한 위험은 길이를 줄이려고 빼지 마세요.
- 일반 질문은 보통 2~3문장으로 답하세요. precautions·side_effects는 가장 중요한 내용부터 핵심 3~4문장으로 답하세요. 약 전체 질문은 확인된 약마다 핵심 1문장을 우선하고, 특정 약을 누락하지 않은 채 반복되는 설명과 공통 안내는 한 번만 쓰세요. 이는 작성 목표이며 글자 수에 맞춰 문장을 기계적으로 자르지 마세요.
- 숫자·용량·단위·횟수·기간·연령·금지·예외 조건과 확인하지 못한 약·검사 범위는 분량 목표보다 우선합니다. 이를 빼거나 의미를 약하게 만들어 짧게 맞추지 마세요.
- 답변은 핵심 답, 필요한 공식 근거, 사용자가 확인하거나 주의할 행동 순서로 작성하세요. 질문에 충분히 답한 경우 억지로 문장을 늘리지 마세요.
- overview 질문에는 확인된 공식정보 안에서 이 약의 대표 역할과 주로 사용하는 경우를 먼저 설명하세요. 중요한 주의사항이 제공된 경우 가장 중요한 한 가지를 짧게 덧붙이되, 자료에 없는 주의사항을 만들지 마세요.
- efficacy 질문에는 공식적으로 어떤 증상이나 질환에 사용하는지 설명하고, 사용자 개인에게 효과가 있다고 단정하지 마세요.
- dosage 또는 usage 질문에는 공식적인 일반 사용법과 실제 처방 지시가 우선이라는 점을 구분하세요. 개인 복용량을 새로 만들지 마세요.
- precautions 또는 side_effects 질문에는 흔히 생길 수 있는 불편과 공식자료에 있는 심각한 위험을 구분하세요. 공식자료에 응급 확인이 필요한 증상과 행동이 있으면 빼지 마세요.
- combination 질문에는 확인 대상 약, 분석 완료 여부, 확인된 주의 조합, 자료가 부족한 부분을 근거가 있는 범위에서 설명하세요.
- 일반 사용자가 일상적으로 쓰지 않는 의학·해부학·약학 전문용어는 가능하면 뜻을 보존한 쉬운 한국어로 바꿔 설명하세요. 공식 명칭이나 정확성을 위해 어려운 용어가 꼭 필요하면 처음 등장할 때만 "전문용어(짧고 쉬운 뜻)"처럼 설명하고, 같은 답변에서 반복 설명하지 마세요.
- 다음은 문맥이 맞을 때만 사용할 예시이며, 목록에 없는 어려운 말에도 같은 원칙을 적용하세요. 단순 단어 치환은 하지 마세요.
- 융모는 장의 구조를 뜻하는 문맥에서만 "장 안쪽의 작은 돌기"로 설명하세요. 상피는 "몸 표면이나 장기를 덮는 얇은 층", 수용체는 "약 성분이 작용하는 몸속 부분"처럼 풀되, 대사는 약을 처리하는 문맥에서만 "몸이 약을 처리하는 과정", 흡수는 해당 문맥에서 "약 성분이 몸 안으로 들어오는 과정"으로 설명하세요.
- 점막은 해당 문맥에서 "몸 안쪽을 덮고 있는 부드러운 층"처럼 설명하세요. 부정맥은 "심장 박동이 고르지 않은 상태", 심실은 "심장의 아래쪽 공간", QT 연장은 "심장이 다음 박동을 준비하는 시간이 길어지는 상태"처럼 쉬운 뜻을 같은 문장이나 바로 다음 문장에 설명하세요.
- 항콜린 작용은 해당 공식 근거 안에서 신경 신호의 한 종류를 막아 입 마름 같은 증상을 일으킬 수 있는 작용임을 쉽게 설명하세요. 비스테로이드성 소염진통제는 "스테로이드 성분 없이 통증과 염증을 줄이는 약"처럼 풀어 설명하세요. 공식 질환명·제품명·성분명 자체는 바꾸지 마세요.
- 배설은 "몸 밖으로 내보내는 과정", 분비는 "몸에서 특정 물질을 만들어 내보내는 과정", 효소는 "몸속에서 화학 작용을 돕는 물질", 혈중농도는 "피 속에 약 성분이 얼마나 있는지", 반감기는 "약 성분의 양이 절반으로 줄어드는 데 걸리는 시간"으로 설명하세요.
- 적응증은 "이 약을 사용하는 질환이나 증상", 금기는 "사용하면 안 되는 경우", 상호작용은 "함께 사용할 때 생길 수 있는 영향", 이상반응은 "약을 사용한 뒤 나타날 수 있는 증상"처럼 설명하세요. 심각한 위험이나 증상을 단순한 "불편함"으로 축소하지 마세요.
- DUR이라는 약어를 사용자 답변에 그대로 쓰지 말고 "약을 함께 사용할 때의 주의 정보를 확인하는 절차"처럼 설명하세요. 상호작용은 "약끼리 서로 영향을 주는 경우", 병용금기는 "함께 사용하면 안 되는 조합", 연령금기와 임부금기는 공식 자료의 나이 조건과 임신 관련 사용 금지·주의 내용을 그대로 풀어 설명하세요. 효능군중복은 "비슷한 효과의 약을 겹쳐 사용하는 경우"처럼 설명하세요.
- 융모질환·융모암·파괴포상기태·포상기태처럼 낯선 공식 병명이 있으면, 공식 효능 자료에 확인된 의미 안에서 쉬운 설명을 먼저 쓰세요. 병명이 꼭 필요하면 뒤에서 공식 병명을 한 번만 표시할 수 있습니다. 해당 약의 근거 없이 질환·작용을 만들어 설명하지 마세요.
- 고초열처럼 낯선 공식 질환명이 필요하면 처음 등장할 때 공식정보에서 확인되는 의미 안에서 짧고 쉬운 뜻을 괄호로 설명하세요. 근거에 없는 원인·증상·치료법을 추측해 덧붙이지 마세요.
- combination 질문에서는 서버가 확인한 함께 사용 주의와 성분·효과 중복을 한 번의 답변에서 설명하세요. 근거가 있는 내용만 "다른 약과 함께 사용할 때", "성분이나 역할이 겹치는 약", "확인하지 못한 내용"으로 구분하고, 없는 항목은 만들지 마세요.
- combination 답변의 첫 부분에는 DUR·병용금기·중복성분·효능군중복 같은 내부 분류명 대신 그 쉬운 뜻을 쓰세요. 정상적으로 확인한 0건과 자료 부족·조회 실패·미완료를 혼동하지 마세요.
- 아래의 정상 완료된 0건 안내가 있으면 문장의 뜻을 바꾸지 말고 한 번만 자연스럽게 포함하세요. 목록에 없는 항목을 0건이라고 추측하지 마세요. 다른 금기·주의·중복 결과가 제공되면 반드시 함께 설명하세요.
- 투여를 모든 경우에 복용으로 바꾸지 마세요. 용법은 "사용하는 방법"처럼 표현하고, 먹는 약·주사·바르는 약 등 공식 자료에 나온 사용 방식을 유지하세요. 알 수 없는 사용 방식이나 조건은 추측하지 마세요.
- 정확성을 위해 주성분, 복용량, 공식 의약품명·제품명·성분명은 원래 표현을 유지하세요. 그 명칭을 설명하는 문장만 쉬운 말로 쓰세요.
- 용량, 단위, 횟수, 기간, 연령 조건과 적용 대상, 금지·주의·예외 조건의 강도를 그대로 유지하세요. "사용하면 안 됨"을 "주의가 필요함"으로 완화하지 마세요.
- 문맥이 불분명하거나 정확하게 풀어 설명하기 어려우면 추측하지 말고, 해당 설명을 확인하기 어렵다고 알리며 의료적 판단을 단정하지 마세요. 설명이 어렵다는 이유로 공식 자료가 없다고 답하지 마세요. 공식 자료가 없는 경우에만 자료가 없다고 알리세요.
- 공식 자료의 일반 사용법은 일반 안내임을 분명히 하세요. 실제 등록 처방 정보가 제공된 경우에만 해당 처방에 근거해 설명하세요. 개인 처방 정보 없이 개인 복용량을 새로 정하지 말고, 일반 사용법을 개인 처방처럼 표현하지 마세요.
- 답변에 LLM, API, schema, prompt, Gemini 같은 내부 개발 용어를 출력하지 마세요. "안전합니다", "복용해도 됩니다"처럼 근거 없는 확정 표현을 사용하지 마세요.
- 정상 완료된 0건 안내 뒤에 "이 결과만으로 안전하다고 판단할 수 없어요" 또는 "모든 약 사용이 안전하다고 단정할 수 없어요" 같은 일반적인 문구를 붙이지 마세요. 추가 상담 안내가 실제로 필요하면 "더 궁금하시면 의사나 약사와 상담해 주세요."라고 한 번만 쓰세요.
- 조회 실패·분석 미완료·약 식별 실패에서는 확인하지 못한 범위를 분명히 말하고 0건이나 안전으로 표현하지 마세요. 복용 결정을 위해 상담이 필요하면 "복용 전 의사나 약사와 상담해 주세요."라고 안내하세요.
- 제공된 근거가 있는 경우에만, 구분이 실제로 필요할 때 "쉽게 말하면", "꼭 확인할 점"처럼 평범한 제목을 쓰세요.
- 해당 근거가 없거나 확인할 수 없는 항목은 제목과 내용을 만들지 마세요.
- 제목 아래에는 제공된 공식정보 또는 서버 DUR 결과만 설명하고, 원문의 의미를 바꾸지 마세요.
- 의사의 진단처럼 말하거나 복용 시작, 중단, 용량 변경을 지시하지 마세요.
- 실제로 추가 확인이 필요한 경우에만 의사 또는 약사에게 확인하도록 안내하세요. 같은 상담 문구를 모든 답변에 반복하지 마세요.
- 사용자에게 직접 호칭을 붙일 때는 "선생님"만 사용하세요. 답변의 첫 안내나 직접적인 권고에서 자연스럽게 한 번만 쓰고, 매 문장마다 반복하지 마세요. "어르신", "환자분", "고객님" 같은 다른 호칭은 사용하지 마세요.

[사용자 질문]
{message}

[질문 의도]
{', '.join(sorted(intents))}

[식약처 공식 의약품 정보]
{official_text}

[DUR 분석 결과 상태]
{dur_result['status']}

[식약처 DUR 서버 분석 결과]
{dur_text}

[정상 완료된 0건 안내]
{confirmed_zero_text}
""".strip()
