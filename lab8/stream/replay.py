"""Shared by the local producer (Redpanda) and the cloud producer (Kinesis):
read one day of webhook events, order them by arrival, and pace them in time."""

from __future__ import annotations

import json
import time
import zlib
from collections.abc import Iterator
from datetime import datetime
from pathlib import Path


def parse_ts(value: str) -> datetime:
    """'2026-10-01T08:15:22Z' -> an aware datetime."""
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def load_events(path: Path) -> list[dict]:
    """All events of the file, in the order they reached us (receivedAt)."""
    with path.open(encoding="utf-8") as fh:
        events = [json.loads(line) for line in fh if line.strip()]
    events.sort(key=lambda e: e["receivedAt"])
    return events


def select_window(events: list[dict], start: str | None, minutes: int | None) -> list[dict]:
    """Keep the events received from HH:MM on, for at most `minutes` minutes."""
    if not events or (start is None and minutes is None):
        return events
    day = parse_ts(events[0]["receivedAt"])
    begin = day
    if start is not None:
        hh, mm = (int(x) for x in start.split(":"))
        begin = day.replace(hour=hh, minute=mm, second=0, microsecond=0)
    out = [e for e in events if parse_ts(e["receivedAt"]) >= begin]
    if minutes is not None and out:
        first = parse_ts(out[0]["receivedAt"])
        out = [e for e in out if (parse_ts(e["receivedAt"]) - first).total_seconds() < minutes * 60]
    return out


def inject_failures(events: list[dict], rate: float) -> int:
    """Turn the successful outcome of about `rate` of the payments into a failure.
    The choice is a hash of invoiceId, so every event of a payment agrees.
    Returns how many events were changed."""
    if rate <= 0:
        return 0
    changed = 0
    for e in events:
        bucket = zlib.crc32(e["invoiceId"].encode()) % 10_000
        if e["status"] == "success" and bucket < rate * 10_000:
            e["status"] = "failure"
            e["failureReason"] = "Injected failure (experiment)"
            e["finalAmount"] = 0
            changed += 1
    return changed


def speed_for(events: list[dict], payments_per_sec: float) -> float:
    """How many times faster than real time to replay, so that on average
    `payments_per_sec` payments go out each second."""
    if len(events) < 2:
        return 1.0
    span = (parse_ts(events[-1]["receivedAt"]) - parse_ts(events[0]["receivedAt"])).total_seconds()
    payments = len({e["invoiceId"] for e in events})
    if span <= 0 or payments == 0:
        return 1.0
    return max(1.0, payments_per_sec / (payments / span))


def paced(events: list[dict], speed: float) -> Iterator[dict]:
    """Yield the events keeping their gaps in receivedAt, `speed` times faster.
    Late events therefore come out late, as they would in production."""
    if not events:
        return
    t0_event = parse_ts(events[0]["receivedAt"])
    t0_wall = time.monotonic()
    for e in events:
        due = t0_wall + (parse_ts(e["receivedAt"]) - t0_event).total_seconds() / speed
        delay = due - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        yield e
