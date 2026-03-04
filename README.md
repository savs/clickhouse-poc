# Travel Booking Observability Demo

A local observability demo built around a travel booking application. A React frontend, three Node.js microservices (hotel, flight, booking/GraphQL), and the full Grafana observability stack — all wired together with OpenTelemetry, shipping metrics, logs, and traces into ClickHouse and visualised in Grafana.

## Services

### Application

| Service | Port | Purpose |
|---------|------|---------|
| **frontend** | `8080` | React travel booking UI (Vite + nginx) |
| **booking-service** | `4000` | GraphQL API — orchestrates hotel + flight |
| **hotel-service** | `3001` | REST API — hotel inventory |
| **flight-service** | `3002` | REST API — flight inventory |

### Observability Infrastructure

| Service | Image | Purpose |
|---------|-------|---------|
| **ClickHouse** | `clickhouse/clickhouse-server` | Columnar storage for all telemetry |
| **OTel Collector** | `otel/opentelemetry-collector-contrib` | Receives OTLP, writes to ClickHouse |
| **Grafana Alloy** | `grafana/alloy` | Scrapes metrics, tails logs, forwards OTLP |
| **Grafana PDC** | `grafana/pdc-agent` | Tunnel from Grafana Cloud to local ClickHouse |
| **Grafana** | `grafana/grafana` | Dashboards and visualisation |

## Architecture

> Note: OTel Collector Contrib is required as an intermediary because the ClickHouse exporter [is not yet available in Alloy](https://github.com/grafana/alloy/issues/3492).

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │  Browser                                                             │
  │  travel-booking-frontend :8080                                       │
  │  React + OTel FetchInstrumentation                                   │
  │                                                                      │
  │  /graphql  ──────────────────────────────► booking-service :4000     │
  │  /v1/traces ─────────────────────────────► alloy :4318 (via nginx)   │
  └──────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────┐      ┌──────────────────────┐
  │  booking-service :4000  │─────►│  hotel-service :3001  │
  │  Apollo GraphQL         │      └──────────────────────┘
  │  OTel Node SDK          │      ┌──────────────────────┐
  │                         │─────►│  flight-service :3002 │
  └─────────────────────────┘      └──────────────────────┘
            │ OTLP HTTP                     │ OTLP HTTP
            ▼                               ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Grafana Alloy :4317/:4318                                           │
  │                                                                      │
  │  otelcol.receiver.otlp  ◄── all microservices + Grafana traces       │
  │  otelcol.receiver.prometheus ◄── prometheus.scrape (Alloy + CH)      │
  │  otelcol.receiver.loki  ◄── loki.source.docker (container logs)      │
  │                                                                      │
  │  otelcol.processor.batch                                             │
  │  otelcol.exporter.otlphttp                                           │
  └──────────────────────────────────┬──────────────────────────────────┘
                                     │ OTLP HTTP :4318
                                     ▼
                        ┌────────────────────────┐
                        │  OTel Collector Contrib  │
                        │  clickhouse exporter     │
                        └────────────┬───────────┘
                                     │ native TCP :9000
                                     ▼
                        ┌────────────────────────┐
                        │  ClickHouse             │
                        │  otel_metrics_*         │
                        │  otel_logs              │
                        │  otel_traces            │
                        └────────────┬───────────┘
                                     │
                    ┌────────────────┤
                    │                │
                    ▼                ▼
        ┌───────────────┐  ┌────────────────────────┐
        │  Grafana PDC  │  │  Grafana :3000          │
        │  (tunnel to   │  │  ClickHouse datasource  │
        │  Cloud)       │  │  Dashboards             │
        └───────────────┘  └────────────────────────┘
```

## Data Flow

| Signal | Source | Collected by | Destination |
|--------|--------|--------------|-------------|
| Traces | frontend (browser) | OTel FetchInstrumentation → nginx → Alloy | `otel_traces` |
| Traces | booking-service | OTel Node SDK → Alloy | `otel_traces` |
| Traces | hotel-service | OTel Node SDK → Alloy | `otel_traces` |
| Traces | flight-service | OTel Node SDK → Alloy | `otel_traces` |
| Traces | Grafana | OTLP gRPC → Alloy | `otel_traces` |
| Metrics | all Node.js services | OTel Node SDK → Alloy | `otel_metrics_*` |
| Metrics | Alloy (self) | `prometheus.scrape` | `otel_metrics_*` |
| Metrics | ClickHouse (self) | `prometheus.scrape` | `otel_metrics_*` |
| Logs | all app containers | `loki.source.docker` (Docker socket) | `otel_logs` |

All signals are written to ClickHouse using the OpenTelemetry schema (`otel_*` tables) with a 72-hour TTL.

## Quick Start

### Prerequisites

Create a `.env` file with your Grafana Cloud PDC credentials:

```
GCLOUD_PDC_SIGNING_TOKEN=<your-pdc-token>
GCLOUD_PDC_CLUSTER=<your-pdc-cluster>
GCLOUD_HOSTED_GRAFANA_ID=<your-grafana-id>
```

### Start the Stack

```bash
docker compose up --build -d
```

On first start, Grafana installs the ClickHouse plugin — allow ~30 seconds before the datasource is ready.

### Endpoints

| Service | URL | Notes |
|---------|-----|-------|
| Travel booking UI | http://localhost:8080 | React frontend |
| GraphQL playground | http://localhost:4000/graphql | booking-service |
| Hotel API | http://localhost:3001/hotels | `?location=Paris` |
| Flight API | http://localhost:3002/flights | `?from=London&to=Tokyo` |
| Grafana | http://localhost:3000 | admin / admin |
| Alloy UI | http://localhost:12345 | Pipeline status |
| ClickHouse HTTP | http://localhost:8123 | grafana / grafana |

### Try the App

1. Open http://localhost:8080
2. Select **From** and **To** cities and click **Search**
3. Click a hotel and/or flight card to select them
4. Click **Book Trip** — a booking reference is returned
5. Open Grafana and explore traces to see the distributed call chain:
   `frontend → booking-service → hotel-service / flight-service`

### Sample GraphQL Query

```graphql
query {
  hotels(location: "Paris") {
    id name pricePerNight rating available
  }
  flights(from: "London", to: "Paris") {
    id airline flightNumber departure arrival price available
  }
}
```

```bash
curl -X POST http://localhost:4000/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ hotels(location:\"Paris\") { name pricePerNight rating } }"}'
```

## Configuration Files

```
.
├── docker-compose.yml
├── alloy/
│   └── config.alloy               # Alloy pipeline (OTLP, scrape, Docker logs)
├── booking-service/
│   ├── server.js                  # Apollo GraphQL server
│   ├── tracing.js                 # OTel Node SDK setup
│   └── package.json
├── clickhouse/
│   └── init/
│       └── 01-init.sql            # Database initialisation
├── flight-service/
│   ├── server.js                  # Express REST API
│   ├── tracing.js                 # OTel Node SDK setup
│   └── package.json
├── frontend/
│   ├── src/
│   │   ├── App.jsx                # Travel booking UI
│   │   ├── main.jsx               # React entry point
│   │   └── tracing.js             # Browser OTel setup
│   ├── nginx.conf                 # Proxies /graphql and /v1/traces
│   └── vite.config.js
├── grafana/
│   ├── Dockerfile
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── datasources.yaml   # ClickHouse + Prometheus datasources
│   │   └── dashboards/
│   │       └── dashboards.yaml    # Dashboard provisioning config
│   └── dashboards/
│       ├── sample-dashboard.json
│       └── telemetry-dashboard.json
├── hotel-service/
│   ├── server.js                  # Express REST API
│   ├── tracing.js                 # OTel Node SDK setup
│   └── package.json
└── otelcol/
    └── config.yaml                # OTel Collector: OTLP receiver → ClickHouse exporter
```

## Sample Queries

Run these in Grafana Explore against the ClickHouse datasource.

**End-to-end trace for a booking:**
```sql
SELECT TraceId, SpanName, ServiceName, Duration / 1e6 AS duration_ms
FROM otel_traces
WHERE ServiceName IN ('travel-booking-frontend', 'booking-service', 'hotel-service', 'flight-service')
  AND Timestamp >= now() - INTERVAL 1 HOUR
ORDER BY Timestamp DESC
LIMIT 100
```

**Booking-service logs:**
```sql
SELECT Timestamp, SeverityText AS level, Body AS message
FROM otel_logs
WHERE ServiceName = 'booking-service'
  AND Timestamp >= now() - INTERVAL 1 HOUR
ORDER BY Timestamp DESC
LIMIT 100
```

**HTTP request metrics by service:**
```sql
SELECT TimeUnix AS timestamp, ServiceName AS service, MetricName AS metric, Value AS value
FROM otel_metrics_sum
WHERE MetricName LIKE 'http%'
  AND TimeUnix >= now() - INTERVAL 1 HOUR
ORDER BY timestamp DESC
LIMIT 100
```

**Alloy and ClickHouse infrastructure metrics:**
```sql
SELECT TimeUnix AS timestamp, MetricName AS metric, Value AS value
FROM otel_metrics_sum
WHERE MetricName LIKE '%cpu%'
  AND TimeUnix >= now() - INTERVAL 1 HOUR
ORDER BY timestamp DESC
LIMIT 100
```

## Managing the Stack

```bash
# View logs for a specific service
docker compose logs -f booking-service

# Rebuild and restart a single service after code changes
docker compose up --build -d hotel-service

# Stop without removing data
docker compose down

# Stop and wipe all volumes (fresh start)
docker compose down -v && docker compose up --build -d
```

## Troubleshooting

**Grafana plugin not installing**
The `grafana-clickhouse-datasource` plugin is installed at container startup via `GF_INSTALL_PLUGINS`. Allow ~30 seconds on first boot. Grafana uses Google DNS (`8.8.8.8`) to ensure the download succeeds inside Docker Desktop.

**No traces from the frontend**
The browser sends traces to `/v1/traces`, which nginx proxies to `alloy:4318` inside Docker. If the frontend container is not running, traces will fail silently. Check `docker compose logs frontend`.

**booking-service cannot reach hotel/flight services**
Services communicate over the `grafana-net` Docker network using container names as hostnames. Verify all three are running: `docker compose ps`.

**Alloy pipeline errors**
Open the Alloy UI at http://localhost:12345 — it shows the live status of every component, including scrape targets and export errors.

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
- The Docker socket mount on Alloy (`/var/run/docker.sock`) gives Alloy read access to all container metadata — scope appropriately in production
