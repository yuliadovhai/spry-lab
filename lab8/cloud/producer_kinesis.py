"""Lab 8, Part 4 - producer for the cloud.

The same replay as Part 3 (receivedAt order, ~20 payments a second, key = invoiceId),
but into Kinesis Data Streams with PutRecords, up to 500 records per call.
Every record ends with a newline, so Firehose writes valid JSON Lines to S3.

    python producer_kinesis.py ../stream/data/events.jsonl --start 08:00 --minutes 60
    python producer_kinesis.py ../stream/data/events.jsonl \
        --start 12:00 --minutes 10 --fail-rate 0.3
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import boto3

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "stream"))
from replay import inject_failures, load_events, paced, select_window, speed_for  # noqa: E402

MAX_BATCH = 500


def send(client, stream: str, batch: list[dict]) -> int:
    """PutRecords with a retry of the records Kinesis throttled. Returns records sent."""
    records = [
        {
            "Data": (json.dumps(e, ensure_ascii=False) + "\n").encode(),
            "PartitionKey": e["invoiceId"],
        }
        for e in batch
    ]
    for attempt in range(5):
        resp = client.put_records(StreamName=stream, Records=records)
        if resp["FailedRecordCount"] == 0:
            return len(batch)
        records = [r for r, res in zip(records, resp["Records"]) if "ErrorCode" in res]
        time.sleep(0.2 * 2**attempt)
    raise RuntimeError(f"{len(records)} records still failing after retries")


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("file", type=Path)
    ap.add_argument("--stream", default="lab8-payments")
    ap.add_argument("--region", default="us-east-1")
    ap.add_argument("--rate", type=float, default=20.0, help="payments per second")
    ap.add_argument("--start", default="08:00", help="receivedAt time of day to start from (UTC)")
    ap.add_argument("--minutes", type=int, default=60, help="how many minutes of the day to send")
    ap.add_argument("--fail-rate", type=float, default=0.0)
    args = ap.parse_args()

    events = select_window(load_events(args.file), args.start, args.minutes)
    changed = inject_failures(events, args.fail_rate)
    speed = speed_for(events, args.rate)
    print(
        f"{len(events)} events, x{speed:.0f} real time"
        + (f", {changed} successes turned into failures" if changed else "")
    )

    client = boto3.client("kinesis", region_name=args.region)
    batch: list[dict] = []
    sent = 0
    flushed_at = time.monotonic()
    for e in paced(events, speed):
        batch.append(e)
        if len(batch) >= MAX_BATCH or time.monotonic() - flushed_at >= 0.5:
            sent += send(client, args.stream, batch)
            batch, flushed_at = [], time.monotonic()
            print(f"  sent {sent}/{len(events)}  (receivedAt {e['receivedAt']})", end="\r")
    if batch:
        sent += send(client, args.stream, batch)
    print(f"\ndone: {sent} records into {args.stream}")


if __name__ == "__main__":
    main()
