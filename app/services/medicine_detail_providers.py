"""Pluggable sources for verified, complete ingredient explanations.

Only source-verified and reviewed ingredient copy may reach the detail screen.
An official provider can implement the same interface later without changing
the detail API or Flutter response shape.
"""

from __future__ import annotations

import re
from typing import Any, Protocol


_SPACE = re.compile(r"\s+")
_INCOMPLETE_ENDING = re.compile(r"(?:따라|따르면|및|또는|그리고|,|:|：|\(|·)\s*$")
_COMPLETE_ENDING = re.compile(
    r"(?:이에요|예요|해요|돼요|줘요|있어요|없어요|됩니다|합니다|입니다|"
    r"있습니다|없습니다|돕습니다|조절합니다|사용됩니다|성분이다|성분입니다)"
    r"[.!?]?\s*$"
)
_HIDDEN_COPY = ("준비 중", "준비중", "확인 중", "확인중")
_MAX_SENTENCE_CHARS = 180


def clean_ingredient_explanation(value: Any) -> str:
    """Normalize display copy without clipping a sentence."""
    return _SPACE.sub(" ", str(value or "")).strip()


def is_displayable_ingredient_explanation(value: Any) -> bool:
    """Reject drafts, dangling official-purpose fragments, and cut sentences."""
    text = clean_ingredient_explanation(value)
    if not text or any(marker in text for marker in _HIDDEN_COPY):
        return False
    if _INCOMPLETE_ENDING.search(text):
        return False
    if not _COMPLETE_ENDING.search(text):
        return False
    sentences = [item for item in re.split(r"(?<=[.!?])\s+", text) if item.strip()]
    return len(sentences) <= 2 and all(
        len(sentence) <= _MAX_SENTENCE_CHARS for sentence in sentences
    )


class IngredientExplanationProvider(Protocol):
    name: str

    def find_reviewed(
        self,
        cursor,
        ingredients: list[dict[str, str]],
    ) -> dict[str, dict[str, Any]]:
        """Return reviewed explanations keyed by normalized ingredient key."""


class LocalReviewedIngredientProvider:
    name = "local-reviewed"

    def find_reviewed(
        self,
        cursor,
        ingredients: list[dict[str, str]],
    ) -> dict[str, dict[str, Any]]:
        result: dict[str, dict[str, Any]] = {}
        for ingredient in ingredients:
            row = cursor.execute(
                """
                SELECT ingredient_name, explanation, role_explanation, use_help,
                       role_group, group_explanation,
                       source, source_verified, content_version
                FROM ingredient_explanations
                WHERE normalized_key=? AND review_status='REVIEWED'
                  AND source_verified=1
                """,
                (ingredient["key"],),
            ).fetchone()
            # A reuse key (which may omit strength) is not identity evidence.
            # Require the reviewed official ingredient name as well; no aliases.
            if (row and str(row["ingredient_name"]).strip().casefold()
                    == ingredient["name"].strip().casefold()
                    and is_displayable_ingredient_explanation(row["explanation"])):
                result[ingredient["key"]] = dict(row)
        return result


INGREDIENT_EXPLANATION_PROVIDERS: tuple[IngredientExplanationProvider, ...] = (
    LocalReviewedIngredientProvider(),
)


def find_reviewed_ingredient_explanations(
    cursor,
    ingredients: list[dict[str, str]],
) -> dict[str, dict[str, Any]]:
    combined: dict[str, dict[str, Any]] = {}
    for provider in INGREDIENT_EXPLANATION_PROVIDERS:
        for key, value in provider.find_reviewed(cursor, ingredients).items():
            combined.setdefault(key, {**value, "provider": provider.name})
    return combined
