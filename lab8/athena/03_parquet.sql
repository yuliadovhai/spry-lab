-- 7. Parquet: the deduplicated payments, partitioned by dt, under curated/.
--    CTAS writes the files and registers the table in one go (31 partitions < the 100 limit).
CREATE TABLE lab8.payments_parquet
WITH (
  format            = 'PARQUET',
  write_compression = 'SNAPPY',
  external_location = 's3://spry-lab8-416670858269/curated/payments/',
  partitioned_by    = ARRAY['dt']
) AS
SELECT * FROM lab8.payments;

SELECT count(*) AS payments FROM lab8.payments_parquet;

-- Queries 3-5 again, now against Parquet. Compare "Data scanned" and "Run time".

-- 3 (Parquet). Turnover.
SELECT
  merchantname,
  CASE ccy WHEN 980 THEN 'UAH' WHEN 840 THEN 'USD' WHEN 978 THEN 'EUR'
           ELSE CAST(ccy AS varchar) END       AS currency,
  count(*)                                    AS payments,
  round(sum(finalamount) / 100.0, 2)          AS turnover
FROM lab8.payments_parquet
WHERE status = 'success'
GROUP BY 1, 2
ORDER BY currency, turnover DESC;

-- 4 (Parquet). Failure rate.
SELECT
  paymentmethod,
  device,
  count(*)                                                     AS finished,
  count_if(status = 'failure')                                 AS failed,
  round(100.0 * count_if(status = 'failure') / count(*), 2)    AS failure_pct
FROM lab8.payments_parquet
WHERE status IN ('success', 'failure')
GROUP BY 1, 2
ORDER BY failure_pct DESC;

-- 5 (Parquet). Peak hours.
SELECT
  hour(created_at) AS hour_utc,
  count(*)         AS payments
FROM lab8.payments_parquet
GROUP BY 1
ORDER BY 1;
