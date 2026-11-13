# Docker deployment

Status: **not run on the development machine** (no Docker installed). The files are written to the
Compose specification and checked only for YAML validity. Treat the first `docker compose up` on a
Docker host as the real test.

## Services (`docker-compose.yml` at the repo root)

| Service | Image | Host port (loopback only) | Volume |
|---|---|---|---|
| postgres | `pgvector/pgvector:pg17` | 127.0.0.1:5432 | `pgdata` |
| redis | `redis:7-alpine` | 127.0.0.1:6379 | `redisdata` |
| minio | `minio/minio` | 127.0.0.1:9000 (API), 9001 (console) | `miniodata` |
| backend | built from `backend/Dockerfile` (python 3.12 slim, uv, user `zoro`, uid 10001) | 127.0.0.1:8787 | `./config` read-only |

Every service has a health check; the backend waits for the other three to be healthy.
`infrastructure/database/init/01-extensions.sql` creates the `vector` extension on first start.

## Use

1. `scripts/install.sh` (creates `.env` with generated secrets) or copy `.env.example` to `.env` and fill
   `ZORO_SECRET_KEY`, `ZORO_DATA_KEY`, `ZORO_POSTGRES_PASSWORD`, `ZORO_MINIO_ACCESS_KEY`, `ZORO_MINIO_SECRET_KEY`.
   Compose refuses to start when the password or MinIO credentials are empty.
2. `docker compose up -d --build`
3. `scripts/healthcheck.sh` and `docker compose ps`.

The compose file overrides `ZORO_DATABASE_URL`, `ZORO_REDIS_URL`, `ZORO_OBJECT_STORE`, `ZORO_MINIO_ENDPOINT`
and `ZORO_CONFIG_DIR` for the backend container; everything else comes from `.env` via `env_file`.

## Notes and limits

- The backend schema is created by the backend itself (`python -m app.cli init-db`); the container does
  not run it automatically. Run `docker compose exec backend python -m app.cli init-db` once.
- Ports are loopback-bound. To reach the server from a phone, put a TLS reverse proxy in front; none ships here.
- The MinIO bucket named in `ZORO_MINIO_BUCKET` is not pre-created by compose.
- `minio/minio:latest` and `redis:7-alpine` are not pinned by digest; pin them for production.
