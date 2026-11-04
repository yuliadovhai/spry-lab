-- Way B: after the Glue Crawler has run (database lab8_crawler), compare its schema.
-- The crawler names the table after the S3 folder, usually "payments".

SHOW CREATE TABLE lab8_crawler.payments;

SHOW PARTITIONS lab8_crawler.payments;

-- The same query 4 through the crawler's table, to show it works (or where it breaks).
SELECT paymentmethod, count(*) AS events
FROM lab8_crawler.payments
GROUP BY 1
ORDER BY 2 DESC;
