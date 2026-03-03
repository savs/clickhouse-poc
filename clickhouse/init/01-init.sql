-- Initialize ClickHouse database with sample tables

-- Create a sample metrics table
CREATE TABLE IF NOT EXISTS default.metrics (
    timestamp DateTime,
    metric_name String,
    value Float64,
    tags Map(String, String)
) ENGINE = MergeTree()
ORDER BY (metric_name, timestamp);

-- Create a sample logs table
CREATE TABLE IF NOT EXISTS default.logs (
    timestamp DateTime,
    level String,
    message String,
    service String,
    host String
) ENGINE = MergeTree()
ORDER BY (timestamp, service);

-- Create a sample traces table
CREATE TABLE IF NOT EXISTS default.traces (
    trace_id String,
    span_id String,
    parent_span_id String,
    operation_name String,
    start_time DateTime64(9),
    duration_ns UInt64,
    service_name String,
    tags Map(String, String)
) ENGINE = MergeTree()
ORDER BY (service_name, start_time);

-- Insert sample data into metrics
INSERT INTO default.metrics (timestamp, metric_name, value, tags) VALUES
    (now() - INTERVAL 1 HOUR, 'cpu_usage', 45.2, {'host': 'server1', 'env': 'prod'}),
    (now() - INTERVAL 30 MINUTE, 'cpu_usage', 62.8, {'host': 'server1', 'env': 'prod'}),
    (now() - INTERVAL 15 MINUTE, 'cpu_usage', 38.5, {'host': 'server1', 'env': 'prod'}),
    (now() - INTERVAL 1 HOUR, 'memory_usage', 78.3, {'host': 'server1', 'env': 'prod'}),
    (now() - INTERVAL 30 MINUTE, 'memory_usage', 82.1, {'host': 'server1', 'env': 'prod'}),
    (now() - INTERVAL 15 MINUTE, 'memory_usage', 75.9, {'host': 'server1', 'env': 'prod'});

-- Insert sample data into logs
INSERT INTO default.logs (timestamp, level, message, service, host) VALUES
    (now() - INTERVAL 1 HOUR, 'INFO', 'Application started successfully', 'web-app', 'server1'),
    (now() - INTERVAL 45 MINUTE, 'WARN', 'High memory usage detected', 'web-app', 'server1'),
    (now() - INTERVAL 30 MINUTE, 'ERROR', 'Database connection timeout', 'web-app', 'server1'),
    (now() - INTERVAL 15 MINUTE, 'INFO', 'Request processed successfully', 'web-app', 'server1');

-- Insert sample data into traces
INSERT INTO default.traces (trace_id, span_id, parent_span_id, operation_name, start_time, duration_ns, service_name, tags) VALUES
    ('trace1', 'span1', '', 'http_request', now() - INTERVAL 1 HOUR, 150000000, 'api-gateway', {'method': 'GET', 'path': '/api/users'}),
    ('trace1', 'span2', 'span1', 'database_query', now() - INTERVAL 1 HOUR, 50000000, 'user-service', {'query': 'SELECT * FROM users'}),
    ('trace2', 'span3', '', 'http_request', now() - INTERVAL 30 MINUTE, 200000000, 'api-gateway', {'method': 'POST', 'path': '/api/orders'});
