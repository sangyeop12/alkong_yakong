from unittest.mock import patch

from app.services.pharmacist.chat_pipeline import run_chat_pipeline


def test_together_reuses_latest_dur_when_current():
    latest = {
        "message": "함께 먹을 때 주의가 있어요.",
        "matches": [{"reason": "함께 먹으면 안 되는 약이 있어요."}],
        "medicine_names": ["코다론정", "아디팜정"],
        "incomplete": False,
    }
    with (
        patch(
            "app.services.chat_context_service.load_latest_dur_context",
            return_value={"status": "current", "items": []},
        ),
        patch("app.services.dur_service.get_latest_dur", return_value=latest),
        patch("app.services.dur_service.analyze_dur") as analyze,
    ):
        result = run_chat_pipeline("같이 먹으면", user_id="mvp-user")
    analyze.assert_not_called()
    assert result.ok is True
    assert result.trace.get("dur_reused") is True
    assert "함께 먹을 때 주의" in result.reply


def test_together_reanalyzes_when_dur_is_stale():
    analyzed = {
        "message": "다시 살펴본 결과예요.",
        "matches": [],
        "medicine_names": ["코다론정"],
        "incomplete": False,
    }
    with (
        patch(
            "app.services.chat_context_service.load_latest_dur_context",
            return_value={"status": "stale", "items": []},
        ),
        patch("app.services.dur_service.get_latest_dur") as latest,
        patch("app.services.dur_service.analyze_dur", return_value=analyzed) as analyze,
    ):
        result = run_chat_pipeline("같이 먹으면", user_id="mvp-user")
    latest.assert_not_called()
    analyze.assert_called_once()
    assert result.trace.get("dur_reused") is False
    assert "특별한 함께먹기 주의는 없어요" in result.reply
