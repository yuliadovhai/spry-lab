"""The agenda parser behind its own Lambda function URL.

Runs outside the VPC: it needs Bedrock, not the database, so it reaches
Bedrock over the internet with no NAT and no VPC endpoint, and costs nothing
while nobody uses it. It never writes anything - saving is the API's job.

CORS (origins, POST only) is configured on the function URL, not here.
"""

from __future__ import annotations

import base64
import json
import time
from datetime import date
from typing import Any

from app.ai.agenda import (
    PROMPT_VERSION,
    AgendaParseError,
    AgendaThrottled,
    cost_usd,
    parse_agenda,
    parser_model,
)

MAX_TEXT = 10_000


def _response(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def _log(**fields: Any) -> None:
    # One JSON line per request; print() lands in CloudWatch Logs as-is.
    print(json.dumps(fields, ensure_ascii=False))


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        body = json.loads(raw)
        text = body["text"]
        today = date.fromisoformat(body["today"])
        tz = str(body["tz"])
    except ValueError, KeyError, TypeError:
        return _response(400, {"error": "expected JSON with text, today (YYYY-MM-DD) and tz"})

    if not isinstance(text, str) or not text.strip():
        return _response(400, {"error": "the text is empty"})
    # Checked before the model is called: every token costs money.
    if len(text) > MAX_TEXT:
        return _response(413, {"error": f"the text is longer than {MAX_TEXT} characters"})

    model = parser_model()
    request_id = getattr(context, "aws_request_id", None)
    started = time.monotonic()
    try:
        agenda, usage = parse_agenda(text, today, tz, model)
    except AgendaThrottled:
        _log(event="agenda_throttled", model=model, request_id=request_id)
        return _response(503, {"error": "the AI service is busy, try again in a minute"})
    except AgendaParseError as e:
        _log(event="agenda_failed", model=model, request_id=request_id, error=str(e))
        return _response(422, {"error": str(e)})
    except Exception as e:  # noqa: BLE001 - Bedrock down, access denied, ...
        _log(event="agenda_error", model=model, request_id=request_id, error=repr(e))
        return _response(502, {"error": "the AI service is unavailable"})

    _log(
        event="agenda_parsed",
        user="anonymous",  # no sign-in yet: Cognito arrives with Lab 4 (see ADR 0006)
        request_id=request_id,
        model=model,
        prompt_version=PROMPT_VERSION,
        **usage.as_dict(),
        text_chars=len(text),
        latency_ms=int((time.monotonic() - started) * 1000),
        cost_usd=cost_usd(model, usage),
    )
    return _response(
        200,
        {
            "agenda": agenda.model_dump(mode="json"),
            "model": model,
            "prompt_version": PROMPT_VERSION,
        },
    )
