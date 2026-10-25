-- Flink inserts one row per device per 1-minute window that looks anomalous.
CREATE TABLE IF NOT EXISTS anomalies (
    device_id      TEXT,
    window_start   TIMESTAMP,
    total_bytes    BIGINT,
    distinct_ports BIGINT,
    detected_at    TIMESTAMP DEFAULT now()
);
