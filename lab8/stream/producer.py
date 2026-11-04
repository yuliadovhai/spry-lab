"""Lab 8, Part 3 - producer.

Replays one day of payment webhooks into the Redpanda topic `payments`, in the order
they were received (receivedAt), at about 20 payments a second. The message key is
invoiceId, so every event of one payment lands in the same partition.

    python producer.py data/events.jsonl                    # the whole day (~25 min)
    python producer.py data/events.jsonl --start 08:00 --minutes 120
    python producer.py data/events.jsonl --fail-rate 0.3    # experiment 3
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from confluent_kafka import Producer
from replay import inject_failures, load_events, paced, select_window, speed_for


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("file", type=Path, help="one day of events, e.g. data/events.jsonl")
    ap.add_argument("--bootstrap", default="localhost:19092")
    ap.add_argument("--topic", default="payments")
    ap.add_argument("--rate", type=float, default=20.0, help="payments per second (default 20)")
    ap.add_argument("--start", help="begin at this receivedAt time of day, HH:MM (UTC)")
    ap.add_argument("--minutes", type=int, help="replay only this many minutes of the day")
    ap.add_argument(
        "--fail-rate", type=float, default=0.0, help="turn this share of successes into failures"
    )
    args = ap.parse_args()

    events = select_window(load_events(args.file), args.start, args.minutes)
    changed = inject_failures(events, args.fail_rate)
    speed = speed_for(events, args.rate)
    payments = len({e["invoiceId"] for e in events})
    print(
        f"{len(events)} events, {payments} payments, x{speed:.0f} real time"
        + (f", {changed} successes turned into failures" if changed else "")
    )

    producer = Producer({"bootstrap.servers": args.bootstrap, "linger.ms": 20, "acks": "all"})
    sent = 0
    last_report = time.monotonic()
    try:
        for e in paced(events, speed):
            producer.produce(
                args.topic,
                key=e["invoiceId"].encode(),
                value=json.dumps(e, ensure_ascii=False).encode(),
            )
            producer.poll(0)  # serve delivery callbacks, keep the queue moving
            sent += 1
            if time.monotonic() - last_report >= 5:
                print(f"  sent {sent}/{len(events)}  (now at receivedAt {e['receivedAt']})")
                last_report = time.monotonic()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        producer.flush(10)
        print(f"done: {sent} events sent to '{args.topic}'")


if __name__ == "__main__":
    main()
