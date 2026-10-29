"""Run the parser from a laptop: `make llm-hello`, `make parse TEXT="..."`."""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import date

from app.ai.agenda import REGION, cost_usd, parse_agenda, parser_model, to_json


def hello() -> None:
    model = parser_model()
    if model.startswith("anthropic."):
        from anthropic import AnthropicBedrockMantle

        client = AnthropicBedrockMantle(aws_region=REGION)
        msg = client.messages.create(
            model=model,
            max_tokens=1024,
            output_config={"effort": "low"},
            messages=[{"role": "user", "content": "In one sentence: what is an ISO week?"}],
        )
        print(next(b.text for b in msg.content if b.type == "text"))
        print(msg.stop_reason, msg.usage.input_tokens, msg.usage.output_tokens)
    else:
        import boto3

        resp = boto3.client("bedrock-runtime", region_name=REGION).converse(
            modelId=model,
            messages=[
                {"role": "user", "content": [{"text": "In one sentence: what is an ISO week?"}]}
            ],
            inferenceConfig={"maxTokens": 200},
        )
        print(resp["output"]["message"]["content"][0]["text"])
        print(resp["stopReason"], resp["usage"])


def parse(text: str) -> None:
    tz = os.environ.get("PARSER_TZ", "Europe/Kyiv")
    started = time.monotonic()
    agenda, usage = parse_agenda(text, date.today(), tz)
    print(to_json(agenda))
    model = parser_model()
    print(
        json.dumps(
            {
                "model": model,
                **usage.as_dict(),
                "latency_ms": int((time.monotonic() - started) * 1000),
                "cost_usd": cost_usd(model, usage),
            }
        )
    )


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "hello"
    if command == "hello":
        hello()
    elif command == "parse":
        parse(sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read())
    else:
        sys.exit("usage: python -m app.ai.cli hello | parse TEXT")
