# Grafana Stack with Alloy, PDC, and ClickHouse

This Docker Compose project provides a complete observability stack with:
- **Grafana**: Visualization and dashboarding
- **Grafana Alloy**: Telemetry collector (OTLP receiver)
- **Grafana Private Datasource Connect (PDC)**: Secure datasource connectivity
- **ClickHouse**: High-performance columnar database

## Quick Start

### 1. Start the Stack

```bash
docker-compose up -d
```

### 2. Access the Services

- **Grafana**: http://localhost:3000
  - Username: `admin`
  - Password: `admin`
- **Alloy**: http://localhost:12345
- **ClickHouse**: http://localhost:8123
- **PDC**: http://localhost:8080

### 3. Send Sample Telemetry to Alloy

Send OTLP metrics via HTTP:
```bash
curl -X POST http://localhost:4318/v1/metrics \
  -H "Content-Type: application/json" \
  -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"demo-service"}}]},"scopeMetrics":[{"metrics":[{"name":"demo.metric","gauge":{"dataPoints":[{"asDouble":42.0}]}}]}]}]}'
```

### 4. Configure PDC Token

Before using PDC in production, update the PDC token:

1. Edit `docker-compose.yml` and set `PDC_TOKEN` environment variable
2. Edit `pdc/config.yaml` and set the `grafana.token` value
3. Restart the PDC container:
   ```bash
   docker-compose restart pdc
   ```

## Architecture

```
┌─────────────┐
│   Clients   │
│  (OTLP SDK) │
└──────┬──────┘
       │
       v
┌─────────────┐      ┌──────────────┐
│    Alloy    │─────>│  ClickHouse  │
│ (Collector) │      │  (Storage)   │
└─────────────┘      └──────┬───────┘
                            │
                            │
       ┌────────────────────┴────────┐
       │                             │
       v                             v
┌─────────────┐              ┌─────────────┐
│     PDC     │<─────────────│   Grafana   │
│  (Proxy)    │              │(Visualization)
└─────────────┘              └─────────────┘
```

## Data Flow

1. **Telemetry Collection**: Applications send OTLP data to Alloy (ports 4317/4318)
2. **Processing**: Alloy batches and processes the telemetry data
3. **Storage**: Data is exported to ClickHouse for storage
4. **Querying**: Grafana queries ClickHouse directly or via PDC
5. **Visualization**: Dashboards display metrics, logs, and traces

## Components

### Grafana Alloy
- Receives OTLP telemetry (gRPC: 4317, HTTP: 4318)
- Processes and batches data
- Exports to ClickHouse
- UI available at http://localhost:12345

### ClickHouse
- Stores metrics, logs, and traces
- Pre-populated with sample data
- Native protocol: port 9000
- HTTP interface: port 8123

### Grafana PDC
- Provides secure access to private datasources
- Enables Grafana Cloud to connect to on-prem ClickHouse
- Configured to proxy ClickHouse connections

### Grafana
- Pre-configured with ClickHouse datasource
- Sample dashboard included
- Anonymous access enabled (for demo only)

## Configuration Files

```
.
├── docker-compose.yml              # Main compose configuration
├── alloy/
│   └── config.alloy               # Alloy pipeline configuration
├── clickhouse/
│   └── init/
│       └── 01-init.sql            # Database initialization
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── datasources.yaml   # Datasource configuration
│   │   └── dashboards/
│   │       └── dashboards.yaml    # Dashboard provisioning
│   └── dashboards/
│       └── sample-dashboard.json  # Sample dashboard
└── pdc/
    └── config.yaml                # PDC configuration
```

## Managing the Stack

### View Logs
```bash
docker-compose logs -f [service_name]
```

### Stop the Stack
```bash
docker-compose down
```

### Stop and Remove Data
```bash
docker-compose down -v
```

### Restart a Service
```bash
docker-compose restart [service_name]
```

## Sample Queries

### ClickHouse (via Grafana)

**Metrics Query:**
```sql
SELECT timestamp, value
FROM metrics
WHERE metric_name = 'cpu_usage'
ORDER BY timestamp DESC
LIMIT 100
```

**Logs Query:**
```sql
SELECT timestamp, level, message, service
FROM logs
ORDER BY timestamp DESC
LIMIT 100
```

**Traces Query:**
```sql
SELECT
    trace_id,
    operation_name,
    duration_ns / 1000000 as duration_ms,
    service_name
FROM traces
ORDER BY start_time DESC
LIMIT 100
```

## Troubleshooting

### ClickHouse Connection Issues
```bash
# Test ClickHouse connectivity
docker-compose exec clickhouse clickhouse-client -u grafana --password grafana -q "SELECT 1"
```

### Alloy Configuration Check
```bash
# View Alloy logs
docker-compose logs alloy

# Check Alloy UI for component status
open http://localhost:12345
```

### PDC Connection Issues
```bash
# Check PDC logs
docker-compose logs pdc

# Verify PDC can reach ClickHouse
docker-compose exec pdc wget -O- http://clickhouse:8123
```

## Production Considerations

Before deploying to production:

1. **Security**:
   - Change default passwords in `docker-compose.yml`
   - Generate proper PDC tokens
   - Disable anonymous Grafana access
   - Enable TLS for all services

2. **Persistence**:
   - Configure external volumes for data persistence
   - Set up backup strategies for ClickHouse

3. **Monitoring**:
   - Configure Alloy self-monitoring
   - Set up health checks and alerts
   - Monitor resource usage

4. **Networking**:
   - Use proper network segmentation
   - Configure firewall rules
   - Set up reverse proxy with TLS

## License

This configuration is provided as-is for demonstration purposes.
