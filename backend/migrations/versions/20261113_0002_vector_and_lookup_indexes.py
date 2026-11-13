"""Hand-written: pgvector HNSW indexes and indexes on expiry / time lookup columns.

Vector indexes are PostgreSQL only (cosine distance, matching `app.db.vector.vector_search`, which
orders by ``embedding <=> :query``). The time indexes serve the expiry sweeps (sessions,
challenges, pairing codes, memories, credentials) and time-ordered reads (audit log, transactions,
paper trades). They are named ``ixm_*``; migrations/env.py keeps autogenerate from proposing to drop
them, since they are not declared on the models.

Revision ID: 0002
Revises: 0001
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0002"
down_revision: str | Sequence[str] | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

VECTOR_INDEXES = (
    ("ixm_memory_records_embedding_hnsw", "memory_records"),
    ("ixm_document_chunks_embedding_hnsw", "document_chunks"),
)

TIME_INDEXES = (
    ("ixm_audit_log_ts", "audit_log", ["ts"]),
    ("ixm_device_sessions_expires_at", "device_sessions", ["expires_at"]),
    ("ixm_auth_challenges_expires_at", "auth_challenges", ["expires_at"]),
    ("ixm_pairing_codes_expires_at", "pairing_codes", ["expires_at"]),
    ("ixm_memory_records_expires_at", "memory_records", ["expires_at"]),
    ("ixm_integration_credentials_expires_at", "integration_credentials", ["expires_at"]),
    ("ixm_finance_transactions_txn_date", "finance_transactions", ["txn_date"]),
    ("ixm_inv_paper_trades_executed_at", "inv_paper_trades", ["executed_at"]),
    ("ixm_orchestrator_messages_created_at", "orchestrator_messages", ["created_at"]),
)


def upgrade() -> None:
    for name, table, columns in TIME_INDEXES:
        op.create_index(name, table, columns, unique=False)
    if op.get_bind().dialect.name == "postgresql":
        for name, table in VECTOR_INDEXES:
            op.execute(
                f"CREATE INDEX IF NOT EXISTS {name} ON {table} USING hnsw (embedding vector_cosine_ops)"
            )


def downgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for name, _table in VECTOR_INDEXES:
            op.execute(f"DROP INDEX IF EXISTS {name}")
    for name, table, _columns in reversed(TIME_INDEXES):
        op.drop_index(name, table_name=table)
