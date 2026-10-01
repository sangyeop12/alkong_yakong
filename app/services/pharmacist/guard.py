"""Reject answers that have no clear overlap with the retrieved source."""

from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
import re


@dataclass(frozen=True)
class GuardResult:
    allowed: bool
    reply: str
    rejected: tuple[str, ...]
    evidence_score: float


def guard_reply(reply: str, source_text: str) -> GuardResult:
    text = (reply or "").strip()
    source = _compact(source_text)
    if not text or not source:
        return GuardResult(False, "", (text,) if text else (), 0.0)

    kept: list[str] = []
    rejected: list[str] = []
    sentences = _sentences(text)
    for sentence in sentences:
        if _has_source_overlap(sentence, source):
            kept.append(sentence)
        else:
            rejected.append(sentence)
    evidence_score = round((len(kept) / len(sentences)) * 100, 1) if sentences else 0.0
    if not kept:
        return GuardResult(False, "", tuple(rejected), evidence_score)
    return GuardResult(True, " ".join(kept), tuple(rejected), evidence_score)


def _sentences(text: str) -> list[str]:
    return [piece.strip() for piece in text.replace("!", ".").split(".") if piece.strip()]


def _compact(value: str) -> str:
    return "".join(str(value or "").casefold().split())


def _has_source_overlap(sentence: str, source: str) -> bool:
    compact = _compact(sentence)
    if len(compact) < 6:
        return False
    if not _numbers_are_supported(compact, source):
        return False
    if compact in source:
        return True
    match = SequenceMatcher(None, compact, source).find_longest_match(
        0, len(compact), 0, len(source)
    )
    minimum_length = max(10, int(len(compact) * 0.35))
    return match.size >= minimum_length


def _numbers_are_supported(sentence: str, source: str) -> bool:
    return set(re.findall(r"\d+(?:\.\d+)?", sentence)) <= set(
        re.findall(r"\d+(?:\.\d+)?", source)
    )
