"""Chat flow: candidate extraction -> matching -> retrieval -> fixed/DB reply."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from app.services.matching.name_matcher import match_medicine_name
from app.services.mfds_drug_permission.db import search_permission_names
from app.services.pharmacist.generate import generate_from_source
from app.services.pharmacist.guard import guard_reply
from app.services.pharmacist.efficacy_display import display_efficacy_text
from app.services.pharmacist.retrieve import retrieve_official
from app.services.pharmacist.spell import extract_drug_name_candidates


@dataclass(frozen=True)
class ChatPipelineResult:
    ok: bool
    reply: str
    trace: dict[str, Any] = field(default_factory=dict)


def run_chat_pipeline(
    message: str,
    lexicon: list[str] | None = None,
    user_id: str | None = None,
) -> ChatPipelineResult:
    original = (message or "").strip()
    faq_kind = _faq_kind(original)
    if faq_kind == "together" and user_id:
        asked = None
        compact = "".join(original.casefold().split())
        if compact not in {"같이먹으면", "같이먹어도", "같이먹어도되나요"}:
            enriched = _enrich_lexicon(original, lexicon)
            cands = extract_drug_name_candidates(original, enriched)
            stop = {"같이", "먹으면", "먹어도", "되나요"}
            cands = [name for name in cands if name not in stop]
            if cands:
                if enriched:
                    match = match_medicine_name(cands[0], enriched, similar=False)
                    asked = match.matched_name or cands[0]
                else:
                    asked = cands[0]
        return _together_from_dur(user_id, original, asked_name=asked)

    enriched_lexicon = _enrich_lexicon(original, lexicon)
    candidates = extract_drug_name_candidates(original, enriched_lexicon)
    if not candidates:
        return _failure(original, "약 이름을 먼저 선택하거나 입력해주세요.", "spell")

    corrected = candidates[0]
    name_match_score: float | None = None
    name_match_method = "official_search"
    if enriched_lexicon:
        match = match_medicine_name(candidates[0], enriched_lexicon)
        if not match.matched_name and match.candidates:
            candidate_items = [
                {"label": name, "score": round(score * 100, 1)}
                for name, score in match.candidates[:5]
            ]
            return ChatPipelineResult(
                False,
                "혹시 이 약인가요? 아래에서 골라 주세요.",
                {
                    "original": original,
                    "corrected": None,
                    "candidates": candidate_items,
                    "name_match_score": round(match.score * 100, 1),
                    "name_match_method": "candidate",
                    "source": None,
                    "rejected": [],
                    "evidence_score": 0.0,
                    "stage": "match",
                },
            )
        if match.matched_name:
            corrected = match.matched_name
            name_match_score = round(match.score * 100, 1)
            name_match_method = match.method

    official = retrieve_official(corrected)
    if not official:
        return ChatPipelineResult(
            False,
            "공식 자료에서 그 약을 찾지 못했어요.",
            {
                "original": original,
                "corrected": corrected,
                "name_match_score": name_match_score,
                "name_match_method": name_match_method,
                "source": None,
                "rejected": [],
                "evidence_score": 0.0,
                "stage": "retrieve",
            },
        )

    official_name = official.get("medicine", {}).get("product_name")
    corrected = official_name or corrected
    source_label = _source_label(official)
    faq_kind = _faq_kind(original)
    reply = _fixed_db_reply(faq_kind, official, corrected)
    reply = _fixed_db_reply(faq_kind, official, corrected)
    # missed/together 는 안전 안내(추측)라 공식 출처·evidence 100 으로 위장하지 않음
    safety_only = faq_kind in {"missed", "together"}
    trace = {
        "original": original,
        "corrected": corrected,
        "name_match_score": name_match_score,
        "name_match_method": name_match_method,
        "source": official.get("source"),
        "source_label": None if safety_only else source_label,
        "rejected": [],
        "evidence_score": 0.0 if safety_only else 100.0,
        "stage": "fixed",
        "faq_kind": faq_kind,
    }
    if reply:
        body = reply if safety_only else _with_source(reply, source_label)
        return ChatPipelineResult(
            True,
            body,
            {**trace, "stage": "safety_fixed" if safety_only else "done"},
        )

    # 고정 답이 애매할 때만 생성→가드. 실패하면 원문 발췌로 대체.
    try:
        draft = generate_from_source(original, official)
        guarded = guard_reply(draft, official.get("source_text", ""))
        if guarded.allowed and guarded.reply.strip():
            return ChatPipelineResult(
                True,
                _with_source(guarded.reply, source_label),
                {
                    **trace,
                    "rejected": list(guarded.rejected),
                    "evidence_score": guarded.evidence_score,
                    "stage": "done",
                },
            )
    except Exception:
        pass

    fallback = _official_excerpt_reply(official, corrected)
    if fallback:
        return ChatPipelineResult(
            True,
            _with_source(fallback, source_label),
            {**trace, "stage": "excerpt"},
        )
    return ChatPipelineResult(
        False,
        "공식 자료로 안내할 내용이 부족해요. 의사·약사에게 확인해 주세요.",
        {**trace, "stage": "guard", "evidence_score": 0.0},
    )


def _enrich_lexicon(message: str, lexicon: list[str] | None) -> list[str]:
    """자동완성·허가DB 이름으로 사전을 보강해 오타(라이트장제수→라이트정제수)를 잡는다."""
    names: list[str] = []
    seen: set[str] = set()

    def _add(label: str) -> None:
        text = (label or "").strip()
        if text and text not in seen:
            seen.add(text)
            names.append(text)

    for label in lexicon or []:
        _add(label)

    # 사용자가 친 원문 토큰은 사전에 넣지 않는다.
    # (넣으면 exact 매칭되어 오타가 그대로 확정됨)
    tokens = extract_drug_name_candidates(message, None)
    for token in tokens:
        try:
            if len(token) >= 2:
                for hit in search_permission_names(token[:2], limit=8):
                    _add(hit)
            for hit in search_permission_names(token, limit=8):
                _add(hit)
        except Exception:
            continue
    return names


def _together_from_dur(user_id: str | None, original: str, asked_name: str | None = None) -> ChatPipelineResult:
    """챗봇 '같이 먹으면'은 최신 DUR 결과를 우선하고, 약이 바뀌었을 때만 다시 검사한다."""
    if not user_id:
        return ChatPipelineResult(
            False,
            "지금 드시는 약을 등록한 뒤, 약 함께먹기 주의에서 확인해 주세요.",
            {"original": original, "stage": "dur", "faq_kind": "together", "evidence_score": 0.0},
        )
    result: dict[str, Any] | None = None
    reused = False
    try:
        from app.models.schemas import DurAnalyzeRequest
        from app.services.chat_context_service import load_latest_dur_context
        from app.services.dur_service import analyze_dur, get_latest_dur

        ctx = load_latest_dur_context(user_id, {"combination"})
        if ctx.get("status") == "current":
            try:
                result = get_latest_dur(user_id)
                reused = True
            except Exception:
                result = None
        if result is None:
            result = analyze_dur(DurAnalyzeRequest(user_id=user_id, medicine_codes=[]))
    except Exception:
        return ChatPipelineResult(
            False,
            "지금은 함께먹기 검사를 하지 못했어요. 약 함께먹기 주의 화면에서 다시 살펴봐 주세요.",
            {"original": original, "stage": "dur", "faq_kind": "together", "evidence_score": 0.0},
        )

    names = [str(name) for name in (result.get("medicine_names") or []) if name]
    if not names:
        names = [
            str(item.get("product_name") or item.get("ingredient") or "").strip()
            for item in (result.get("medicines") or [])
            if isinstance(item, dict)
        ]
        names = [name for name in names if name]
    matches = result.get("matches") or []
    incomplete = bool(result.get("incomplete"))
    lines: list[str] = []
    if asked_name:
        compact_asked = "".join(asked_name.split())
        in_list = any(compact_asked and compact_asked in "".join(str(n).split()) for n in names)
        if not in_list:
            lines.append(f"{asked_name}은(는) 지금 등록된 약 목록에 없어요. 등록된 약 기준으로 살펴봤어요.")
    if not names:
        lines.append("살펴볼 등록 약이 아직 없어요. 처방전을 먼저 등록해 주세요.")
    elif matches:
        lines.append(str(result.get("message") or "함께 먹을 때 주의가 있어요."))
        for match in matches[:4]:
            reason = str(match.get("reason") or "").strip()
            if reason:
                lines.append(f"- {reason}")
        lines.append("자세한 건 약 함께먹기 주의 화면과 의사·약사에게 확인해 주세요.")
    elif incomplete:
        lines.append(str(result.get("message") or "함께먹기 검사를 끝까지 하지 못했어요."))
    else:
        lines.append("지금 등록된 약끼리, 특별한 함께먹기 주의는 없어요.")
        if names:
            lines.append("살펴본 약: " + ", ".join(names[:8]))
        lines.append("몸이 평소와 다르면 약국에 물어보세요.")

    return ChatPipelineResult(
        True,
        "\n".join(lines),
        {
            "original": original,
            "stage": "dur",
            "faq_kind": "together",
            "source": "식약처 DUR 검사",
            "source_label": None,
            "evidence_score": 0.0,
            "dur_match_count": len(matches),
            "incomplete": incomplete,
            "dur_reused": reused,
        },
    )


def _source_label(official: dict[str, Any]) -> str:
    """사용자에게 보여줄 출처 한 줄 (점수 없이)."""
    source = str(official.get("source") or "").strip()
    lowered = source.casefold()
    if "허가" in source or "permission" in lowered or "mfds" in lowered:
        return "식약처 의약품 허가정보에 의하면"
    if "e약은요" in source or "easy" in lowered:
        return "식약처 e약은요 안내에 의하면"
    if "local" in lowered or "로컬" in source:
        return "등록된 약 정보에 의하면"
    if source:
        return f"{source}에 의하면"
    return "공식 약 정보에 의하면"


def _with_source(reply: str, source_label: str) -> str:
    text = (reply or "").strip()
    label = (source_label or "").strip()
    if not text:
        return text
    if not label:
        return text
    # 이미 출처가 붙어 있으면 중복하지 않음
    if text.startswith(label) or "에 의하면" in text[:40]:
        return text
    return f"{label},\n{text}"


def _faq_kind(message: str) -> str | None:
    compact = "".join((message or "").casefold().split())
    if any(key in compact for key in ("안먹", "깜빡", "잊었", "어제안")):
        return "missed"
    if any(key in compact for key in ("같이먹", "겹쳐", "같이")):
        return "together"
    if any(key in compact for key in ("설명", "뭐야", "효능", "뭐에")):
        return "explain"
    if any(key in compact for key in ("언제먹", "복용", "어떻게먹", "밥전", "식후")):
        return "usage"
    return None


def _fixed_db_reply(kind: str | None, official: dict[str, Any], name: str) -> str | None:
    """DB/공식 필드만으로 정해진 답을 만든다. 추측 문장 금지."""
    med = official.get("medicine") or {}
    product = str(med.get("product_name") or name).strip()
    efficacy = display_efficacy_text(
        med.get("efficacy") or med.get("efficacy_text")
    ) or ""
    usage = _short_field(med.get("usage") or med.get("usage_text"))
    caution = display_efficacy_text(
        med.get("cautions") or med.get("caution_text") or med.get("precautions")
    ) or ""

    if kind == "missed":
        parts = [
            f"{product}{_object_particle(product)} 깜빡하고 안 드셨다면, 임의로 양을 늘려 드시지 마세요.",
            "다음 복용 때까지 기다릴지, 지금 드실지는 의사·약사에게 확인하는 게 안전해요.",
        ]
        if usage:
            parts.append(f"공식 복용 안내: {usage}")
        return "\n".join(parts)

    if kind == "together":
        return None

    if kind == "usage":
        if usage:
            return f"{product} 공식 복용 안내입니다.\n{usage}\n궁금하면 의사·약사에게 물어보세요."
        return (
            f"{product}의 자세한 복용 방법은 공식 자료에 짧게 안내되어 있지 않아요. "
            "의사·약사에게 확인하세요."
        )

    if kind == "explain":
        parts = [f"{product} 공식 안내입니다."]
        if efficacy:
            parts.append(f"효능: {efficacy}")
        if usage:
            parts.append(f"복용: {usage}")
        if caution:
            parts.append(f"주의: {caution}")
        if len(parts) == 1:
            return (
                f"{product}에 대해 보여줄 공식 요약이 부족해요. "
                "의사·약사에게 확인해 주세요."
            )
        parts.append("자세한 건 의사·약사에게 확인하세요.")
        return "\n".join(parts)

    return None


def _official_excerpt_reply(official: dict[str, Any], name: str) -> str | None:
    med = official.get("medicine") or {}
    product = str(med.get("product_name") or name).strip()
    efficacy = display_efficacy_text(
        med.get("efficacy") or med.get("efficacy_text")
    ) or ""
    usage = _short_field(med.get("usage") or med.get("usage_text"))
    if not efficacy and not usage:
        return None
    parts = [f"{product} 공식 자료 요약입니다."]
    if efficacy:
        parts.append(f"효능: {efficacy}")
    if usage:
        parts.append(f"복용: {usage}")
    parts.append("임의로 판단하지 말고 의사·약사에게 확인하세요.")
    return "\n".join(parts)


def _object_particle(name: str) -> str:
    """한글 받침에 따라 을/를 선택."""
    if not name:
        return "를"
    code = ord(name[-1])
    if 0xAC00 <= code <= 0xD7A3:
        return "을" if (code - 0xAC00) % 28 else "를"
    return "를"


def _short_field(value: Any, limit: int = 120) -> str:
    text = " ".join(str(value or "").split())
    if not text:
        return ""
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def _failure(original: str, reply: str, stage: str) -> ChatPipelineResult:
    return ChatPipelineResult(
        False,
        reply,
        {
            "original": original,
            "corrected": None,
            "name_match_score": None,
            "name_match_method": None,
            "source": None,
            "rejected": [],
            "evidence_score": 0.0,
            "stage": stage,
        },
    )
