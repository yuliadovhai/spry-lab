"""Lab 8, Part 4 - the failure-rate check on the Kinesis stream.

Kinesis hands the function a batch of records (up to 10 000 or 60 s worth). For the
batch: drop duplicates, count finished payments per paymentMethod, and if a method's
failure share is above THRESHOLD, publish one e-mail through SNS.

This is a micro-batch check by arrival, not an event-time window like the local
consumer: Lambda keeps no state between calls.
"""

from __future__ import annotations

import base64
import json
import os

import boto3

sns = boto3.client("sns")
TOPIC_ARN = os.environ["TOPIC_ARN"]
THRESHOLD = float(os.environ.get("THRESHOLD", "0.10"))
MIN_FINISHED = int(os.environ.get("MIN_FINISHED", "20"))


def handler(event, _context):
    seen: set[tuple[str, str, str]] = set()
    stats: dict[str, list[int]] = {}  # method -> [finished, failed]
    duplicates = 0
    times: list[str] = []

    for record in event["Records"]:
        e = json.loads(base64.b64decode(record["kinesis"]["data"]))
        key = (e["invoiceId"], e["status"], e["modifiedDate"])
        if key in seen:
            duplicates += 1
            continue
        seen.add(key)
        times.append(e["modifiedDate"])
        if e["status"] not in ("success", "failure"):
            continue
        s = stats.setdefault(e.get("paymentMethod") or "unknown", [0, 0])
        s[0] += 1
        s[1] += e["status"] == "failure"

    shares = {m: round(f / n, 4) for m, (n, f) in stats.items() if n}
    breaching = {
        m: shares[m] for m, (n, _f) in stats.items() if n >= MIN_FINISHED and shares[m] > THRESHOLD
    }
    span = f"{min(times)} .. {max(times)}" if times else "-"

    # One structured log line per batch (CloudWatch Logs Insights can query it).
    print(
        json.dumps(
            {
                "records": len(event["Records"]),
                "duplicates": duplicates,
                "event_time": span,
                "finished_by_method": {m: n for m, (n, _f) in stats.items()},
                "failure_share": shares,
                "alert": sorted(breaching),
            }
        )
    )

    if breaching:
        lines = [
            f"{m}: {shares[m]:.1%} failed ({stats[m][1]} of {stats[m][0]})"
            for m in sorted(breaching)
        ]
        sns.publish(
            TopicArn=TOPIC_ARN,
            Subject=f"Payments: failure share above {THRESHOLD:.0%}",
            Message=f"Event time {span}\n\n" + "\n".join(lines),
        )
    return {"records": len(event["Records"]), "alerts": len(breaching)}
