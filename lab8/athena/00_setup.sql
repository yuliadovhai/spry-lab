-- Lab 8, Part 2, Way A. Run in the Athena query editor, one statement at a time.
-- Bucket: spry-lab8-416670858269 (our copy of s3://ucu-ooad-lab8-payments/payments/).

CREATE DATABASE IF NOT EXISTS lab8;

-- 1. The table: raw JSON Lines, one webhook event per line, partitioned by day.
--    Dates stay strings here (the JSON SerDe does not parse ISO-8601 with "Z" into
--    TIMESTAMP reliably); the payments view converts them once.
CREATE EXTERNAL TABLE IF NOT EXISTS lab8.payment_events (
  invoiceid     string,
  status        string,
  failurereason string,
  amount        bigint,
  finalamount   bigint,
  ccy           int,
  reference     string,
  createddate   string,
  modifieddate  string,
  receivedat    string,
  merchantid    string,
  merchantname  string,
  mcc           string,
  customerid    string,
  paymentmethod string,
  device        string
)
PARTITIONED BY (dt string)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ('case.insensitive' = 'true', 'ignore.malformed.json' = 'false')
LOCATION 's3://spry-lab8-416670858269/payments/';

-- Load the 31 dt=... partitions.
MSCK REPAIR TABLE lab8.payment_events;

-- Check: about three million.
SELECT count(*) AS events FROM lab8.payment_events;
