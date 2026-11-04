"""Lab 8, Part 3 - consumer.

Reads `payments`, drops duplicates, and prints the failure share per paymentMethod in
one-minute windows of event time (modifiedDate). A window closes 2 minutes after it
ends (the wait for late events); an alert is printed when a share is above 10%.

    python consumer.py                  # group "failure-monitor", wait 120 s
    python consumer.py --lateness 0     # experiment 4: no waiting for late events
    python consumer.py --from-start     # a new group that reads the topic from the beginning

Ctrl+C prints the totals: duplicates dropped, late events rejected, alerts.
"""

from __future__ import annotations

import argparse
import json
import uuid

from confluent_kafka import Consumer, KafkaException
from windowing import FailureMonitor


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--bootstrap", default="localhost:19092")
    ap.add_argument("--topic", default="payments")
    ap.add_argument("--group", default="failure-monitor")
    ap.add_argument(
        "--from-start", action="store_true", help="use a fresh group id and read from offset 0"
    )
    ap.add_argument(
        "--lateness", type=int, default=120, help="seconds to wait for late events (default 120)"
    )
    ap.add_argument("--threshold", type=float, default=0.10)
    ap.add_argument(
        "--min-finished",
        type=int,
        default=10,
        help="skip a method with fewer finished payments in a window",
    )
    ap.add_argument("--quiet", action="store_true", help="print only alerts, not every window")
    args = ap.parse_args()

    group = f"{args.group}-{uuid.uuid4().hex[:6]}" if args.from_start else args.group
    consumer = Consumer(
        {
            "bootstrap.servers": args.bootstrap,
            "group.id": group,
            "auto.offset.reset": "earliest",  # a new group starts at the beginning of the log
            "enable.auto.commit": True,  # the position is saved, so a restart resumes
        }
    )

    def on_assign(_consumer, partitions):
        print(f"[{group}] assigned partitions: {sorted(p.partition for p in partitions)}")

    def on_revoke(_consumer, partitions):
        print(f"[{group}] giving back partitions: {sorted(p.partition for p in partitions)}")

    consumer.subscribe([args.topic], on_assign=on_assign, on_revoke=on_revoke)
    monitor = FailureMonitor(
        lateness=args.lateness, threshold=args.threshold, min_finished=args.min_finished
    )
    print(
        f"reading '{args.topic}' as group '{group}', "
        f"waiting {args.lateness}s for late events. Ctrl+C to stop."
    )

    try:
        while True:
            msg = consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                raise KafkaException(msg.error())
            for window in monitor.add(json.loads(msg.value())):
                if window.alerts or not args.quiet:
                    print(window.render())
    except KeyboardInterrupt:
        pass
    finally:
        consumer.close()  # commits the offsets and leaves the group
        print("\n" + monitor.summary())


if __name__ == "__main__":
    main()
