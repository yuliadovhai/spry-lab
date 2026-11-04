-- 2. Deduplication: one row per invoiceId, the latest status.
--    Step 1 (DISTINCT) drops the ~1% exact duplicates: the same event delivered twice.
--    Step 2 (row_number) keeps the newest event of each payment by event time
--    (modifiedDate). A status rank breaks ties when two statuses share a second.
CREATE OR REPLACE VIEW lab8.payments AS
WITH distinct_events AS (
  SELECT DISTINCT
    invoiceid, status, failurereason, amount, finalamount, ccy, reference,
    createddate, modifieddate, receivedat,
    merchantid, merchantname, mcc, customerid, paymentmethod, device, dt
  FROM lab8.payment_events
),
ranked AS (
  SELECT
    *,
    row_number() OVER (
      PARTITION BY invoiceid
      ORDER BY
        from_iso8601_timestamp(modifieddate) DESC,
        CASE status WHEN 'success' THEN 3 WHEN 'failure' THEN 3
                    WHEN 'processing' THEN 2 ELSE 1 END DESC,
        receivedat DESC
    ) AS rn
  FROM distinct_events
)
SELECT
  invoiceid, status, failurereason, amount, finalamount, ccy, reference,
  CAST(from_iso8601_timestamp(createddate)  AS timestamp(3)) AS created_at,
  CAST(from_iso8601_timestamp(modifieddate) AS timestamp(3)) AS modified_at,
  CAST(from_iso8601_timestamp(receivedat)   AS timestamp(3)) AS received_at,
  merchantid, merchantname, mcc, customerid, paymentmethod, device,
  dt
FROM ranked
WHERE rn = 1;

-- Scale: events, exact duplicates, unique payments.
WITH d AS (SELECT DISTINCT * FROM lab8.payment_events)
SELECT
  (SELECT count(*) FROM lab8.payment_events)                 AS events,
  (SELECT count(*) FROM d)                                   AS distinct_events,
  (SELECT count(*) FROM lab8.payment_events)
    - (SELECT count(*) FROM d)                               AS exact_duplicates,
  (SELECT count(DISTINCT invoiceid) FROM lab8.payment_events) AS unique_invoices,
  (SELECT count(*) FROM lab8.payments)                       AS rows_in_view;

-- Final statuses in the view (most should be success or failure).
SELECT status, count(*) AS payments
FROM lab8.payments
GROUP BY status
ORDER BY payments DESC;
