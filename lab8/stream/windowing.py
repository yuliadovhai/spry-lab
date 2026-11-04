"""Event-time tumbling windows with a waiting time for late events.

Pure Python, no Kafka here, so the logic can be tested on its own (test_windowing.py).

* Duplicates: an event is identified by (invoiceId, status, modifiedDate); a repeat is dropped.
* Window: one minute of event time (modifiedDate), e.g. [08:15:00, 08:16:00).
* Watermark: the latest event time seen minus the waiting time (`lateness`).
  A window closes once the watermark passes its end. With the default 120 s,
  the 08:15 window closes when an event of 08:18:00 or later arrives.
* An event whose window has already closed is late: it is counted and rejected.
* Only finished events (success, failure) count towards the failure share.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import UTC, datetime

FINISHED = ("success", "failure")


def epoch(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def hhmm(ts: float) -> str:
    return datetime.fromtimestamp(ts, UTC).strftime("%H:%M")


@dataclass
class MethodStats:
    finished: int = 0
    failed: int = 0

    @property
    def share(self) -> float:
        return self.failed / self.finished if self.finished else 0.0


@dataclass
class ClosedWindow:
    start: float
    by_method: dict[str, MethodStats]
    alerts: list[str]

    def render(self) -> str:
        parts = [
            f"{m} {s.share:6.1%} of {s.finished:<4}" for m, s in sorted(self.by_method.items())
        ]
        line = f"[{hhmm(self.start)}-{hhmm(self.start + 60)}] " + (
            " | ".join(parts) or "no finished payments"
        )
        for method in self.alerts:
            s = self.by_method[method]
            line += (
                f"\n    ALERT {hhmm(self.start)} {method}: "
                f"{s.share:.1%} failed ({s.failed} of {s.finished})"
            )
        return line


@dataclass
class FailureMonitor:
    size: int = 60  # window length, seconds
    lateness: int = 120  # how long to wait for late events, seconds
    threshold: float = 0.10  # alert above this failure share
    min_finished: int = 10  # ignore windows with too few payments of a method

    seen: set[tuple[str, str, str]] = field(default_factory=set)
    open: dict[float, dict[str, MethodStats]] = field(
        default_factory=lambda: defaultdict(lambda: defaultdict(MethodStats))
    )
    max_event_time: float = float("-inf")
    closed_until: float = float("-inf")  # every window ending at or before this is closed

    events: int = 0
    duplicates: int = 0
    late: int = 0
    windows_closed: int = 0
    alerts: int = 0

    def add(self, event: dict) -> list[ClosedWindow]:
        """Take one event; return the windows that this event closed."""
        self.events += 1
        key = (event["invoiceId"], event["status"], event["modifiedDate"])
        if key in self.seen:
            self.duplicates += 1
            return []
        self.seen.add(key)

        t = epoch(event["modifiedDate"])
        start = t - (t % self.size)
        if start + self.size <= self.closed_until:
            self.late += 1  # its window has already been reported
            return []

        if event["status"] in FINISHED:
            stats = self.open[start][event.get("paymentMethod") or "unknown"]
            stats.finished += 1
            stats.failed += event["status"] == "failure"

        self.max_event_time = max(self.max_event_time, t)
        return self._close(self.max_event_time - self.lateness)

    def flush(self) -> list[ClosedWindow]:
        """Close everything still open (on shutdown)."""
        return self._close(float("inf"))

    def _close(self, watermark: float) -> list[ClosedWindow]:
        done = []
        for start in sorted(s for s in self.open if s + self.size <= watermark):
            by_method = dict(self.open.pop(start))
            alerts = [
                m
                for m, s in sorted(by_method.items())
                if s.finished >= self.min_finished and s.share > self.threshold
            ]
            done.append(ClosedWindow(start, by_method, alerts))
            self.windows_closed += 1
            self.alerts += len(alerts)
        if watermark not in (float("inf"), float("-inf")):
            # Windows end on whole minutes; everything up to the watermark is now closed.
            self.closed_until = max(self.closed_until, watermark - (watermark % self.size))
        return done

    def summary(self) -> str:
        return (
            f"events read {self.events}, duplicates dropped {self.duplicates}, "
            f"late rejected {self.late}, windows closed {self.windows_closed}, "
            f"alerts {self.alerts}, ids remembered {len(self.seen)}"
        )
