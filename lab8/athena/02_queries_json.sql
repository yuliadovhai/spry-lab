-- Queries 3-6 over the deduplicated view (reads the raw JSON).
-- After each run, note "Run time" and "Data scanned" under the results.

-- 3. Turnover by merchant and currency, successful payments only, in major units.
SELECT
  merchantname,
  CASE ccy WHEN 980 THEN 'UAH' WHEN 840 THEN 'USD' WHEN 978 THEN 'EUR'
           ELSE CAST(ccy AS varchar) END       AS currency,
  count(*)                                    AS payments,
  round(sum(finalamount) / 100.0, 2)          AS turnover
FROM lab8.payments
WHERE status = 'success'
GROUP BY 1, 2
ORDER BY currency, turnover DESC;

-- 4. Failure rate per payment method and device (finished payments only), highest first.
SELECT
  paymentmethod,
  device,
  count(*)                                                     AS finished,
  count_if(status = 'failure')                                 AS failed,
  round(100.0 * count_if(status = 'failure') / count(*), 2)    AS failure_pct
FROM lab8.payments
WHERE status IN ('success', 'failure')
GROUP BY 1, 2
ORDER BY failure_pct DESC;

-- 5. Peak hours: payments per hour of the day (UTC, by creation time).
SELECT
  hour(created_at) AS hour_utc,
  count(*)         AS payments
FROM lab8.payments
GROUP BY 1
ORDER BY 1;

-- 6. Late events: received more than 60 s (and more than 1 h) after they happened.
--    Counted over distinct events (exact duplicates removed), not over payments.
WITH e AS (SELECT DISTINCT * FROM lab8.payment_events),
d AS (
  SELECT date_diff('second',
                   from_iso8601_timestamp(modifieddate),
                   from_iso8601_timestamp(receivedat)) AS delay_s
  FROM e
)
SELECT
  count(*)                                               AS events,
  count_if(delay_s > 60)                                 AS late_over_60s,
  round(100.0 * count_if(delay_s > 60) / count(*), 2)    AS pct_over_60s,
  count_if(delay_s > 3600)                               AS late_over_1h,
  round(100.0 * count_if(delay_s > 3600) / count(*), 4)  AS pct_over_1h,
  max(delay_s)                                           AS max_delay_s
FROM d;
