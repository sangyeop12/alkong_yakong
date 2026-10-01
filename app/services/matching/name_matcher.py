"""Match OCR medicine names against the verified local lexicon."""

from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
import re


AUTO_ACCEPT = 0.90
SIMILAR_ACCEPT = 0.74
CANDIDATE_MIN = 0.68


@dataclass(frozen=True)
class MatchResult:
    query: str
    matched_name: str | None
    score: float
    method: str
    candidates: tuple[tuple[str, float], ...]


def _normalize(value: str) -> str:
    return "".join(str(value or "").lower().split())


def _before_paren(value: str) -> str:
    """괄호 안 성분·잘린 괄호 뒤를 빼고 제품명만 남긴다."""
    return re.split(r"[（(]", str(value or ""), maxsplit=1)[0]


_OCR_FOLD = str.maketrans(
    {
        "징": "짓",
        "짙": "짓",
        "짇": "짓",
        "란": "라",
    }
)


def _fold_ocr_chars(value: str) -> str:
    """짓/짙/짇/징, 라/란, 베넥/벨처럼 OCR에서 자주 바뀌는 글자를 같은 키로 본다."""
    text = str(value or "").replace("베넥", "벨").replace("베이", "벨")
    return text.translate(_OCR_FOLD)


def _alnum_hangul(value: str) -> str:
    return "".join(
        ch for ch in str(value or "") if ch.isalnum() or "가" <= ch <= "힣"
    ).casefold()


def compare_key(value: str) -> str:
    """매칭·오버레이가 같이 쓰는 비교 키."""
    return _fold_ocr_chars(_medicine_key(_before_paren(value)))


_EXTRA_BRAND_REST = (
    "콜드",
    "씨콜드",
    "에스",
    "플러스",
    "복합",
    "나이트",
    "데이",
    "심이",
    "세미",
)


def _edit_distance_le1(left: str, right: str) -> bool:
    """한 글자 치환·삽입·삭제만 허용."""
    a, b = left, right
    if a == b:
        return True
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) == len(b):
        return sum(x != y for x, y in zip(a, b)) == 1
    if len(a) > len(b):
        a, b = b, a
    skipped = False
    i = 0
    for ch in b:
        if i < len(a) and a[i] == ch:
            i += 1
        elif skipped:
            return False
        else:
            skipped = True
    return True


def _rest_is_same_product(rest: str) -> bool:
    """접두 매칭 뒤 남은 글자가 같은 약의 용량·제형인지."""
    text = str(rest or "")
    if not text:
        return True
    if any(text.startswith(marker) for marker in _EXTRA_BRAND_REST):
        return False
    if text.isdigit() or re.fullmatch(r"\d+(?:\.\d+)?", text):
        return True
    if text in {"서방", "이알", "필름"}:
        return True
    for form in (
        "필름코팅정",
        "이알서방정",
        "서방정",
        "연질캡슐",
        "캡슐",
        "시럽",
        "액",
        "정",
    ):
        if text.startswith(form):
            return _rest_is_same_product(text[len(form) :])
    hangul = re.sub(r"[^가-힣]", "", text)
    if hangul and len(hangul) <= 2:
        return True
    return False


def _safe_prefix(short: str, long: str) -> bool:
    """잘린 OCR명만 접두로 인정. 타이레놀 ⊂ 타이레놀콜드는 다른 약으로 본다."""
    if len(short) < 4 or len(long) < len(short):
        return False
    if not long.startswith(short):
        return False
    return _rest_is_same_product(long[len(short) :])


def names_correspond(left: str, right: str, *, allow_typo: bool = True) -> bool:
    """필터·오버레이·매칭이 같이 쓰는 이름 대응.

    1) 정규화 키가 같음
    2) 한 글자 OCR 오타
    3) 잘린 접두(같은 제품 용량만 뒤에 남은 경우)
    """
    a = compare_key(left)
    b = compare_key(right)
    if len(a) < 2 or len(b) < 2:
        a = _fold_ocr_chars(_alnum_hangul(_before_paren(left)))
        b = _fold_ocr_chars(_alnum_hangul(_before_paren(right)))
    if len(a) < 2 or len(b) < 2:
        return False
    if a == b:
        return True
    if allow_typo and min(len(a), len(b)) >= 3 and _edit_distance_le1(a, b):
        return True
    return _safe_prefix(a, b) or _safe_prefix(b, a)


def line_matches_drug_name(line: str, drug_name: str) -> bool:
    """박스 글자·OCR명·공식명이 같은 약인지."""
    return names_correspond(line, drug_name, allow_typo=True)


def _medicine_key(value: str) -> str:
    normalized = _normalize(_before_paren(value))
    normalized = re.sub(r"\([^)]*\)", "", normalized)
    normalized = re.sub(r"\[[^\]]*\]", "", normalized)
    normalized = re.sub(r"[·]", "", normalized)
    normalized = re.sub(
        r"\d+(?:\.\d+)?(?:mg|ml|g|%|밀리그램|밀리그람)",
        "",
        normalized,
    )
    for dosage_form in (
        "필름코팅정",
        "이알서방정",
        "서방정",
        "연질캡슐",
        "플라스타",
        "패취",
        "패치",
        "캡슐",
        "시럽",
        "연고",
        "크림",
        "액",
        "정",
    ):
        if normalized.endswith(dosage_form):
            normalized = normalized[: -len(dosage_form)]
            break
    return normalized


def extract_strengths(value: str) -> set[float]:
    """이름 안 용량 숫자(mg/% 등) 추출."""
    text = str(value or "").casefold()
    nums: set[float] = set()
    for match in re.finditer(
        r"(\d+(?:\.\d+)?)\s*(?:mg|ml|g|%|밀리그램|밀리그람)",
        text,
    ):
        try:
            nums.add(float(match.group(1)))
        except ValueError:
            continue
    # 피엠에스플루옥세틴캡슐10 / 토핀정25 형태
    for match in re.finditer(r"(?:정|캡슐|액)\s*(\d+(?:\.\d+)?)", text):
        try:
            nums.add(float(match.group(1)))
        except ValueError:
            continue
    return nums


def _dosage_form(value: str) -> str | None:
    text = _normalize(value)
    for form in (
        "필름코팅정",
        "이알서방정",
        "서방정",
        "연질캡슐",
        "플라스타",
        "패취",
        "패치",
        "캡슐",
        "시럽",
        "연고",
        "크림",
        "액",
        "정",
    ):
        if form in text:
            return "패취" if form == "패치" else form
    return None


def forms_compatible(query: str, official: str) -> bool:
    """시럽↔정 처럼 제형이 뚜렷이 다르면 거부."""
    q_form = _dosage_form(query)
    o_form = _dosage_form(official)
    if not q_form or not o_form:
        return True
    if q_form == o_form:
        return True
    tablet = {"정", "필름코팅정", "서방정", "이알서방정"}
    if q_form in tablet and o_form in tablet:
        return True
    return False


def strengths_compatible(
    query: str,
    official: str,
    *,
    dosage_hint: str | float | None = None,
) -> bool:
    """OCR/힌트 용량과 공식명 용량이 충돌하면 False (250≠500)."""
    official_nums = extract_strengths(official)
    query_nums = extract_strengths(query)
    if dosage_hint is not None and str(dosage_hint).strip():
        hint_text = str(dosage_hint)
        # "250" / "250mg" / "500, 10"
        for part in re.split(r"[,/]", hint_text):
            found = extract_strengths(part if re.search(r"[a-z%밀리]", part.casefold()) else f"{part}mg")
            if not found:
                try:
                    query_nums.add(float(re.search(r"\d+(?:\.\d+)?", part).group(0)))  # type: ignore[union-attr]
                except (AttributeError, ValueError, TypeError):
                    pass
            else:
                query_nums |= found
    if not query_nums or not official_nums:
        return True
    # 교집합이 있으면 호환. OCR 250 vs 공식 500만 있으면 거부.
    return bool(query_nums & official_nums)


def _display_core(value: str) -> str:
    """비교용: 괄호 성분·용량 단위를 뺀 제품 핵심명."""
    text = re.sub(r"\([^)]*\)", "", str(value or ""))
    text = re.sub(r"\[[^\]]*\]", "", text)
    return _normalize(text)


def _rank_candidates(
    query: str,
    lexicon: list[str],
    *,
    dosage_hint: str | float | None = None,
    similar: bool = False,
) -> list[tuple[str, float]]:
    medicine_key = _medicine_key(query)
    q_core = _display_core(query)
    ranked: list[tuple[str, float]] = []
    for name in lexicon:
        if not strengths_compatible(query, name, dosage_hint=dosage_hint):
            continue
        if not forms_compatible(query, name):
            continue
        n_core = _display_core(name)
        n_key = _medicine_key(name)
        full = SequenceMatcher(None, q_core, n_core).ratio()
        key = (
            SequenceMatcher(None, medicine_key, n_key).ratio()
            if medicine_key and n_key
            else 0.0
        )
        fold_q = _fold_ocr_chars(medicine_key) if similar else medicine_key
        fold_n = _fold_ocr_chars(n_key) if similar else n_key
        fold = (
            SequenceMatcher(None, fold_q, fold_n).ratio()
            if fold_q and fold_n
            else 0.0
        )
        prefix_bonus = 0.0
        if _safe_prefix(fold_q, fold_n) or _safe_prefix(fold_n, fold_q):
            prefix_bonus = 0.12
        score = min(1.0, max(full, key, fold) + prefix_bonus)
        if similar and fold_q and fold_n and fold_q == fold_n:
            score = max(score, 0.96)
        elif (
            similar
            and min(len(fold_q), len(fold_n)) >= 4
            and _edit_distance_le1(fold_q, fold_n)
        ):
            score = max(score, 0.88)
        ranked.append((name, score))
    ranked.sort(key=lambda item: item[1], reverse=True)
    return ranked


def match_medicine_name(
    query: str,
    lexicon: list[str],
    *,
    dosage_hint: str | float | None = None,
    similar: bool = False,
) -> MatchResult:
    """similar=True 이면 미매칭용 유사 추론(SIMILAR_ACCEPT)까지 허용."""
    raw = (query or "").strip()
    if not raw or not lexicon:
        return MatchResult(raw, None, 0.0, "none", ())

    usable = [
        name
        for name in lexicon
        if strengths_compatible(raw, name, dosage_hint=dosage_hint)
        and forms_compatible(raw, name)
    ]
    if not usable:
        return MatchResult(raw, None, 0.0, "none", ())

    for name in usable:
        if name == raw:
            return MatchResult(raw, name, 1.0, "exact", ((name, 1.0),))

    normalized = _normalize(raw)
    for name in usable:
        if _normalize(name) == normalized:
            return MatchResult(raw, name, 0.99, "normalized", ((name, 0.99),))

    medicine_key = _medicine_key(raw)

    def _unique_hit(hits: list[str], method: str, score: float) -> MatchResult | None:
        if len(hits) != 1:
            return None
        return MatchResult(raw, hits[0], score, method, ((hits[0], score),))

    key_hits = [
        name
        for name in usable
        if medicine_key and _medicine_key(name) == medicine_key
    ]
    hit = _unique_hit(key_hits, "medicine_key", 0.98)
    if hit:
        return hit
    if len(key_hits) > 1:
        # 용량으로 하나로 좁혀질 때만 키 매칭
        narrowed = [
            name
            for name in key_hits
            if strengths_compatible(raw, name, dosage_hint=dosage_hint)
            and (extract_strengths(raw) or dosage_hint)
        ]
        hit = _unique_hit(narrowed, "medicine_key_strength", 0.98)
        if hit:
            return hit
        # 용량 힌트 없이 여러 규격이면 키만으로 확정하지 않음

    prefix_key_hits = [
        name
        for name in usable
        if medicine_key
        and (
            _safe_prefix(medicine_key, _medicine_key(name))
            or _safe_prefix(_medicine_key(name), medicine_key)
        )
    ]
    hit = _unique_hit(prefix_key_hits, "truncated_prefix", 0.95)
    if hit:
        return hit

    # 비슷한 이름(한 글자 오타·OCR 접기)으로는 공식 약을 확정하지 않는다.
    if not similar:
        ranked = _rank_candidates(
            raw, usable, dosage_hint=dosage_hint, similar=False
        )
        candidates = tuple(
            (name, score) for name, score in ranked if score >= CANDIDATE_MIN
        )[:5]
        return MatchResult(
            raw,
            None,
            candidates[0][1] if candidates else 0.0,
            "none",
            candidates,
        )

    folded = _fold_ocr_chars(medicine_key)
    fold_hits = [
        name
        for name in usable
        if folded and _fold_ocr_chars(_medicine_key(name)) == folded
    ]
    hit = _unique_hit(fold_hits, "ocr_fold", 0.97)
    if hit:
        return hit

    prefix_hits = [
        name
        for name in usable
        if _safe_prefix(folded, _fold_ocr_chars(_medicine_key(name)))
        or _safe_prefix(_fold_ocr_chars(_medicine_key(name)), folded)
    ]
    hit = _unique_hit(prefix_hits, "truncated_prefix", 0.95)
    if hit:
        return hit

    edit_hits = [
        name
        for name in usable
        if min(len(folded), len(_fold_ocr_chars(_medicine_key(name)))) >= 4
        and _edit_distance_le1(folded, _fold_ocr_chars(_medicine_key(name)))
    ]
    hit = _unique_hit(edit_hits, "edit1", 0.93)
    if hit:
        return hit

    ranked = _rank_candidates(raw, usable, dosage_hint=dosage_hint, similar=True)
    candidates = tuple(
        (name, score) for name, score in ranked if score >= CANDIDATE_MIN
    )[:5]
    if candidates and candidates[0][1] >= SIMILAR_ACCEPT:
        if len(candidates) > 1 and (candidates[0][1] - candidates[1][1]) < 0.06:
            return MatchResult(raw, None, candidates[0][1], "none", candidates)
        name, score = candidates[0]
        return MatchResult(raw, name, score, "similar", candidates)
    return MatchResult(
        raw,
        None,
        candidates[0][1] if candidates else 0.0,
        "none",
        candidates,
    )
