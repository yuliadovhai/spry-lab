"""The parser's contract, with the model replaced by a fake Bedrock client."""

import json
from datetime import date
from types import SimpleNamespace

import pytest

from app.ai import agenda as agenda_module
from app.ai import agenda_lambda

GOOD = {
    "title": "Синк по прайсингу",
    "starts_at": "2026-11-02T10:00:00+02:00",
    "duration_minutes": 45,
    "items": [{"topic": "Нові тарифи Pro", "owner": "Олена", "minutes": 15}],
    "action_items": [{"task": "Порівняння з конкурентами", "owner": "Taras", "due": "2026-11-06"}],
    "language": "uk",
}


class FakeConverse:
    """Answers with the given tool inputs, one per call."""

    def __init__(self, *inputs):
        self.inputs = list(inputs)
        self.calls = []

    def converse(self, **kwargs):
        self.calls.append(kwargs)
        tool_input = self.inputs.pop(0)
        return {
            "output": {
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "toolUse": {
                                "toolUseId": "t1",
                                "name": "record_agenda",
                                "input": tool_input,
                            }
                        }
                    ],
                }
            },
            "stopReason": "tool_use",
            "usage": {"inputTokens": 1000, "outputTokens": 200},
        }


@pytest.fixture
def fake(monkeypatch):
    def install(*inputs):
        client = FakeConverse(*inputs)
        monkeypatch.setattr(agenda_module, "_runtime_client", client)
        monkeypatch.setenv("PARSER_MODEL", "us.amazon.nova-micro-v1:0")
        return client

    return install


def test_parses_a_valid_agenda(fake):
    client = fake(GOOD)
    parsed, usage = agenda_module.parse_agenda("text", date(2026, 10, 29), "Europe/Kyiv")
    assert parsed.items[0].owner == "Олена"
    assert usage.input_tokens == 1000
    # Today's date and the time zone reach the model, and the text is delimited.
    sent = client.calls[0]["messages"][0]["content"][0]["text"]
    assert "Thursday 2026-10-29" in sent and "<pasted_text>" in sent


def test_retries_once_with_the_validation_error(fake):
    client = fake({"items": [{"topic": ""}], "language": "uk"}, GOOD)
    parsed, usage = agenda_module.parse_agenda("text", date(2026, 10, 29), "Europe/Kyiv")
    assert parsed.title == "Синк по прайсингу"
    assert usage.input_tokens == 2000
    retry = client.calls[1]["messages"][-1]["content"][0]["toolResult"]
    assert retry["status"] == "error"


def test_gives_up_after_two_invalid_answers(fake):
    bad = {"items": [{"topic": ""}], "language": "uk"}
    fake(bad, bad)
    with pytest.raises(agenda_module.AgendaParseError):
        agenda_module.parse_agenda("text", date(2026, 10, 29), "Europe/Kyiv")


def test_no_items_is_not_an_agenda(fake):
    fake({"items": [], "language": "en"})
    with pytest.raises(agenda_module.AgendaParseError, match="no agenda"):
        agenda_module.parse_agenda("milk, eggs", date(2026, 10, 29), "Europe/Kyiv")


def _event(body):
    return {"body": json.dumps(body), "isBase64Encoded": False}


def test_handler_returns_the_agenda_and_logs_cost(fake, capsys):
    fake(GOOD)
    response = agenda_lambda.handler(
        _event({"text": "agenda", "today": "2026-10-29", "tz": "Europe/Kyiv"}),
        SimpleNamespace(aws_request_id="r1"),
    )
    assert response["statusCode"] == 200
    assert json.loads(response["body"])["prompt_version"] == "agenda-v1"
    line = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert line["event"] == "agenda_parsed"
    assert line["cost_usd"] == pytest.approx(1000 * 0.035e-6 + 200 * 0.14e-6)


def test_handler_rejects_long_text_before_calling_the_model(fake):
    client = fake(GOOD)
    body = {"text": "x" * 10_001, "today": "2026-10-29", "tz": "UTC"}
    assert agenda_lambda.handler(_event(body), None)["statusCode"] == 413
    assert client.calls == []


def test_handler_rejects_a_bad_body():
    assert agenda_lambda.handler({"body": "not json"}, None)["statusCode"] == 400


def test_handler_maps_no_agenda_to_422(fake):
    fake({"items": [], "language": "en"})
    body = {"text": "milk", "today": "2026-10-29", "tz": "UTC"}
    assert agenda_lambda.handler(_event(body), None)["statusCode"] == 422
