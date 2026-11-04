# Lab 8 — Big Data on AWS (payments)

Everything runs from the repository root. Account `416670858269`, region `us-east-1`.
Our bucket: **`spry-lab8-416670858269`**.

```
lab8/athena/   Part 2 — SQL for Athena (run in the console, file by file)
lab8/stream/   Part 3 — Redpanda (docker compose), producer.py, consumer.py
lab8/cloud/    Part 4 — Terraform (Kinesis, Firehose, Lambda, SNS, Glue), producer_kinesis.py
docs/lab8-report.md                 answers + results
docs/diagrams/lab8-cloud-pipeline.png   Part 4 diagram
```

## Part 2 — batch

```bash
make lab8-bucket          # creates the bucket, copies payments/ (server-side, ~1.2 GB, free in-region)
```
Athena console → Settings → **Query result location** `s3://spry-lab8-416670858269/athena-results/`.
Then run `lab8/athena/00_setup.sql`, `01_dedup_view.sql`, `02_queries_json.sql`, `03_parquet.sql`
one statement at a time; under each result note **Run time** and **Data scanned**.

Way B (Glue Crawler, console): Glue → Crawlers → Create, name `lab8-payments-crawler` → data source S3
`s3://spry-lab8-416670858269/payments/` → *Create new IAM role* `AWSGlueServiceRole-lab8` →
target database: *Add database* `lab8_crawler` → Create → **Run**. Then `04_crawler.sql`.

## Part 3 — streaming on the laptop

```bash
make lab8-stream-up       # Redpanda + Console (http://localhost:8080) + topic payments (3 partitions)
make lab8-venv            # python venv with confluent-kafka and boto3
make lab8-day             # downloads one day (dt=2026-10-15) to lab8/stream/data/events.jsonl

# two terminals:
lab8/.venv/bin/python lab8/stream/consumer.py
lab8/.venv/bin/python lab8/stream/producer.py lab8/stream/data/events.jsonl
```
Experiments: see the report, section Part 3.

## Part 4 — streaming in the cloud (billed by the hour: destroy when done)

```bash
terraform -chdir=lab8/cloud init
terraform -chdir=lab8/cloud apply -var alert_email=yuliadovhai@gmail.com   # confirm the SNS e-mail
lab8/.venv/bin/python lab8/cloud/producer_kinesis.py lab8/stream/data/events.jsonl --start 08:00 --minutes 60
lab8/.venv/bin/python lab8/cloud/producer_kinesis.py lab8/stream/data/events.jsonl --start 12:00 --minutes 10 --fail-rate 0.3
# wait ~2 min for Firehose, then:
aws glue start-crawler --name lab8-payments-stream
# Athena: lab8/cloud/athena_stream.sql
terraform -chdir=lab8/cloud destroy -var alert_email=yuliadovhai@gmail.com
```
