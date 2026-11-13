# Monitoring

What exists today, nothing more. There is no Prometheus, Grafana, alerting or tracing setup.

- **`GET /healthz`** on the backend (default `http://127.0.0.1:8787/healthz`). Provided by the backend
  kernel; its exact response body is defined there.
- **JSON logs.** The backend writes structured JSON log lines to stdout. Secrets and raw sensitive
  payloads are never logged (CLAUDE.md rule 5). Under Docker: `docker compose logs -f backend`.
- **`scripts/healthcheck.sh [base-url]`** calls `/healthz`, prints the body and exits 0 only on HTTP 200
  (2 when unreachable, 1 on any other status). Usable from cron or a launchd job.
- **Docker health checks** in `docker-compose.yml` for postgres, redis, minio and backend
  (`docker compose ps` shows state). Not run on the development machine.
- **Capability registry** reports which integrations are enabled or "needs credentials".
