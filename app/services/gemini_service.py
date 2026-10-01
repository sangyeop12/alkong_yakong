"""Compatibility wrappers. OCR lives in ocr/, cards in pharmacist/generate."""

import json
import logging
import re
import time
from pathlib import Path
from typing import Any

from fastapi import HTTPException

from app.core.config import GEMINI_API_KEY, GEMINI_MODEL
from app.services.pharmacist.generate import generate_card_from_source


logger = logging.getLogger(__name__)


INCOMPLETE_CHAT_REPLY = (
    "답변을 끝까지 준비하지 못했어요.\n"
    "잠시 후 다시 물어봐 주세요.\n"
    "그동안 약의 복용량이나 사용 방법을 임의로 바꾸지 마세요."
)

CHAT_RETRY_INSTRUCTION = """

[답변 다시 작성]
앞 답변을 이어 붙이거나 일부를 재사용하지 말고 처음부터 다시 작성하세요.
더 짧게 작성하되 핵심 안전 조건은 빼지 마세요.
첫 답변이 길었다면 같은 뜻의 반복, 일반적인 인사, 질문과 관련 없는 공식정보, 긴 맺음말을 빼고 처음부터 간결하게 다시 작성하세요.
앞 프롬프트의 분량 정책을 그대로 따라 일반 질문은 보통 2~3문장, 주의사항·부작용은 핵심 3~4문장으로 쓰고, 약 전체는 확인된 약마다 핵심 1문장을 우선하세요. 글자 수를 기준으로 답변을 기계적으로 자르지 마세요.
모든 문장을 끝까지 완성하고 결론을 첫 문장에 쓰세요.
공식정보의 숫자, 용량, 단위, 횟수, 기간, 연령, 금지·주의·예외 조건을 그대로 보존하세요.
확인하지 못한 약과 실제 검사 범위도 분량 목표보다 우선하여 보존하세요.
제품명과 성분명은 바꾸지 마세요.
어려운 의학 용어가 꼭 필요하면 처음 등장할 때 같은 문장이나 바로 다음 문장에서 쉬운 뜻을 설명하세요. 같은 답변에서 반복 설명하지 마세요.
사용자에게 직접 호칭을 붙일 때는 "선생님"만 자연스럽게 한 번 사용하세요.
""".strip()


def _compact_product_name(value: object) -> str:
    return "".join(str(value or "").split()).casefold()


def _with_official_permission_ingredient(
    medicine: dict[str, Any],
    *,
    required_fields: set[str] | None = None,
) -> dict[str, Any]:
    """정확히 일치하는 공식 허가정보에서 비어 있는 근거 필드만 보완한다."""
    from app.services.mfds_drug_permission.client import fetch_permission_detail
    from app.services.mfds_drug_permission.db import (
        DB_PATH,
        find_permission_product_by_item_seq,
        product_to_medicine,
    )
    from app.services.pharmacist.ingredient import (
        ingredient_keys,
        is_usable_ingredient,
    )

    code = str(medicine.get("medicine_code") or "").strip()
    expected_name = _compact_product_name(medicine.get("product_name"))
    local_db_available = Path(DB_PATH).is_file()
    local_exact_found = False
    local_ingredient_usable = False
    api_fallback_attempted = False
    api_call_succeeded = False
    exact_item_seq_match = False
    exact_product_name_match = False
    local_identity_matches = False
    if not code or not expected_name:
        logger.warning(
            "Permission ingredient diagnostic selected_code_present=%s "
            "local_db_available=%s local_exact_found=false "
            "local_ingredient_usable=false api_fallback_attempted=false "
            "api_call_succeeded=false exact_item_seq_match=false "
            "exact_product_name_match=false final_ingredient_usable=false "
            "ingredient_key_count=0",
            bool(code),
            local_db_available,
        )
        return medicine

    candidates: list[dict[str, Any]] = []
    try:
        local_row = find_permission_product_by_item_seq(code)
        if local_row:
            local_exact_found = True
            local_medicine = product_to_medicine(local_row)
            local_ingredient_usable = is_usable_ingredient(
                local_medicine.get("ingredient"),
                local_medicine.get("product_name"),
            )
            local_identity_matches = (
                str(local_medicine.get("medicine_code") or "").strip() == code
                and _compact_product_name(local_medicine.get("product_name"))
                == expected_name
            )
            candidates.append(local_medicine)
    except Exception as error:
        logger.warning(
            "Permission ingredient local_lookup_failed exception_type=%s",
            type(error).__name__,
        )

    required = required_fields or {"ingredient"}
    if (
        not candidates
        or not local_identity_matches
        or any(not candidates[0].get(field) for field in required)
    ):
        api_fallback_attempted = True
        try:
            detail = fetch_permission_detail(
                str(medicine.get("product_name") or ""),
                item_seq=code,
            )
            api_call_succeeded = True
            if detail:
                normalized_detail = {
                    str(key).lower(): value for key, value in detail.items()
                }
                candidates.append(product_to_medicine(normalized_detail))
        except Exception as error:
            logger.warning(
                "Permission ingredient permission_api_failed exception_type=%s",
                type(error).__name__,
            )

    result = medicine
    added_fields: dict[str, Any] = {}
    for candidate in candidates:
        code_matches = str(candidate.get("medicine_code") or "").strip() == code
        name_matches = (
            _compact_product_name(candidate.get("product_name")) == expected_name
        )
        exact_item_seq_match = exact_item_seq_match or code_matches
        exact_product_name_match = exact_product_name_match or name_matches
        if code_matches and name_matches:
            fallback_fields = (
                "ingredient",
                "manufacturer",
                "efficacy",
                "usage",
                "cautions",
                "precautions",
                "side_effects",
                "storage",
                "image_url",
            )
            added_fields = {
                field: candidate[field]
                for field in fallback_fields
                if not medicine.get(field) and candidate.get(field)
            }
            result = {
                **medicine,
                **added_fields,
                "_permission_identity_verified": True,
            }
            if (
                any(field != "ingredient" for field in added_fields)
                and medicine.get("source") == "e약은요"
            ):
                result["source"] = "e약은요 + 식약처 의약품 제품 허가정보"
            break

    final_ingredient_usable = is_usable_ingredient(
        result.get("ingredient"),
        result.get("product_name"),
    )
    logger.warning(
        "Permission ingredient diagnostic selected_code_present=true "
        "local_db_available=%s local_exact_found=%s "
        "local_ingredient_usable=%s api_fallback_attempted=%s "
        "api_call_succeeded=%s exact_item_seq_match=%s "
        "exact_product_name_match=%s final_ingredient_usable=%s "
        "ingredient_key_count=%d",
        local_db_available,
        local_exact_found,
        local_ingredient_usable,
        api_fallback_attempted,
        api_call_succeeded,
        exact_item_seq_match,
        exact_product_name_match,
        final_ingredient_usable,
        len(ingredient_keys(result.get("ingredient"))),
    )
    logger.warning(
        "Permission content diagnostic required_fields=%s exact_match=%s "
        "efficacy_present=%s dosage_present=%s precautions_present=%s "
        "side_effects_present=%s fallback_used=%s",
        sorted(required),
        bool(exact_item_seq_match and exact_product_name_match),
        bool(result.get("efficacy")),
        bool(result.get("usage")),
        bool(result.get("cautions")),
        bool(result.get("side_effects")),
        bool(result is not medicine and added_fields),
    )
    return result


def _required_official_fields(intents: set[str]) -> set[str]:
    fields: set[str] = set()
    if intents & {"efficacy", "overview"}:
        fields.add("efficacy")
    if intents & {"dosage", "usage"}:
        fields.add("usage")
    if "precautions" in intents:
        fields.add("cautions")
    if "side_effects" in intents:
        fields.add("side_effects")
    return fields


def _has_requested_official_content(
    medicine: dict[str, Any],
    intents: set[str],
) -> bool:
    required = _required_official_fields(intents)
    return bool(required) and all(medicine.get(field) for field in required)

CHAT_EXTRACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "drug_names": {
            "type": "array",
            "items": {"type": "string"},
            "description": "질문에 포함된 약품명 또는 성분명 목록 (없으면 빈 배열 반환)"
        }
    },
    "required": ["drug_names"],
    "additionalProperties": False,
}


def generate_easy_explanation(
    official_info: dict[str, Any],
) -> dict[str, Any] | None:
    try:
        return generate_card_from_source(official_info)
    except (ValueError, RuntimeError, ImportError, TypeError):
        return None


def _is_gemini_unavailable(error: Exception) -> bool:
    status_code = getattr(error, "status_code", None)
    code = getattr(error, "code", None)
    message = str(error).upper()
    return (
        status_code == 503
        or code == 503
        or ("503" in message and "UNAVAILABLE" in message)
    )


def _generate_content_with_retry(client, **kwargs):
    retry_delays = (1, 2)
    for attempt in range(len(retry_delays) + 1):
        try:
            return client.models.generate_content(**kwargs)
        except Exception as error:
            if not _is_gemini_unavailable(error) or attempt >= len(retry_delays):
                raise
            delay = retry_delays[attempt]
            logger.warning(
                "Gemini unavailable; retrying in %s second(s) (%s/2).",
                delay,
                attempt + 1,
            )
            time.sleep(delay)


def _read_response_text(response) -> str:
    try:
        return str(getattr(response, "text", None) or "")
    except Exception as error:
        logger.debug("Unable to read Gemini response.text: %s", error)
        return ""


def _strip_json_code_fence(response_text: str) -> str:
    stripped = response_text.strip()
    if not stripped.startswith("```"):
        return stripped

    first_newline = stripped.find("\n")
    if first_newline == -1:
        return stripped

    fenced_body = stripped[first_newline + 1 :]
    if fenced_body.rstrip().endswith("```"):
        fenced_body = fenced_body.rstrip()[:-3]
    return fenced_body.strip()


def _json_boundary_kind(response_text: str, *, first: bool) -> str:
    stripped = response_text.strip()
    if not stripped:
        return "empty"
    boundary = stripped[0] if first else stripped[-1]
    if boundary in "{}[]`":
        return boundary
    if boundary.isalpha():
        return "alphabetic"
    return "other"


def _gemini_part_kind(part) -> str:
    if getattr(part, "function_call", None) is not None:
        return "function_call"
    if isinstance(getattr(part, "text", None), str):
        return "thought_text" if getattr(part, "thought", False) else "text"
    return "other"


def _log_extraction_diagnostics(response, response_text: str) -> None:
    extracted_parsed = getattr(response, "parsed", None)
    candidates = getattr(response, "candidates", None) or []
    finish_reasons = []
    part_types = []
    part_count = 0

    for candidate in candidates:
        finish_reason = getattr(candidate, "finish_reason", None)
        if finish_reason is not None:
            finish_reasons.append(str(finish_reason))
        content = getattr(candidate, "content", None)
        parts = getattr(content, "parts", None) or []
        part_count += len(parts)
        part_types.extend(_gemini_part_kind(part) for part in parts)

    logger.warning(
        "Gemini extraction_parse_failed parsed_type=%s parsed_is_none=%s "
        "candidate_count=%d finish_reason=%s part_count=%d part_types=%s "
        "response_length=%d first_char_type=%s last_char_type=%s",
        type(extracted_parsed).__name__,
        extracted_parsed is None,
        len(candidates),
        ",".join(finish_reasons) or "none",
        part_count,
        ",".join(part_types) or "none",
        len(response_text),
        _json_boundary_kind(response_text, first=True),
        _json_boundary_kind(response_text, first=False),
    )


def _extract_drug_names(response) -> list[str]:
    extracted_parsed = getattr(response, "parsed", None)
    if hasattr(extracted_parsed, "model_dump"):
        extracted_parsed = extracted_parsed.model_dump()

    if extracted_parsed is None:
        response_text = _read_response_text(response)
        cleaned_text = _strip_json_code_fence(response_text)
        if cleaned_text:
            try:
                extracted_parsed = json.loads(cleaned_text)
            except (json.JSONDecodeError, TypeError):
                _log_extraction_diagnostics(response, response_text)
                return []
        else:
            _log_extraction_diagnostics(response, response_text)
            return []

    if not isinstance(extracted_parsed, dict):
        return []

    drug_names = extracted_parsed.get("drug_names", [])
    if not isinstance(drug_names, list):
        return []
    return [name.strip() for name in drug_names if isinstance(name, str) and name.strip()]


def _complete_response_text(response, *, response_text: str | None = None) -> str:
    primary_text = (
        _read_response_text(response) if response_text is None else response_text
    )
    if primary_text:
        return primary_text.strip()

    completed_parts = []
    for candidate in getattr(response, "candidates", None) or []:
        content = getattr(candidate, "content", None)
        for part in getattr(content, "parts", None) or []:
            part_text = getattr(part, "text", None)
            if part_text:
                completed_parts.append(str(part_text))
    return "".join(completed_parts).strip()


def _finish_reasons(response) -> list[str]:
    reasons = []
    direct_reason = getattr(response, "finish_reason", None)
    if direct_reason is not None:
        reasons.append(str(direct_reason))
    for candidate in getattr(response, "candidates", None) or []:
        reason = getattr(candidate, "finish_reason", None)
        if reason is not None:
            reasons.append(str(reason))
    return reasons


def _plain_chat_reply(value: str) -> str:
    """Remove AI reply markup only; preserve medicine text and clinical values."""
    text = value.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"(?m)^[ \t]*```(?:[A-Za-z][A-Za-z0-9_-]*)?[ \t]*$", "", text)
    text = re.sub(r"(?m)^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$", "", text)
    text = re.sub(r"(?m)^[ \t]{0,3}#{1,6}[ \t]+", "", text)
    text = re.sub(r"(?m)^[ \t]{0,3}>+[ \t]?", "", text)
    text = re.sub(r"(?m)^[ \t]{0,3}\d+[.)][ \t]+", "• ", text)
    text = re.sub(r"(?m)^[ \t]{0,3}[-*+][ \t]+", "• ", text)
    text = re.sub(r"\*\*([^*\n]+)\*\*", r"\1", text)
    text = re.sub(r"__([^\n]+?)__", r"\1", text)
    text = re.sub(r"(?<![\w*])\*([^*\s\n](?:[^*\n]*?[^*\s\n])?)\*(?!\*)", r"\1", text)
    text = re.sub(r"(?<![\w_])_([^_\s\n](?:[^_\n]*?[^_\s\n])?)_(?!_)", r"\1", text)
    text = re.sub(
        r'\[([^\]\n]+)\]\([^\s)]+(?:\s+"[^"]*")?\)',
        r"\1",
        text,
    )
    text = text.replace("`", "")
    text = "\n".join(
        re.sub(r"[ \t]{3,}", " ", line).rstrip() for line in text.split("\n")
    )
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def _has_balanced_delimiters(reply: str) -> bool:
    for opening, closing in (("(", ")"), ("[", "]"), ("{", "}"), ("“", "”"), ("‘", "’")):
        if reply.count(opening) != reply.count(closing):
            return False
    if reply.count('"') % 2:
        return False
    return True


def _has_complete_ending(reply: str) -> bool:
    if not reply:
        return False
    stripped = reply.rstrip()
    if not stripped or stripped.endswith((":", ";", ",", "·", "-", "–", "—", "/")):
        return False
    if re.search(
        r"(?:다만|하지만|특히|그리고|또는|따라서|또한|예를 들어|다음과 같은|"
        r"경우에는|때문에|그러므로|그러나|즉)$",
        stripped,
    ):
        return False
    if re.search(r"(?:은|는|이|가|을|를|에|에서|으로|와|과|의)$", stripped):
        return False
    return bool(
        re.search(
            r"(?:[.!?]|요|다|니다|세요|까요|죠|함|음|없음|있음)$",
            stripped,
        )
    )


_JARGON_EXPLANATION_HINTS = {
    "DUR": ("약을 함께 사용할 때", "주의 정보를 확인"),
    "상호작용": ("약끼리 서로 영향을", "함께 사용할 때 생길 수 있는 영향"),
    "금기": ("사용하면 안", "함께 사용하면 안", "피해야 하는"),
    "효능군중복": ("비슷한 효과의 약",),
    "효능군 중복": ("비슷한 효과의 약",),
    "융모": ("장 안쪽의 작은 돌기",),
    "점막": ("몸 안쪽을 덮", "몸의 안쪽을 덮"),
    "심실": ("심장의 아래쪽 공간",),
    "QT 연장": ("다음 박동을 준비하는 시간이 길",),
    "항콜린": ("신경 신호", "입 마름"),
    "비스테로이드성 소염진통제": ("스테로이드 성분 없이",),
    "대사": ("몸이 약을 처리하는 과정",),
    "수용체": ("약 성분이 작용하는 몸속 부분",),
    "고초열": ("꽃가루", "알레르기"),
}

_JARGON_DIAGNOSTIC_CODES = {
    "DUR": "dur_abbreviation",
    "상호작용": "interaction_term",
    "금기": "contraindication_term",
    "효능군중복": "therapeutic_duplication_term",
    "효능군 중복": "therapeutic_duplication_term",
    "융모": "villus_term",
    "점막": "mucosa_term",
    "심실": "ventricle_term",
    "QT 연장": "qt_interval_term",
    "항콜린": "anticholinergic_term",
    "비스테로이드성 소염진통제": "nsaid_term",
    "대사": "metabolism_term",
    "수용체": "receptor_term",
    "고초열": "hay_fever_term",
}


def _sentence_windows(reply: str, term: str) -> list[str]:
    """용어가 나온 문장과 바로 앞·뒤 문장만 반환한다."""
    sentences = [
        sentence.strip()
        for sentence in re.split(r"(?<=[.!?。！？])\s+|\n+", reply)
        if sentence.strip()
    ]
    return [
        " ".join(sentences[max(0, index - 1) : index + 2])
        for index, sentence in enumerate(sentences)
        if term in sentence
    ]


def _has_meaningful_parenthetical(window: str, term: str) -> bool:
    """용어 직후 괄호가 반복어가 아닌 실제 쉬운 설명인지 보수적으로 본다."""
    pattern = rf"{re.escape(term)}\s*[（(]([^()（）]{{2,100}})[）)]"
    for match in re.finditer(pattern, window):
        explanation = match.group(1).strip()
        normalized_explanation = re.sub(r"[^0-9A-Za-z가-힣]", "", explanation).casefold()
        normalized_term = re.sub(r"[^0-9A-Za-z가-힣]", "", term).casefold()
        if not normalized_explanation or normalized_explanation == normalized_term:
            continue
        if len(re.findall(r"[가-힣]", explanation)) < 5:
            continue
        if re.search(r"상태|현상|과정|공간|부분|영향|신호|약|몸|심장|장|피부", explanation):
            return True
    return False


def _jargon_occurrence_is_explained(window: str, term: str, hints: tuple[str, ...]) -> bool:
    return any(hint in window for hint in hints) or _has_meaningful_parenthetical(
        window, term
    )


def _unexplained_jargon(reply: str) -> list[str]:
    unexplained = []
    for term, hints in _JARGON_EXPLANATION_HINTS.items():
        windows = _sentence_windows(reply, term)
        if windows and not _jargon_occurrence_is_explained(windows[0], term, hints):
            unexplained.append(term)
    return unexplained


def _chat_response_quality(
    response,
    *,
    required_medicine_names: tuple[str, ...] = (),
    forbidden_phrases: tuple[str, ...] = (),
) -> tuple[str, bool, list[str]]:
    response_text = _read_response_text(response)
    logger.debug("Gemini response.text length: %d", len(response_text))

    reasons = _finish_reasons(response)
    if reasons:
        logger.debug("Gemini finish_reason: %s", ", ".join(reasons))

    reply = _plain_chat_reply(
        _complete_response_text(response, response_text=response_text)
    )
    logger.debug("Gemini final reply length: %d", len(reply))

    has_valid_ending = _has_complete_ending(reply)
    candidate_value = getattr(response, "candidates", None)
    candidates = candidate_value or []
    part_count = sum(
        len(getattr(getattr(candidate, "content", None), "parts", None) or [])
        for candidate in candidates
    )
    usage_metadata = getattr(response, "usage_metadata", None)
    logger.warning(
        "Gemini final_response_diagnostic response_length=%d candidate_count=%d "
        "finish_reason=%s part_count=%d valid_ending=%s "
        "prompt_token_count=%s candidates_token_count=%s "
        "thoughts_token_count=%s total_token_count=%s",
        len(reply),
        len(candidates),
        ",".join(reasons) or "none",
        part_count,
        has_valid_ending,
        getattr(usage_metadata, "prompt_token_count", None),
        getattr(usage_metadata, "candidates_token_count", None),
        getattr(usage_metadata, "thoughts_token_count", None),
        getattr(usage_metadata, "total_token_count", None),
    )
    quality_issues = []
    normalized_reasons = {reason.upper() for reason in reasons}
    if any("MAX_TOKENS" in reason or "LENGTH" in reason for reason in normalized_reasons):
        quality_issues.append("token_limit")
    if any(
        marker in reason
        for reason in normalized_reasons
        for marker in ("SAFETY", "BLOCK", "RECITATION", "PROHIBITED", "SPII")
    ):
        quality_issues.append("blocked_finish")
    if candidate_value is not None and not candidates:
        quality_issues.append("no_candidate")
    if not reply:
        quality_issues.append("empty_reply")
    if not has_valid_ending:
        quality_issues.append("incomplete_ending")
    if not _has_balanced_delimiters(reply):
        quality_issues.append("unbalanced_delimiter")
    jargon = _unexplained_jargon(reply)
    if jargon:
        quality_issues.append("unexplained_jargon")
    compact_reply = _compact_product_name(reply)
    if any(
        _compact_product_name(name) not in compact_reply
        for name in required_medicine_names
        if _compact_product_name(name)
    ):
        quality_issues.append("missing_medicine_coverage")
    if any(phrase in reply for phrase in forbidden_phrases if phrase):
        quality_issues.append("wrong_medicine_scope")
    if quality_issues:
        jargon_codes = sorted(
            {
                _JARGON_DIAGNOSTIC_CODES.get(term, "other_medical_term")
                for term in jargon
            }
        )
        logger.warning(
            "Gemini response rejected: length=%d issues=%s jargon_count=%d "
            "jargon_codes=%s",
            len(reply),
            ",".join(quality_issues),
            len(jargon),
            ",".join(jargon_codes) or "none",
        )
    return reply, not quality_issues, quality_issues


def _finalize_chat_response(response) -> str:
    reply, is_complete, _ = _chat_response_quality(response)
    return reply if is_complete else INCOMPLETE_CHAT_REPLY


def _generate_complete_chat_reply(
    client,
    *,
    prompt: str,
    max_output_tokens: int = 512,
    required_medicine_names: tuple[str, ...] = (),
    forbidden_phrases: tuple[str, ...] = (),
) -> str:
    config = {
        "temperature": 0.2,
        "max_output_tokens": max_output_tokens,
        "thinking_config": {"thinking_budget": 0},
    }
    first_response = _generate_content_with_retry(
        client,
        model=GEMINI_MODEL,
        contents=prompt,
        config=config,
    )
    first_reply, is_complete, issues = _chat_response_quality(
        first_response,
        required_medicine_names=required_medicine_names,
        forbidden_phrases=forbidden_phrases,
    )
    if is_complete:
        return first_reply

    logger.warning("Gemini chat quality retry issues=%s", ",".join(issues))
    retry_config = dict(config)
    if "token_limit" in issues:
        retry_config["max_output_tokens"] = min(
            max(max_output_tokens * 2, 1024),
            2048,
        )
    retry_response = _generate_content_with_retry(
        client,
        model=GEMINI_MODEL,
        contents=f"{prompt}\n\n{CHAT_RETRY_INSTRUCTION}",
        config=retry_config,
    )
    retry_reply, is_complete, retry_issues = _chat_response_quality(
        retry_response,
        required_medicine_names=required_medicine_names,
        forbidden_phrases=forbidden_phrases,
    )
    if is_complete:
        return retry_reply
    if retry_reply and set(retry_issues) == {"unexplained_jargon"}:
        logger.warning(
            "Gemini reply accepted after jargon-only retry rejection"
        )
        return retry_reply
    return INCOMPLETE_CHAT_REPLY


def _all_medicine_unverified_notice(
    *,
    unverified_names: list[str],
    identity_incomplete: bool,
) -> str:
    if not unverified_names and not identity_incomplete:
        return ""
    return "일부 약은 공식정보를 확인하지 못해 답변에서 제외했어요."


def _dur_context_unavailable_reply(
    intents: set[str],
    status: str,
    reason: str | None = None,
    *,
    all_medicines: bool = False,
) -> str:
    message = _dur_context_unavailable_message(
        intents,
        status,
        reason,
        all_medicines=all_medicines,
    )
    return f"{message} 복용 전 의사나 약사와 상담해 주세요."


def _dur_context_unavailable_message(
    intents: set[str],
    status: str,
    reason: str | None = None,
    *,
    all_medicines: bool = False,
) -> str:
    if "combination" in intents:
        if reason == "official_medicine_unavailable":
            return (
                "선택한 약의 성분을 공식 자료에서 확인하지 못했어요. "
                "함께 사용할 때 주의할 점과 겹치는 약을 모두 확인하지 못했으니 다시 확인이 필요해요."
            )
        if reason == "dur_data_unavailable":
            return (
                "지금은 함께 사용할 때 주의할 공식 정보와 겹치는 약 정보를 모두 확인하지 못했어요. "
                "잠시 후 다시 확인해 주세요."
            )
        if status == "missing":
            return (
                "함께 사용할 때 주의할 점과 겹치는 약 정보를 확인한 결과를 찾지 못했어요. "
                "현재 복용약으로 다시 확인이 필요해요."
            )
        if status == "stale":
            return (
                "복용 중인 약이 바뀌어 이전 결과를 그대로 사용하기 어려워요. "
                "함께 사용할 때 주의할 점과 겹치는 약을 다시 확인해야 해요."
            )
        if status == "incomplete":
            if all_medicines:
                return "현재 복용약 전체의 함께 사용 주의와 겹치는 약 검사를 끝까지 완료하지 못했어요."
            return (
                "현재 복용 중인 약과 선택한 약의 함께 사용 주의 및 겹치는 약 정보를 "
                "모두 확인하지 못했어요."
            )
        if status == "malformed":
            return "함께 사용할 때 주의할 점과 겹치는 약의 검사 결과를 모두 확인하지 못했어요."
        if all_medicines:
            return (
                "현재 복용약 전체의 함께 사용 주의와 겹치는 약 정보를 모두 확인하지 못했어요. "
                "현재 복용약으로 다시 확인이 필요해요."
            )
        return (
            "현재 복용 중인 약과 선택한 약의 함께 사용 주의 및 겹치는 약 정보를 "
            "모두 확인하지 못했어요. 현재 복용약으로 다시 확인이 필요해요."
        )
    if "interaction" in intents:
        if status == "missing":
            return (
                "현재 복용 중인 약에 함께 사용하면 안 되는 조합이 있는지 확인한 결과를 찾지 못했어요. "
                "현재 복용약으로 다시 확인이 필요해요."
            )
        return (
            "복용 중인 약이 바뀌어 이전 결과를 그대로 사용하기 어려워요. "
            "함께 사용하면 안 되는 조합이 있는지 다시 확인이 필요해요."
        )
    if "age" in intents:
        if status == "missing":
            return (
                "현재 사용자 기준으로 나이에 따른 약 사용 제한을 확인한 결과를 찾지 못했어요. "
                "현재 복용약으로 다시 확인이 필요해요."
            )
        return (
            "복용 중인 약이 바뀌어 이전 결과를 그대로 사용하기 어려워요. "
            "나이에 따른 약 사용 제한을 다시 확인해야 해요."
        )
    if "pregnancy" in intents:
        if status == "missing":
            return (
                "현재 사용자 기준으로 임신 중 약 사용 제한을 확인한 결과를 찾지 못했어요. "
                "현재 복용약으로 다시 확인이 필요해요."
            )
        return (
            "복용 중인 약이 바뀌어 이전 결과를 그대로 사용하기 어려워요. "
            "임신 중 약 사용 제한을 다시 확인해야 해요."
        )
    if "duplicate" in intents:
        if reason == "official_medicine_unavailable":
            return (
                "선택한 약의 성분을 공식 자료에서 확인하지 못했어요. "
                "성분이나 효과가 겹치는지 확인할 수 없어요."
            )
        if reason == "dur_data_unavailable":
            return (
                "지금은 약을 함께 사용할 때 주의할 공식 정보를 확인하지 못했어요. "
                "잠시 후 다시 시도해 주세요."
            )
        if status == "missing":
            return (
                "현재 복용 중인 약에서 비슷한 효과가 겹치는지 확인한 결과를 찾지 못했어요. "
                "현재 복용약으로 다시 확인이 필요해요."
            )
        if status == "incomplete":
            return "현재 복용약의 성분이나 비슷한 효과가 겹치는지 검사를 끝까지 완료하지 못했어요."
        if status == "malformed":
            return (
                "현재 복용약의 성분이나 비슷한 효과가 겹치는지 검사한 결과를 확인하지 못했어요. "
                "현재 복용약으로 다시 확인이 필요해요."
            )
        if status == "stale":
            return (
                "복용 중인 약이 바뀌어 이전 결과를 그대로 사용하기 어려워요. "
                "비슷한 효과가 겹치는지 다시 확인이 필요해요."
            )
        return (
            "현재 복용약의 성분이나 비슷한 효과가 겹치는지 확인하지 못했어요. "
            "현재 복용약으로 다시 확인이 필요해요."
        )
    return (
        "현재 약 사용 시 주의할 내용을 확인한 결과를 찾지 못했어요. "
        "현재 복용약으로 다시 확인이 필요해요."
        if status == "missing"
        else "복용 중인 약이 바뀌어 다시 확인이 필요해요."
    )


def _confirmed_zero_messages(
    intents: set[str],
    dur_result: dict[str, Any],
    *,
    selected_medicine: dict[str, Any] | None,
) -> list[str]:
    if dur_result.get("status") != "current":
        return []
    zero_types = {
        str(value or "").strip()
        for value in dur_result.get("zero_result_types") or []
    }
    messages = []
    if intents & {"combination", "interaction"} and "병용금기" in zero_types:
        messages.append(
            "선택한 약과 지금 드시는 약 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요."
            if selected_medicine is not None
            else "확인한 약들 사이에서 함께 먹으면 안 되는 조합은 확인되지 않았어요."
        )
    user_context = dur_result.get("user_context") or {}
    if (
        "age" in intents
        and "연령금기" in zero_types
        and user_context.get("age_known") is True
    ):
        messages.append("확인된 나이를 기준으로, 사용하면 안 되는 약은 확인되지 않았어요.")
    if (
        "pregnancy" in intents
        and "임부금기" in zero_types
        and user_context.get("pregnancy_status") == "pregnant"
    ):
        messages.append("임신 중 사용하면 안 되는 약은 확인되지 않았어요.")
    return messages


def _dur_no_match_reply(
    intents: set[str],
    dur_result: dict[str, Any] | None = None,
    *,
    selected_medicine: dict[str, Any] | None = None,
) -> str:
    result = dur_result or {}
    zero_messages = _confirmed_zero_messages(
        intents,
        result,
        selected_medicine=selected_medicine,
    )
    if "age" in intents and not zero_messages:
        return (
            "생년월일을 확인할 수 없어 나이를 기준으로 사용하면 안 되는 약이 있는지 "
            "끝까지 확인하지 못했어요. 복용 전 의사나 약사와 상담해 주세요."
        )
    if (
        "pregnancy" in intents
        and not zero_messages
        and (result.get("user_context") or {}).get("pregnancy_status")
        == "not_pregnant"
    ):
        return (
            "현재 임신 중이 아닌 것으로 확인되어 임신 중 사용 제한 결과를 "
            "개인 검사 결과로 안내하지 않았어요."
        )
    if "pregnancy" in intents and not zero_messages:
        return (
            "임신 여부를 확인할 수 없어 임신 중 사용하면 안 되는 약이 있는지 "
            "끝까지 확인하지 못했어요. 복용 전 의사나 약사와 상담해 주세요."
        )
    if zero_messages:
        if "combination" in intents and selected_medicine is None:
            return " ".join(
                [*zero_messages, "더 궁금한 점이 있으면 의사나 약사와 상담해 주세요."]
            )
        return " ".join(
            [*zero_messages, "더 궁금하시면 의사나 약사와 상담해 주세요."]
        )
    if "duplicate" in intents:
        if selected_medicine is None and "중복성분" in {
            str(value or "").strip()
            for value in result.get("zero_result_types") or []
        }:
            return (
                "확인한 약들 사이에서 같은 성분의 중복은 확인되지 않았어요. "
                "더 궁금한 점이 있으면 의사나 약사와 상담해 주세요."
            )
        scope = (
            "현재 복용 중인 약들 사이에서 성분이나 비슷한 효과가 겹친다는 정보를 "
            if selected_medicine is None
            else "현재 복용 중인 약과 선택한 약 사이에서 성분이나 비슷한 효과가 겹친다는 정보를 "
        )
        return scope + (
            "확인한 공식 자료에서는 찾지 못했어요. "
            "더 궁금하시면 의사나 약사와 상담해 주세요."
        )
    return (
        "현재 약 사용 시 주의할 내용을 끝까지 확인하지 못했어요. "
        "복용 전 의사나 약사와 상담해 주세요."
    )


def _prepend_confirmed_zero_messages(reply: str, messages: list[str]) -> str:
    if not messages or reply == INCOMPLETE_CHAT_REPLY:
        return reply
    missing = [message for message in messages if message not in reply]
    return "\n".join([*missing, reply]) if missing else reply


def _merge_temporary_medicines(
    context: dict[str, Any],
    temporary_medicines: list[dict[str, Any]],
) -> dict[str, Any]:
    """Merge AI-screen-only medicines without changing the medication source of truth."""

    status = str(context.get("status") or "missing")
    if status not in {"current", "empty", "incomplete"}:
        return context

    items = [dict(item) for item in context.get("items") or [] if isinstance(item, dict)]
    by_code = {
        str(item.get("medicine_code") or "").strip(): item
        for item in items
        if str(item.get("medicine_code") or "").strip()
    }
    incomplete = status == "incomplete"
    for medicine in temporary_medicines:
        if not isinstance(medicine, dict):
            incomplete = True
            continue
        code = str(medicine.get("medicine_code") or "").strip()
        name = str(medicine.get("product_name") or "").strip()
        if not code or not name:
            incomplete = True
            continue
        existing = by_code.get(code)
        if existing is not None:
            if _compact_product_name(existing.get("product_name")) != _compact_product_name(name):
                incomplete = True
            continue
        row = {"medicine_code": code, "product_name": name}
        by_code[code] = row
        items.append(row)

    if not items:
        return {"status": "empty", "items": [], "reason": "no_current_medicines"}
    return {
        "status": "incomplete" if incomplete else "current",
        "items": items,
        "reason": "medicine_identity_incomplete" if incomplete else None,
    }


def _selected_medicines_context(
    selected_medicines: list[dict[str, Any]],
) -> dict[str, Any]:
    """Build an exact AI-screen selection scope without loading all current medicines."""

    items: list[dict[str, str]] = []
    names_by_code: dict[str, str] = {}
    incomplete = len(selected_medicines) < 2
    for medicine in selected_medicines:
        if not isinstance(medicine, dict):
            incomplete = True
            continue
        code = str(medicine.get("medicine_code") or "").strip()
        name = str(medicine.get("product_name") or "").strip()
        if not code or not name:
            incomplete = True
            continue
        previous_name = names_by_code.get(code)
        if previous_name is not None:
            if _compact_product_name(previous_name) != _compact_product_name(name):
                incomplete = True
            continue
        names_by_code[code] = name
        items.append({"medicine_code": code, "product_name": name})

    if len(items) != len(selected_medicines):
        incomplete = True
    return {
        "status": "incomplete" if incomplete else "current",
        "items": items,
        "reason": "medicine_identity_incomplete" if incomplete else None,
    }


def generate_chat_response(
    message: str,
    *,
    user_id: str = "",
    selected_medicine: dict[str, Any] | None = None,
    selected_medicines: list[dict[str, Any]] | None = None,
    temporary_medicines: list[dict[str, Any]] | None = None,
    intent: str | None = None,
) -> str:
    from app.services.chat_context_service import (
        DUR_TYPES_BY_INTENT,
        AMBIGUOUS_QUESTION_REPLY,
        MEDICINE_SELECTION_REQUIRED_REPLY,
        UNRELATED_QUESTION_REPLY,
        build_general_medication_prompt,
        build_grounded_chat_prompt,
        classify_question_scope,
        enrich_dur_matches,
        general_conversation_reply,
        is_safety_question,
        load_latest_dur_context,
        resolve_question_intents,
        select_official_context,
    )

    if general_reply := general_conversation_reply(message):
        return general_reply

    general_medication_question = False
    if selected_medicine is None and intent is None:
        question_scope = classify_question_scope(message)
        if question_scope == "unrelated":
            return UNRELATED_QUESTION_REPLY
        if question_scope == "ambiguous":
            return AMBIGUOUS_QUESTION_REPLY
        if question_scope == "needs_medicine":
            return MEDICINE_SELECTION_REQUIRED_REPLY
        general_medication_question = question_scope == "general_medication"

    intents = resolve_question_intents(message, intent)
    safety_question = is_safety_question(intents)
    compact_message = "".join(str(message or "").split())
    all_medicines_question = (
        selected_medicine is None
        and intent in {"overview", "combination", "duplicate", "precautions"}
        and any(
            marker in compact_message
            for marker in ("현재먹는약전체", "복용약전체", "약전체", "약마다")
        )
    )
    selected_medicines_question = (
        selected_medicine is None and len(selected_medicines or []) >= 2
    )
    unavailable_reply = (
        "현재 확인된 식약처 정보만으로는 답변하기 어려워요. "
        "현재 복용약으로 다시 확인하고, 복용 중인 약 전체를 의사 또는 약사에게 알려 주세요."
        if safety_question
        else "현재 식약처 공식정보를 확인할 수 없어 답변하기 어려워요. 잠시 후 다시 시도해 주세요."
    )
    if not GEMINI_API_KEY:
        return unavailable_reply

    try:
        from google import genai
        from app.services.dur_service import analyze_dur_consultation
        from app.services.external_api_service import (
            fetch_e_drug_info,
            search_drug_info_by_name,
        )

        if general_medication_question:
            with genai.Client(api_key=GEMINI_API_KEY) as client:
                return _generate_complete_chat_reply(
                    client,
                    prompt=build_general_medication_prompt(message),
                    max_output_tokens=512,
                )

        selected_official = None
        official_data_list = []
        question_official_medicines: list[dict[str, str]] = []
        official_search_failure_count = 0
        official_search_empty_count = 0
        all_medicines_context = None
        verified_all_medicine_names: list[str] = []
        unverified_all_medicine_names: list[str] = []
        if all_medicines_question or selected_medicines_question:
            from app.services.medication_feature_dur_client import (
                load_remote_current_medicines,
            )

            if selected_medicines_question:
                all_medicines_context = _selected_medicines_context(
                    selected_medicines or []
                )
            else:
                all_medicines_context = load_remote_current_medicines(user_id=user_id)
                all_medicines_context = _merge_temporary_medicines(
                    all_medicines_context,
                    temporary_medicines or [],
                )
            all_status = all_medicines_context.get("status")
            all_items = all_medicines_context.get("items") or []
            if all_status == "empty":
                return "현재 등록되어 복용 중인 약이 없어요. 약을 등록한 뒤 다시 물어봐 주세요."
            if all_status in {"missing", "malformed"}:
                return (
                    "현재 복용약 목록을 불러오지 못했어요. 잠시 후 다시 시도해 주세요. "
                    "복용 전 의사나 약사와 상담해 주세요."
                )
            if selected_medicines_question and all_status == "incomplete":
                return (
                    "선택한 약 중 공식 제품명과 코드를 확인하지 못한 약이 있어 "
                    "검사를 끝까지 진행하지 못했어요. 약을 다시 선택해 주세요."
                )
            if not all_items:
                return (
                    "현재 복용약의 공식 제품명과 코드를 확인하지 못했어요. "
                    "확인되지 않은 약을 추측해서 설명하지 않을게요."
                )

            required_fields = (
                {"ingredient"}
                if intents & {"combination", "duplicate"}
                else _required_official_fields(intents)
            )
            for medicine in all_items:
                code = str(medicine.get("medicine_code") or "").strip()
                name = str(medicine.get("product_name") or "").strip()
                verified = None
                if code.isdigit() and name:
                    try:
                        candidate = fetch_e_drug_info(medicine_code=code)
                    except Exception as error:
                        logger.warning(
                            "All-medicine e_drug_lookup_failed error_type=%s",
                            type(error).__name__,
                        )
                        candidate = None
                    if (
                        candidate
                        and str(candidate.get("medicine_code") or "").strip() == code
                        and _compact_product_name(candidate.get("product_name"))
                        == _compact_product_name(name)
                    ):
                        verified = candidate
                        if any(
                            not verified.get(field) for field in required_fields
                        ):
                            verified = _with_official_permission_ingredient(
                                verified,
                                required_fields=required_fields,
                            )
                    if verified is None:
                        permission_candidate = _with_official_permission_ingredient(
                            {
                                "medicine_code": code,
                                "product_name": name,
                                "source": "식약처 의약품 제품 허가정보",
                            },
                            required_fields=required_fields,
                        )
                        if (
                            permission_candidate.get("_permission_identity_verified")
                            and _compact_product_name(permission_candidate.get("product_name"))
                            == _compact_product_name(name)
                        ):
                            verified = permission_candidate
                if verified and (
                    intents & {"combination", "duplicate"}
                    or _has_requested_official_content(verified, intents)
                ):
                    verified_all_medicine_names.append(name)
                    official_data_list.append(
                        {
                            "검색된_약품명": verified["product_name"],
                            "match_type": "exact",
                            "식약처_공식정보": verified,
                        }
                    )
                else:
                    unverified_all_medicine_names.append(name or "이름을 확인하지 못한 약")
        if selected_medicine is not None:
            required_fields = (
                {"ingredient"}
                if safety_question
                else _required_official_fields(intents)
            )
            selected_code = str(
                selected_medicine.get("medicine_code") or ""
            ).strip()
            selected_name = str(
                selected_medicine.get("product_name") or ""
            ).strip()
            e_drug_exact = False
            if selected_code.isdigit() and selected_name:
                try:
                    selected_official = fetch_e_drug_info(
                        medicine_code=selected_code,
                    )
                except Exception as error:
                    logger.warning(
                        "Selected medicine e_drug_lookup_failed error_type=%s",
                        type(error).__name__,
                    )
                e_drug_exact = bool(
                    selected_official
                    and selected_official.get("medicine_code") == selected_code
                    and _compact_product_name(
                        selected_official.get("product_name")
                    )
                    == _compact_product_name(selected_name)
                )

            if e_drug_exact:
                if any(not selected_official.get(field) for field in required_fields):
                    selected_official = _with_official_permission_ingredient(
                        selected_official,
                        required_fields=required_fields,
                    )
            elif selected_code.isdigit() and selected_name:
                permission_candidate = _with_official_permission_ingredient(
                    {
                        "medicine_code": selected_code,
                        "product_name": selected_name,
                        "source": "식약처 의약품 제품 허가정보",
                    },
                    required_fields=required_fields,
                )
                from app.services.pharmacist.ingredient import (
                    is_usable_ingredient,
                )

                permission_usable = (
                    is_usable_ingredient(
                        permission_candidate.get("ingredient"),
                        permission_candidate.get("product_name"),
                    )
                    if safety_question
                    else bool(
                        permission_candidate.get("_permission_identity_verified")
                        and _has_requested_official_content(
                            permission_candidate,
                            intents,
                        )
                    )
                )
                if permission_usable:
                    selected_official = permission_candidate
                else:
                    selected_official = None
            else:
                selected_official = None

            if not selected_official:
                return (
                    _dur_context_unavailable_reply(
                        intents,
                        "missing",
                        "official_medicine_unavailable",
                    )
                    if safety_question
                    else unavailable_reply
                )
            if (
                not safety_question
                and not _has_requested_official_content(selected_official, intents)
            ):
                return unavailable_reply
            official_data_list.append(
                {
                    "검색된_약품명": selected_official["product_name"],
                    "match_type": "exact",
                    "식약처_공식정보": selected_official,
                }
            )

        with genai.Client(api_key=GEMINI_API_KEY) as client:
            # Step 0 & 1: 오타 교정 및 약품명 추출 (추론 강화)
            if selected_medicines_question:
                # The client already supplied exact code/name pairs. Re-extracting names
                # from the natural-language prompt can mutate verified product names.
                drug_names = []
            else:
                extract_prompt = (
                    "당신은 제약 전문가입니다. 사용자의 질문에서 약품명이나 성분명을 추출해야 합니다.\n"
                    "사용자가 약품명을 잘못 입력했거나(오타), 속어/줄임말을 사용했을 수 있습니다. "
                    "의약품 정보는 아주 작은 오타로도 검색이 안 되거나 잘못된 결과가 나올 수 있으므로, "
                    "반드시 머릿속으로 다음 3번의 검증(추론)을 거쳐 가장 정확한 명칭을 도출하세요:\n\n"
                    "1. 원본 확인: 사용자가 입력한 단어 그대로 인식\n"
                    "2. 오타 및 유사도 검증: 해당 단어가 흔한 오타인지, 혹은 시판되는 비슷한 이름의 정식 약품이 있는지 분석 (예: 타이래놀 -> 타이레놀, 후시딘 -> 부채표후시딘연고)\n"
                    "3. 최종 확정: 식약처 DB에 검색될 확률이 가장 높은 '정확한 정식 제품명' 또는 '표준 성분명'으로 교정\n\n"
                    "3단계 검증을 모두 마친 최종 확정된 약품명들만 'drug_names' 배열에 담아 JSON으로 반환하세요. 없으면 빈 배열을 반환하세요.\n\n"
                    f"질문: {message}"
                )
                extract_response = _generate_content_with_retry(
                    client,
                    model=GEMINI_MODEL,
                    contents=extract_prompt,
                    config={
                        "temperature": 0.2,
                        "max_output_tokens": 512,
                        "response_mime_type": "application/json",
                        "response_json_schema": CHAT_EXTRACTION_SCHEMA,
                        "thinking_config": {"thinking_budget": 0},
                    },
                )
                drug_names = _extract_drug_names(extract_response)
            logger.warning(
                "Gemini extraction_result drug_name_count=%d",
                len(drug_names),
            )

            # 2. 식약처 공식 데이터 수집
            for drug_index, name in enumerate(drug_names):
                found_data = None
                # 2-1. 먼저 식약처 API 시도
                logger.warning(
                    "Gemini official_search_start drug_index=%d",
                    drug_index,
                )
                try:
                    search_result = search_drug_info_by_name(name)
                    search_items = (
                        search_result.get("items", [])
                        if isinstance(search_result, dict)
                        else []
                    )
                    logger.warning(
                        "Gemini official_search_result drug_index=%d "
                        "items_found=%d match_type_present=%s",
                        drug_index,
                        len(search_items) if isinstance(search_items, list) else 0,
                        bool(
                            isinstance(search_result, dict)
                            and search_result.get("match_type")
                        ),
                    )
                    if search_result and search_result.get("items"):
                        found_data = {
                            "검색된_약품명": name,
                            "match_type": search_result.get("match_type"),
                            "식약처_공식정보": search_result["items"][0],
                        }
                    else:
                        official_search_empty_count += 1
                except Exception as e:
                    official_search_failure_count += 1
                    logger.warning(
                        "Gemini official_search_failed drug_index=%d error_type=%s "
                        "status_code=%s detail_type=%s",
                        drug_index,
                        type(e).__name__,
                        getattr(e, "status_code", None),
                        type(getattr(e, "detail", None)).__name__,
                    )

                if found_data and not any(
                    item["식약처_공식정보"].get("medicine_code")
                    == found_data["식약처_공식정보"].get("medicine_code")
                    for item in official_data_list
                ):
                    official_data_list.append(found_data)
                if found_data and found_data.get("match_type") == "exact":
                    exact_info = found_data.get("식약처_공식정보") or {}
                    exact_code = str(exact_info.get("medicine_code") or "").strip()
                    exact_name = str(exact_info.get("product_name") or "").strip()
                    if (
                        exact_code.isdigit()
                        and exact_name
                        and not any(
                            item["medicine_code"] == exact_code
                            for item in question_official_medicines
                        )
                    ):
                        question_official_medicines.append(
                            {
                                "medicine_code": exact_code,
                                "product_name": exact_name,
                            }
                        )

            if (
                selected_medicine is None
                and not all_medicines_question
                and len(question_official_medicines) == 1
            ):
                exact_code = question_official_medicines[0]["medicine_code"]
                selected_official = next(
                    (
                        item["식약처_공식정보"]
                        for item in official_data_list
                        if str(
                            item.get("식약처_공식정보", {}).get("medicine_code")
                            or ""
                        ).strip()
                        == exact_code
                    ),
                    None,
                )

            official_contexts = [
                select_official_context(item["식약처_공식정보"], intents)
                for item in official_data_list
                if item.get("match_type") in {"exact", "partial"}
                and item.get("식약처_공식정보")
            ]
            official_contexts = [item for item in official_contexts if item]
            if "combination" in intents or (
                (all_medicines_question or selected_medicines_question)
                and "duplicate" in intents
            ):
                from app.services.medication_feature_dur_client import (
                    load_remote_combination_context,
                )

                explicit_question_scope = selected_medicines_question or (
                    selected_medicine is None
                    and not all_medicines_question
                    and len(question_official_medicines) >= 2
                )
                dur_request = {
                    "user_id": user_id,
                    "selected_medicine": (
                        None if explicit_question_scope else selected_official
                    ),
                    "additional_medicines": (
                        temporary_medicines or []
                        if all_medicines_question
                        else (
                            selected_medicines or []
                            if selected_medicines_question
                            else question_official_medicines
                        )
                    ),
                    "requested_types": (
                        {"중복성분"}
                        if (
                            all_medicines_question or selected_medicines_question
                        )
                        and "duplicate" in intents
                        else {"병용금기", "중복성분", "효능군중복"}
                    ),
                }
                if explicit_question_scope:
                    dur_request["include_current_medicines"] = False
                dur_result = load_remote_combination_context(
                    **dur_request,
                )
                if (
                    all_medicines_question or selected_medicines_question
                ) and "duplicate" in intents:
                    duplicate_items = [
                        item
                        for item in dur_result.get("items", [])
                        if item.get("type") in {"중복성분", "효능군중복"}
                    ]
                    dur_result = {
                        **dur_result,
                        "items": duplicate_items,
                        "has_risk": (
                            bool(duplicate_items)
                            if dur_result.get("status") == "current"
                            else None
                        ),
                    }
            elif safety_question and selected_official is not None:
                wanted_types = set().union(
                    *(DUR_TYPES_BY_INTENT.get(intent, set()) for intent in intents)
                )
                dur_result = analyze_dur_consultation(
                    user_id=user_id,
                    selected_medicine=selected_official,
                    risk_types=wanted_types,
                )
                dur_result["items"] = enrich_dur_matches(dur_result["items"])
            else:
                dur_result = load_latest_dur_context(user_id, intents)

            if safety_question and (
                dur_result.get("status") in {"stale", "missing"}
                or (
                    (
                        "combination" in intents
                        or (
                            (all_medicines_question or selected_medicines_question)
                            and "duplicate" in intents
                        )
                    )
                    and (
                        dur_result.get("status") != "current"
                        or dur_result.get("has_risk", False) is None
                    )
                )
            ):
                return _dur_context_unavailable_reply(
                    intents,
                    dur_result.get("status") or "missing",
                    dur_result.get("reason"),
                    all_medicines=all_medicines_question,
                )
            if (
                safety_question
                and dur_result["status"] == "current"
                and not dur_result["items"]
            ):
                return _dur_no_match_reply(
                    intents,
                    dur_result,
                    selected_medicine=selected_medicine,
                )
            if not official_contexts and not dur_result["items"]:
                if all_medicines_question or selected_medicines_question:
                    notice = _all_medicine_unverified_notice(
                        unverified_names=unverified_all_medicine_names,
                        identity_incomplete=(
                            (all_medicines_context or {}).get("status") == "incomplete"
                        ),
                    )
                    return (
                        f"{notice}\n" if notice else ""
                    ) + (
                        "확인하지 못한 내용은 추측해서 만들지 않을게요. "
                        "잠시 후 다시 확인해 주세요."
                    )
                if drug_names and official_search_failure_count > 0:
                    return (
                        "약 공식정보를 조회하는 중 문제가 생겼어요. "
                        "잠시 후 제품명을 그대로 입력해 다시 확인해 주세요."
                    )
                if (
                    drug_names
                    and official_search_empty_count > 0
                    and official_search_failure_count + official_search_empty_count
                    == len(drug_names)
                ):
                    return (
                        "입력한 제품명을 식약처 공식정보에서 확인하지 못했어요. "
                        "약 포장에 적힌 제품명을 확인해 주세요."
                    )
                return unavailable_reply

            confirmed_zero_messages = _confirmed_zero_messages(
                intents,
                dur_result,
                selected_medicine=selected_medicine,
            )
            prompt_dur_result = {
                **dur_result,
                "confirmed_zero_messages": confirmed_zero_messages,
            }
            prompt = build_grounded_chat_prompt(
                message=message,
                intents=intents,
                official_contexts=official_contexts,
                dur_result=prompt_dur_result,
            )
            if all_medicines_question or selected_medicines_question:
                verified_count = len(official_contexts)
                total_count = len((all_medicines_context or {}).get("items") or [])
                scope_label = (
                    "약 데이터 서버의 현재 복용약"
                    if all_medicines_question
                    else "사용자가 선택한 약"
                )
                answer_scope_rule = (
                    '약 전체 질문을 "선택한 약"이나 단일 제품만 확인한 것처럼 표현하지 마세요.'
                    if all_medicines_question
                    else "복수 선택 질문을 현재 복용약 전체를 확인한 것처럼 표현하지 마세요."
                )
                answer_detail_rule = (
                    "약 전체 답변은 공식정보를 확인한 약마다 핵심 1~2문장만 쓰고, "
                    if all_medicines_question
                    else "복수 선택 답변은 공식정보를 확인한 약마다 핵심 1~2문장만 쓰고, "
                )
                prompt += (
                    "\n\n[답변 작성 규칙 - 이 제목과 규칙은 사용자에게 출력하지 마세요]\n"
                    f"{scope_label} {total_count}개 중 "
                    f"공식정보가 정확히 확인된 약은 {verified_count}개입니다.\n"
                    "공식정보를 확인하지 못한 약의 이름이나 상세정보는 답변에 쓰지 마세요.\n"
                    "공식정보를 확인한 약은 각 제품명을 한 번 이상 직접 쓰고, 한 제품의 정보를 "
                    "다른 제품에 적용하거나 제품을 조용히 누락하지 마세요.\n"
                    f"{answer_detail_rule}"
                    "공통 안내는 한 번만 쓰세요. 약이 많아도 분량을 맞추려고 특정 약을 누락하지 마세요. "
                    "단, 중요한 숫자·금지·연령·예외 조건과 확인하지 못한 약·검사 범위는 "
                    "줄이거나 의미를 약하게 만들지 마세요.\n"
                    f"{answer_scope_rule}"
                )
                if verified_all_medicine_names:
                    prompt += (
                        "\n공식정보를 확인한 제품명: "
                        + ", ".join(verified_all_medicine_names)
                    )
                if unverified_all_medicine_names:
                    prompt += (
                        f"\n공식정보를 확인하지 못한 "
                        f"{'등록 약' if all_medicines_question else '선택 약'}이 있으므로, "
                        "그 약의 상세정보를 추측하지 마세요."
                    )
                if (all_medicines_context or {}).get("status") == "incomplete":
                    prompt += (
                        "\n제품명이나 코드를 확인하지 못한 등록 약도 있으므로, "
                        "현재 복용약 전체를 확인했다고 말하지 마세요."
                    )

            required_names = (
                tuple(verified_all_medicine_names)
                if (all_medicines_question or selected_medicines_question)
                and bool(intents & {"overview", "precautions"})
                else ()
            )
            forbidden_phrases: tuple[str, ...] = ()
            if all_medicines_question or selected_medicines_question:
                forbidden_phrases = (
                    "답변 작성 규칙",
                    "현재 복용약 확인 범위",
                    "현재 복용약 전체 확인 범위",
                    *tuple(
                        name
                        for name in unverified_all_medicine_names
                        if name and name != "이름을 확인하지 못한 약"
                    ),
                )
                if all_medicines_question and bool(
                    intents & {"combination", "duplicate"}
                ):
                    forbidden_phrases += ("선택한 약",)
            reply = _generate_complete_chat_reply(
                client,
                prompt=prompt,
                max_output_tokens=(
                    1024
                    if bool(intents & {"dosage", "usage", "precautions"})
                    else 512
                ),
                required_medicine_names=required_names,
                forbidden_phrases=forbidden_phrases,
            )
            reply = _prepend_confirmed_zero_messages(
                reply,
                confirmed_zero_messages,
            )
            if (
                all_medicines_question
                and bool(intents & {"overview", "precautions"})
                and reply != INCOMPLETE_CHAT_REPLY
            ):
                notice = _all_medicine_unverified_notice(
                    unverified_names=unverified_all_medicine_names,
                    identity_incomplete=(
                        (all_medicines_context or {}).get("status") == "incomplete"
                    ),
                )
                return f"{notice}\n{reply}" if notice else reply
            return reply
    except HTTPException:
        raise
    except Exception as error:
        logger.warning("Gemini chat failed: %s", error, exc_info=True)
        return (
            "지금은 답변을 불러오지 못했어요. "
            "잠시 후 다시 시도해 주세요. "
            "약의 사용 방법을 임의로 바꾸지는 마세요."
        )
