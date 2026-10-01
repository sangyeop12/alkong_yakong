"""Generate a simple answer from verified medicine source text only."""

from __future__ import annotations

import json
from typing import Any

from app.core.config import GEMINI_API_KEY, GEMINI_MODEL
from app.services.pharmacist.guard import guard_reply


MAX_SENTENCES = 3
MAX_SENTENCE_CHARS = 80
MISSING_OFFICIAL_TEXT = "공식 정보에 명시되어 있지 않습니다."

CARD_SCHEMA = {
    "type": "object",
    "properties": {
        "easy_summary": {"type": "string"},
        "what_it_does": {"type": "string"},
        "how_to_take": {"type": "string"},
        "cautions": {"type": "array", "items": {"type": "string"}},
        "possible_side_effects": {
            "type": "array",
            "items": {"type": "string"},
        },
        "storage": {"type": "string"},
        "ask_doctor_when": {
            "type": "array",
            "items": {"type": "string"},
        },
        "source_based": {"type": "boolean"},
    },
    "required": [
        "easy_summary",
        "what_it_does",
        "how_to_take",
        "cautions",
        "possible_side_effects",
        "storage",
        "ask_doctor_when",
        "source_based",
    ],
    "additionalProperties": False,
}


def _sentences(text: str) -> list[str]:
    cleaned = (text or "").replace("!", ".").replace("?", ".")
    return [piece.strip() for piece in cleaned.split(".") if piece.strip()]


def validate_easy_output(text: str) -> str:
    """Keep at most 3 sentences and reject a sentence that is too long."""
    raw = (text or "").strip()
    sentences = _sentences(raw)
    if not sentences:
        raise ValueError("empty_reply")
    clipped = sentences[:MAX_SENTENCES]
    for sentence in clipped:
        if len(sentence) > MAX_SENTENCE_CHARS:
            raise ValueError("sentence_too_long")
    joined = ". ".join(clipped)
    if raw.endswith(".") or len(sentences) > 1 or len(clipped) > 1:
        joined += "."
    return joined


def generate_from_source(question: str, official: dict[str, Any]) -> str:
    source_text = str(official.get("source_text") or "").strip()
    if not source_text:
        raise ValueError("official source required")
    if not GEMINI_API_KEY:
        raise RuntimeError("GEMINI_API_KEY가 설정되지 않았습니다.")

    from google import genai

    prompt = (
        "공식 의약품 원문만 근거로 질문에 답하세요. "
        "문장은 3개 이내, 한 문장은 짧게. "
        "의학 용어가 있으면 괄호 없이 일상어로만 쓰세요. "
        "원문에 없는 효능, 복용법, 부작용, 숫자를 추가하지 마세요. "
        "진단하거나 처방하는 말투를 쓰지 마세요. "
        "근거가 부족하면 정확히 '공식 자료에 명시되어 있지 않습니다.'라고만 답하세요.\n\n"
        f"공식 원문:\n{source_text}\n\n질문:\n{question}"
    )
    with genai.Client(api_key=GEMINI_API_KEY) as client:
        response = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=prompt,
            config={"temperature": 0.0},
        )
    reply = str(getattr(response, "text", None) or "").strip()
    if not reply:
        raise RuntimeError("답변이 비어 있습니다.")
    return validate_easy_output(reply)


def generate_card_from_source(official_info: dict[str, Any]) -> dict[str, Any] | None:
    source_text = official_source_text(official_info)
    if not source_text:
        raise ValueError("official source required")
    if not GEMINI_API_KEY:
        raise RuntimeError("GEMINI_API_KEY가 설정되지 않았습니다.")

    from google import genai

    with genai.Client(api_key=GEMINI_API_KEY) as client:
        response = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=_card_prompt(official_info),
            config={
                "temperature": 0.1,
                "response_mime_type": "application/json",
                "response_json_schema": CARD_SCHEMA,
            },
        )
    parsed = getattr(response, "parsed", None)
    if parsed is None:
        response_text = str(getattr(response, "text", None) or "")
        try:
            parsed = json.loads(response_text) if response_text else None
        except json.JSONDecodeError:
            return None
    if not isinstance(parsed, dict):
        return None
    return apply_card_guard(parsed, source_text)


def official_source_text(official: dict[str, Any]) -> str:
    existing = str(official.get("source_text") or "").strip()
    if existing:
        return existing
    labels = (
        ("제품명", "product_name"),
        ("성분명", "ingredient"),
        ("효능/효과", "efficacy"),
        ("복용법", "usage"),
        ("주의사항", "cautions"),
        ("상호작용", "interaction"),
        ("부작용", "side_effects"),
        ("보관법", "storage"),
    )
    return "\n".join(
        f"{label}: {official[key]}"
        for label, key in labels
        if official.get(key)
    )


def apply_card_guard(parsed: dict[str, Any], source_text: str) -> dict[str, Any] | None:
    """Keep only card sentences that overlap the official source."""
    source = (source_text or "").strip()
    if not source:
        return None

    def _guard_text(value: Any) -> str:
        text = str(value or "").strip()
        if not text:
            return MISSING_OFFICIAL_TEXT
        guarded = guard_reply(text, source)
        if not guarded.allowed:
            return MISSING_OFFICIAL_TEXT
        try:
            return validate_easy_output(guarded.reply)
        except ValueError:
            return MISSING_OFFICIAL_TEXT

    def _guard_list(value: Any) -> list[str]:
        items = value if isinstance(value, list) else [value] if value else []
        kept: list[str] = []
        for item in items:
            text = str(item or "").strip()
            if not text:
                continue
            guarded = guard_reply(text, source)
            if guarded.allowed:
                kept.append(guarded.reply)
        return kept or [MISSING_OFFICIAL_TEXT]

    card = {
        "easy_summary": _guard_text(parsed.get("easy_summary")),
        "what_it_does": _guard_text(parsed.get("what_it_does")),
        "how_to_take": _guard_text(parsed.get("how_to_take")),
        "cautions": _guard_list(parsed.get("cautions")),
        "possible_side_effects": _guard_list(parsed.get("possible_side_effects")),
        "storage": _guard_text(parsed.get("storage")),
        "ask_doctor_when": [
            item
            for item in (
                str(value).strip()
                for value in (parsed.get("ask_doctor_when") or [])
            )
            if item
        ]
        or ["복용 중 이상 증상이 있으면 의사/약사와 상담하세요."],
        "source_based": True,
    }
    content_ok = any(
        card[key] != MISSING_OFFICIAL_TEXT
        for key in ("easy_summary", "what_it_does", "how_to_take", "storage")
    )
    if not content_ok:
        return None
    return card


def _card_prompt(official_info: dict[str, Any]) -> str:
    official_json = json.dumps(official_info, ensure_ascii=False, indent=2)
    return f"""
아래에 제공된 식약처 의약품 허가정보 원문만 근거로 고령자가 읽기 쉬운 약 설명 카드를 작성하세요.

반드시 지킬 조건:
- 공식 정보에 없는 내용을 추측하거나 일반 의학 지식으로 보충하지 마세요.
- 정보가 없으면 정확히 "{MISSING_OFFICIAL_TEXT}"라고 쓰세요.
- 어려운 의학 용어는 뜻을 바꾸지 않는 범위에서 쉬운 말로 바꾸세요.
- 짧고 분명한 한국어 문장을 사용하세요. 한 칸은 문장 3개 이내.
- 진단하거나 처방하는 것처럼 말하지 마세요.
- ask_doctor_when에는 이상 증상이 있거나 복용이 걱정될 때
  "의사/약사와 상담하세요"라는 안내를 반드시 포함하세요.
- source_based는 반드시 true로 반환하세요.
- 지정된 JSON 스키마 이외의 설명이나 마크다운을 출력하지 마세요.

공식 식약처 허가정보:
{official_json}
""".strip()
