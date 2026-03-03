.PHONY: help up down logs restart clean test

help:
	@echo "Grafana Stack Management Commands:"
	@echo "  make up          - Start all services"
	@echo "  make down        - Stop all services"
	@echo "  make restart     - Restart all services"
	@echo "  make logs        - Tail logs from all services"
	@echo "  make clean       - Stop and remove all volumes (WARNING: deletes data)"
	@echo "  make test        - Send test OTLP data to Alloy"
	@echo "  make clickhouse  - Open ClickHouse client"
	@echo "  make status      - Show status of all services"

up:
	docker-compose up -d
	@echo "\n✅ Stack is starting up!"
	@echo "📊 Grafana: http://localhost:3000 (admin/admin)"
	@echo "🔍 Alloy: http://localhost:12345"
	@echo "🗄️  ClickHouse: http://localhost:8123"
	@echo "🔒 PDC: http://localhost:8080"

down:
	docker-compose down

restart:
	docker-compose restart

logs:
	docker-compose logs -f

clean:
	@echo "⚠️  WARNING: This will delete all data volumes!"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		docker-compose down -v; \
		echo "✅ All services and volumes removed"; \
	fi

test:
	@echo "Sending test OTLP metrics to Alloy..."
	curl -X POST http://localhost:4318/v1/metrics \
		-H "Content-Type: application/json" \
		-d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"demo-service"}}]},"scopeMetrics":[{"metrics":[{"name":"demo.metric","gauge":{"dataPoints":[{"asDouble":42.0,"timeUnixNano":"'$$(date +%s)000000000'"}]}}]}]}]}'
	@echo "\n✅ Test data sent!"

clickhouse:
	docker-compose exec clickhouse clickhouse-client -u grafana --password grafana

status:
	docker-compose ps
