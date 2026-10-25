-- ============================================================
-- Flink SQL: real-time anomaly detection on network events
-- Paste each statement (ending with ;) into the Flink SQL client
-- ============================================================

-- 0. Client and job settings
SET 'sql-client.execution.result-mode' = 'tableau';
SET 'pipeline.name' = 'netflow-anomaly-detection';
SET 'execution.checkpointing.interval' = '30s';

-- 1. SOURCE: a table view over the Kafka topic
CREATE TABLE network_events (
  device_id   STRING,
  src_ip      STRING,
  dst_ip      STRING,
  dst_port    INT,
  protocol    STRING,
  `bytes`     BIGINT,              -- backticks: BYTES is a reserved word in Flink SQL
  event_time  TIMESTAMP(3),
  WATERMARK FOR event_time AS event_time - INTERVAL '5' SECOND
) WITH (
  'connector'                    = 'kafka',
  'topic'                        = 'network-events',
  'properties.bootstrap.servers' = 'kafka:29092',
  'properties.group.id'          = 'flink-anomaly',
  'scan.startup.mode'            = 'earliest-offset',
  'format'                       = 'json',
  'json.ignore-parse-errors'     = 'true'
);

-- 2. (optional) peek at the stream: stops after 5 rows
SELECT device_id, dst_port, `bytes`, event_time FROM network_events LIMIT 5;

-- 3. SINK: the Postgres table created by init.sql
CREATE TABLE anomalies (
  device_id       STRING,
  window_start    TIMESTAMP(3),
  total_bytes     BIGINT,
  distinct_ports  BIGINT
) WITH (
  'connector'  = 'jdbc',
  'url'        = 'jdbc:postgresql://postgres:5432/netmon',
  'table-name' = 'anomalies',
  'username'   = 'grafana',
  'password'   = 'grafana'
);

-- 4. THE JOB: 1-minute tumbling windows per device, keep only anomalies
--    spike    = more than 1 MB in a minute
--    portscan = more than 50 distinct destination ports in a minute
INSERT INTO anomalies
SELECT
  device_id,
  window_start,
  SUM(`bytes`)             AS total_bytes,
  COUNT(DISTINCT dst_port) AS distinct_ports
FROM TABLE(
  TUMBLE(TABLE network_events, DESCRIPTOR(event_time), INTERVAL '1' MINUTE)
)
GROUP BY device_id, window_start, window_end
HAVING SUM(`bytes`) > 1000000 OR COUNT(DISTINCT dst_port) > 50;