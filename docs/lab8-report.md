# Lab 8 — Big Data on AWS: report

- **Repository:** https://github.com/yuliadovhai/spry-lab — folder `lab8/`, runbook `lab8/README.md`
- **Bucket:** `s3://spry-lab8-416670858269/` (`payments/` raw JSON, `curated/payments/` Parquet,
  `payments-stream/` what came through Kinesis)
- Numbers marked **TODO** are filled in from the runs; everything else is the analysis.

## Part 1 — Uklon: the path of one ride

**What happens if the real-time road falls behind by 10 minutes? And the batch road by a day?**

Real time, 10 minutes behind: the product breaks while the rider waits. Matching reads driver
positions from Redis that are 10 minutes old, so it offers drivers who have already left (a car
moves ~5 km in that time); surge is computed for demand that has passed, so prices are wrong in
both directions; ETA and "your driver is coming" pushes lie. Riders cancel, drivers idle, money
is lost every minute. Kinesis keeps the events (24 h), so nothing is lost and Flink catches up,
but stale answers cannot be fixed afterwards — this road has an SLA in seconds.

Batch, one day behind: almost nobody notices in the moment. Dashboards in Quick show yesterday
instead of today, the nightly ETA/demand models train on data one day older, finance closes a
day later. Raw JSON already sits in S3, so the Glue job simply re-runs on the missing partition
and the result is the same as if it had been on time. The cost is slower decisions, not broken
rides.

**Why does GPS not go through Lambda?**

Volume and shape of the traffic. 580 million pings a day is ~6 700 a second on average, more at
peak. One Lambda invocation per ping (behind API Gateway) is billed per request and per
millisecond, adds a cold start and a new HTTPS connection every 3 seconds per driver, drains the
phone's battery and mobile data, and gives tens of thousands of dollars a month for work that
does nothing but forward a message. GPS is a continuous, ordered stream per driver: MQTT keeps
one persistent connection (IoT Core), Kinesis buffers the pings in order per key, and Flink keeps
state (last position, district counts) across messages, which a stateless Lambda cannot.
Lambda fits the opposite job in the diagram: rare events, such as "a new file arrived in S3".

**Which parts would a small startup drop first, and what would it lose?**

1. **Managed Flink, DynamoDB for surge** — compute surge in the matching service (or a cron every
   minute) from Redis/Postgres. Loses exact per-district, per-second surge and alerting; fine at
   small scale.
2. **IoT Core** — drivers send GPS over HTTPS/WebSocket to the API. Loses cheap persistent
   connections and battery efficiency; acceptable for hundreds of drivers, not hundreds of thousands.
3. **DMS change data capture** — query Aurora directly or write events from the services. Loses a
   clean event history of every DB change and decoupling of analytics from the production DB.
4. **Glue job + Parquet, Data Catalog, Quick** — Athena over raw JSON, or a read replica plus
   Metabase. Loses cheap fast queries on big data (Part 2 shows how much Parquet saves).
5. **SageMaker** — ETA from a maps API, demand from simple averages. Loses tailored models.

What the startup keeps: the app, one service, the database, and S3 as the place where raw events
land, because history cannot be recreated later. The price of dropping parts is mostly scale and
precision, not features.

## Part 2 — Batch: payments in S3

SQL: `lab8/athena/`. The table reads the JSON as-is; the view `lab8.payments` deduplicates;
`lab8.payments_parquet` is the CTAS copy in `curated/`.

### Scale

| | value |
|---|---|
| events (`count(*)`) | TODO |
| exact duplicates (events − `DISTINCT` events) | TODO |
| unique `invoiceId` (= rows in the view) | TODO |
| events more than 60 s late | TODO of TODO (TODO %) |
| events more than 1 hour late | TODO (TODO %) |

### Results of queries 2–6

Screenshots / CSV attached: `turnover.csv`, `failure_rate.csv`, `peak_hours.csv`, `late.csv`. Short:

- **Turnover:** TODO (top merchants per currency).
- **Failure rate:** TODO (highest method + device, lowest).
- **Peak hours:** TODO (busiest hour UTC, quietest).
- **Late events:** TODO.

### JSON vs Parquet

| query | JSON: data scanned | JSON: run time | Parquet: data scanned | Parquet: run time | cheaper |
|---|---|---|---|---|---|
| 3 turnover | TODO | TODO | TODO | TODO | TODO× |
| 4 failure rate | TODO | TODO | TODO | TODO | TODO× |
| 5 peak hours | TODO | TODO | TODO | TODO | TODO× |

Why: on JSON every query reads every byte of all 1.2 GB (Athena cannot skip fields inside a
line) and then deduplicates three million events again. Parquet is columnar and compressed, so a
query reads only its columns (query 5 reads one timestamp column), and the files already hold the
one million deduplicated payments. Athena bills $5 per TB scanned, so the ratio of "Data
scanned" is exactly the ratio of cost.

### Why DISTINCT comes before row_number(), and what breaks without deduplication

`row_number()` keeps one row per `invoiceId` — the newest by `modifiedDate`. It is the right
tool for "several statuses of one payment", but it does not know that two rows are the same
event: if `success` arrives twice, both copies have the same `modifiedDate`, and the order between
them is arbitrary. `DISTINCT` first collapses exact copies of the same event, so the ranking only
sees *different* events and its result is deterministic (the tie-break on status covers two
different statuses within one second). It also makes the window cheaper: fewer rows to sort.

Without deduplication every number is wrong in a different way: turnover counts a payment with a
repeated `success` twice; failure rate counts a payment with `created → processing → failure`
three times (and the non-final rows as "not failed"); peak hours count events, not payments
(×2–3); late-event counts include the copies. The duplicates are ~1 % of events, but the
multiple statuses per payment make the raw table three times larger than the truth.

### Way B — Glue Crawler

Crawler `lab8-payments-crawler` over `s3://spry-lab8-416670858269/payments/`, database
`lab8_crawler`. Its DDL (`SHOW CREATE TABLE`): TODO screenshot.

- **Types:** `amount`, `finalamount` → TODO (expected `bigint`), `ccy` → TODO (expected `int`),
  `createddate`/`modifieddate`/`receivedat` → TODO (expected `string`: a crawler does not turn
  ISO-8601 text in JSON into `timestamp`).
- **Partition:** `dt` → TODO (expected: yes, a `string` partition key, from the `dt=` folders).
- **failureReason:** TODO. A JSON crawler merges the fields it samples; a field present only on
  failed payments becomes a nullable `string` column, and rows without it read as `NULL`. If the
  sampled lines had none, the column would be missing altogether.
- **Which is more convenient, and why hand-written schemas are still common:** the crawler is
  fast and follows new fields automatically. A hand-written schema is a contract: exact types
  (`bigint` for money, the dates we choose to parse), stable names that a change in the data
  cannot silently rename or retype, `case.insensitive`, and no surprise partitions or tables when
  a stray file lands in the folder. Production pipelines read many tables in code and need that
  stability, so they write DDL (or keep it in Terraform) and use crawlers for exploration.

## Part 3 — Streaming locally: Redpanda + Python

`lab8/stream/`: `docker-compose.yml` (Redpanda + Console), `producer.py` (replays one day,
2026-10-15, by `receivedAt`, ~20 payments/s, key `invoiceId`), `consumer.py` +
`windowing.py` (dedup, 1-minute event-time windows on `modifiedDate`, wait 120 s, alert > 10 %).
Unit tests: `python lab8/stream/test_windowing.py`.

How the window works: the watermark is the latest event time seen minus 120 s. The 08:15 window
closes when an event of 08:18:00 arrives; an event of 08:15:xx that comes after that is "late"
and rejected (counted). The 10 % alert only fires for a method with at least 10 finished payments
in the minute, otherwise 1 failure out of 3 would be an alert.

| experiment | what we did | output (attached) | what changed in the numbers |
|---|---|---|---|
| baseline | producer + one consumer | TODO | TODO alerts, TODO duplicates, TODO late |
| 1. stop/start | Ctrl+C the consumer for a minute, start again | TODO | Nothing lost: the group's offsets were committed, the consumer resumes from where it stopped and catches up (fast burst of windows). Only the half-filled windows held in memory at the stop are lost — state is not in Kafka. |
| 2. two consumers | two consumers, same group | TODO screenshot of Console → Consumer groups | The 3 partitions are split 2 + 1; each sees only its payments (key = invoiceId keeps a payment in one partition, so dedup still works), and window shares are computed on half the data each. |
| 3. 30 % failures | `producer.py --fail-rate 0.3` | TODO | Alerts in almost every window, for every method (~30–40 % instead of TODO %). |
| 4. no waiting | `consumer.py --lateness 0` | TODO | Late rejected: TODO (vs TODO with 120 s). Windows close sooner, but the shares are computed without the late events, so they differ slightly; a payment whose `failure` arrives late is never counted. |

The set of seen ids (`ids remembered` in the summary) grows by every event — ~100 000 for a
day, millions in production. A real service keeps it in Redis or in Flink state with a TTL
(duplicates arrive within minutes, so a TTL of an hour is enough).

## Part 4 — Streaming in the cloud

Diagram: `docs/diagrams/lab8-cloud-pipeline.png`. Code: `lab8/cloud/main.tf` (Terraform, local
state), `lab8/cloud/lambda/alert.py`, `lab8/cloud/producer_kinesis.py`. Same data as Part 3.

Producer (laptop, `PutRecords`, key `invoiceId`) → Kinesis Data Streams `lab8-payments`
(on-demand) → Firehose (60 s buffer) → S3 `payments-stream/dt=…/` → Glue Crawler →
`lab8_stream.payments_stream` → Athena. In parallel, a Lambda on the stream counts the failure
share per method in each batch and publishes to SNS (e-mail) above 10 %.

Athena over the stream: TODO screenshot (`lab8/cloud/athena_stream.sql`).

**How it differs from local Redpanda:**

- Nothing to run or patch: no broker, no disk, scaling is the on-demand mode's problem. The price
  is per hour and per GB, and it runs only while we pay for it.
- Kinesis keeps data 24 h by default (Redpanda: as long as our disk allows); its "partitions" are
  shards and the client picks them by partition key, the same idea as the Kafka key.
- The consumer is not a long-running process with a consumer group but a Lambda that AWS calls
  with batches; it keeps no state between calls, so the check is per micro-batch by arrival time,
  not an event-time window with a wait for late events. For true event-time windows the managed
  answer is Managed Flink, at a much higher price.
- The stream also lands in S3 without code (Firehose), so the same events are available to SQL a
  minute later; locally we only printed them.

**What it cost:** TODO (Billing → Bills, or Cost Explorer by service). Expected: Kinesis
on-demand standard $0.04 per stream-hour + $0.08/GB in + $0.04/GB out; for ~TODO hours and a few
MB this is well under $1. Firehose, Lambda, SNS, Glue (one crawler run), Athena and S3 are cents
or free tier. Stream and Firehose deleted with `terraform destroy`: TODO screenshot.

## What we discuss in class (short notes)

- **Event time vs processing time:** our windows use event time (`modifiedDate`); processing
  time (`receivedAt`) would put a late `failure` into the wrong minute. A late event is accepted
  until the watermark passes its window, then counted and dropped (or could go to a side output).
- **JSON and Parquet both:** JSON is the raw, untouched truth we can always reprocess (new
  dedup rule, new field); Parquet is the curated, cheap-to-query copy derived from it.
- **Nightly batch vs seconds:** seconds when a person or a system acts on the answer right away
  (matching, fraud, alerts); a nightly batch for reports, finance and model training.
- **Managed vs self-run:** Kinesis/Flink/Glue remove brokers, upgrades, scaling and on-call, and
  bill per hour or per GB even when idle; Kafka and Spark ourselves are cheaper at scale but need
  people to run them.
