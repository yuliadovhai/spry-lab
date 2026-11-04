-- Lab 8, Part 4: SQL over the data that came through the stream.
-- After: aws glue start-crawler --name lab8-payments-stream  (wait ~1 min until READY)

SHOW TABLES IN lab8_stream;

-- The crawler names the table after the folder: payments_stream.
SELECT count(*) AS events, count(DISTINCT invoiceid) AS payments
FROM lab8_stream.payments_stream;

-- The same failure-share question as the Lambda, over everything that arrived.
WITH e AS (SELECT DISTINCT invoiceid, status, modifieddate, paymentmethod
           FROM lab8_stream.payments_stream)
SELECT
  paymentmethod,
  count_if(status IN ('success', 'failure'))                              AS finished,
  count_if(status = 'failure')                                            AS failed,
  round(100.0 * count_if(status = 'failure')
        / nullif(count_if(status IN ('success', 'failure')), 0), 2)       AS failure_pct
FROM e
GROUP BY 1
ORDER BY failure_pct DESC;
