# Grafana Stack with Alloy, OTel Collector, PDC, and ClickHouse

A local observability demo stack that collects metrics, logs, and traces from the services themselves and stores everything in ClickHouse, visualised in Grafana.

## Components

| Service | Image | Purpose |
|---------|-------|---------|
| **ClickHouse** | `clickhouse/clickhouse-server` | Columnar storage for all telemetry |
| **OTel Collector** | `otel/opentelemetry-collector-contrib` | Receives OTLP, writes to ClickHouse |
| **Grafana Alloy** | `grafana/alloy` | Scrapes metrics, tails logs, forwards OTLP |
| **Grafana PDC** | `grafana/pdc-agent` | Tunnel from Grafana Cloud to local ClickHouse |
| **Grafana** | `grafana/grafana` | Dashboards and visualisation |

## Architecture

Note OTEL collector is used because the OTEL/contrib [Clickhouse exporter is not yet in Alloy](https://github.com/grafana/alloy/issues/3492).
```
                        ┌─────────────────────────────────────────────────────────┐
                        │  Grafana Alloy                                           │
  External apps         │                                                          │
  ─── OTLP ──►  ────────┼──► otelcol.receiver.otlp                                │
                        │         │                                                │
  Grafana traces        │         │                                                │
  ─── gRPC ──►  ────────┼─────────┘                                                │
                        │         │                                                │
  Prometheus scrape     │         │        ┌── prometheus.scrape ──► Alloy :12345  │
  (pull)         ◄──────┼─────────┼────────┤                                       │
                        │         │        └── prometheus.scrape ──► ClickHouse :8123
                        │         │        otelcol.receiver.prometheus             │
                        │         │                  │                             │
  Grafana container     │         │                  │                             │
  logs (Docker socket)  │  loki.source.docker        │                             │
  ──────────────────────┼──► otelcol.receiver.loki   │                             │
                        │         │                  │                             │
                        │         └──────────────────┘                             │
                        │                  │                                       │
                        │      otelcol.processor.batch                             │
                        │                  │                                       │
                        │      otelcol.exporter.otlphttp                           │
                        └──────────────────┼──────────────────────────────────────┘
                                           │ OTLP HTTP :4318
                                           ▼
                              ┌────────────────────────┐
                              │  OTel Collector Contrib │
                              │  (otelcol)              │
                              │  clickhouse exporter    │
                              └────────────┬───────────┘
                                           │ native TCP :9000
                                           ▼
                              ┌────────────────────────┐
                              │  ClickHouse            │
                              │  otel_metrics_*        │
                              │  otel_logs             │
                              │  otel_traces           │
                              └────────────┬───────────┘
                                           │
                       ┌───────────────────┤
                       │                   │
                       ▼                   ▼
           ┌───────────────┐   ┌───────────────────────┐
           │  Grafana PDC  │   │  Grafana              │
           │  (tunnel to   │   │  ClickHouse datasource│
           │  Cloud)       │   │  Dashboards           │
           └───────────────┘   └───────────────────────┘
```

## Data Flow

| Signal | Source | Collected by | Destination |
|--------|--------|--------------|-------------|
| Metrics | Alloy (self) | `prometheus.scrape` | `otel_metrics_*` |
| Metrics | ClickHouse (self) | `prometheus.scrape` | `otel_metrics_*` |
| Logs | Grafana container | `loki.source.docker` (Docker socket) | `otel_logs` |
| Traces | Grafana (instrumented) | OTLP gRPC → Alloy | `otel_traces` |
| All signals | External apps | OTLP gRPC/HTTP → OTel Collector | all tables |

All signals are written to ClickHouse using the OpenTelemetry schema (`otel_*` tables) and have a 72-hour TTL.

## Quick Start

### Prerequisites

Create a `.env` file with your Grafana Cloud credentials:

```
GCLOUD_PDC_SIGNING_TOKEN=<your-pdc-token>
GCLOUD_PDC_CLUSTER=<your-pdc-cluster>
GCLOUD_HOSTED_GRAFANA_ID=<your-grafana-id>
```

### Start the Stack

```bash
docker compose up -d
```

On first start, Grafana will install the ClickHouse plugin — allow ~30 seconds for it to become ready.

### Access the Services

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://localhost:3000 | admin / admin |
| Alloy UI | http://localhost:12345 | — |
| ClickHouse HTTP | http://localhost:8123 | grafana / grafana |

### Send Telemetry

OTLP is accepted directly by the OTel Collector on the standard ports:

```bash
# Metrics via OTLP HTTP
curl -X POST http://localhost:4318/v1/metrics \
  -H "Content-Type: application/json" \
  -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"demo-service"}}]},"scopeMetrics":[{"metrics":[{"name":"demo.requests","sum":{"dataPoints":[{"asInt":"100","startTimeUnixNano":"0","timeUnixNano":"0"}],"isMonotonic":true}}]}]}]}'

# Logs via OTLP HTTP
curl -X POST http://localhost:4318/v1/logs \
  -H "Content-Type: application/json" \
  -d '{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"demo-service"}}]},"scopeLogs":[{"logRecords":[{"timeUnixNano":"0","severityText":"INFO","body":{"stringValue":"hello from demo-service"}}]}]}]}'
```

Or via gRPC on `localhost:4317` using any OTLP-compatible SDK.

## Configuration Files

```
.
├── docker-compose.yml
├── alloy/
│   └── config.alloy               # Alloy pipeline (scrape, log collection, OTLP forwarding)
├── clickhouse/
│   └── init/
│       └── 01-init.sql            # Database initialisation
├── grafana/
│   ├── Dockerfile                 # Extends grafana/grafana:latest
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── datasources.yaml   # ClickHouse + Prometheus datasources
│   │   └── dashboards/
│   │       └── dashboards.yaml    # Dashboard provisioning config
│   └── dashboards/
│       ├── sample-dashboard.json  # CPU / memory / logs / traces panels
│       └── telemetry-dashboard.json
└── otelcol/
    └── config.yaml                # OTel Collector: OTLP receiver → ClickHouse exporter
```

## Sample Queries

All telemetry is stored in OpenTelemetry schema tables. Run these in the Grafana Explore view against the ClickHouse datasource.

**Metrics — Alloy or ClickHouse process CPU:**
```sql
SELECT TimeUnix AS timestamp, MetricName AS metric, Value AS value
FROM otel_metrics_sum
WHERE MetricName LIKE '%cpu%'
  AND TimeUnix >= now() - INTERVAL 1 HOUR
ORDER BY timestamp DESC
LIMIT 100
```

**Logs — Grafana container:**
```sql
SELECT Timestamp, SeverityText AS level, Body AS message, ServiceName AS service
FROM otel_logs
WHERE Timestamp >= now() - INTERVAL 1 HOUR
ORDER BY Timestamp DESC
LIMIT 100
```

**Traces — recent Grafana spans:**
```sql
SELECT TraceId, SpanName, ServiceName, Duration / 1e6 AS duration_ms
FROM otel_traces
WHERE ServiceName = 'grafana'
  AND Timestamp >= now() - INTERVAL 1 HOUR
ORDER BY Timestamp DESC
LIMIT 100
```

## Managing the Stack

```bash
# View logs for a specific service
docker compose logs -f alloy

# Restart a service
docker compose restart alloy

# Stop without removing data
docker compose down

# Stop and wipe all volumes (fresh start)
docker compose down -v && docker compose up -d
```

## Troubleshooting

**Grafana plugin not installing**
The `grafana-clickhouse-datasource` plugin is installed at container startup. If Grafana starts before it finishes, wait 30 seconds and reload. Grafana uses Google DNS (`8.8.8.8`) to ensure the download succeeds.

**Alloy pipeline errors**
Open the Alloy UI at http://localhost:12345 — it shows the live status of every component, including any errors in the scrape, log, or export pipeline.

**OTel Collector not writing to ClickHouse**
```bash
docker compose logs otelcol
```
The collector retries on failure (initial 5s, max 30s, up to 5 min). It auto-creates the `otel_*` tables on first successful write.

**ClickHouse connection test**
```bash
docker compose exec clickhouse clickhouse-client -u grafana --password grafana -q "SHOW TABLES"
```

**PDC not connecting**
```bash
docker compose logs pdc
```
Verify `GCLOUD_PDC_SIGNING_TOKEN`, `GCLOUD_PDC_CLUSTER`, and `GCLOUD_HOSTED_GRAFANA_ID` are set correctly in `.env`.

## Production Considerations

- Change default passwords (`grafana`/`grafana`, `admin`/`admin`) before any non-local deployment
- The ClickHouse exporter TTL is set to 72 hours — adjust `ttl` in `otelcol/config.yaml` as needed
- Disable `GF_AUTH_ANONYMOUS_ENABLED` and `GF_AUTH_ANONYMOUS_ORG_ROLE` in `docker-compose.yml`
- The Docker socket mount on Alloy (`/var/run/docker.sock`) gives Alloy read access to all container metadata — scope this appropriately in production
