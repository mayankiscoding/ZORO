"""Operator commands: ``python -m app.cli <command>``.

- ``pairing-code``  create a one-time device pairing code (valid 10 minutes)
- ``init-db``       first run: migrate to head (adopts a database made by create_all, stamps head)
- ``migrate``       apply Alembic migrations (``--revision``, ``--downgrade REV``, ``--status``)
- ``capabilities``  print the capability registry as Markdown grouped by status
- ``openapi``       print the OpenAPI document of the full app as JSON
- ``verify-audit``  walk the audit hash chain and report the first broken record
- ``gen-keys``      print fresh ZORO_SECRET_KEY / ZORO_DATA_KEY values for your .env
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import secrets
import sys
from collections.abc import Sequence

from app.core.settings import Settings, get_settings
from app.db.discovery import import_models
from app.plugins import build_kernel


async def _pairing_code(settings: Settings) -> int:
    reg = build_kernel(settings)
    database = reg.service("database")
    try:
        if settings.create_schema_on_start:
            await database.init()
        else:
            import_models()
        issued = await reg.service("devices").create_pairing_code()
        await reg.service("audit").append(
            actor="system", action="device.pairing_code_created", decision="info"
        )
    finally:
        await database.dispose()
    print(f"Pairing code: {issued.code}")
    print(f"Server:       {settings.public_base_url}")
    print(f"Valid until:  {issued.expires_at.isoformat(timespec='seconds')} (10 minutes, single use)")
    return 0


def _init_db(settings: Settings) -> int:
    from app.db.migrate import init_database

    action, state = init_database(settings.database_url)
    print(f"Database {action}: {state.dialect}, revision {state.current} (head {state.head})")
    print(f"{len(state.app_tables)} application tables")
    for table in state.app_tables:
        print(f"  {table}")
    return 0


def _migrate(settings: Settings, revision: str, downgrade_to: str | None, status_only: bool) -> int:
    from app.db import migrate

    if status_only:
        state = migrate.schema_state(settings.database_url)
    elif downgrade_to is not None:
        state = migrate.downgrade(settings.database_url, downgrade_to)
    else:
        try:
            state = migrate.upgrade(settings.database_url, revision)
        except migrate.SchemaNotManaged as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 2
    print(f"{state.dialect}: revision {state.current or '(none)'}; head {state.head}")
    print(f"{len(state.app_tables)} of {len(state.tables)} tables are application tables")
    return 0


async def _verify_audit(settings: Settings) -> int:
    reg = build_kernel(settings)
    database = reg.service("database")
    try:
        import_models()
        status = await reg.service("audit").verify_chain()
    finally:
        await database.dispose()
    if status.ok:
        print(f"Audit chain intact: {status.records} records")
        return 0
    print(
        f"Audit chain BROKEN at record {status.broken_at} ({status.reason}) after {status.records} good records"
    )
    return 1


def _gen_keys() -> int:
    print(f"ZORO_SECRET_KEY={secrets.token_urlsafe(48)}")
    print(f"ZORO_DATA_KEY={base64.b64encode(secrets.token_bytes(32)).decode('ascii')}")
    print("# Keep these in your .env or secret manager. Losing ZORO_DATA_KEY makes stored", file=sys.stderr)
    print(
        "# integration credentials unreadable; changing ZORO_SECRET_KEY signs every device out.",
        file=sys.stderr,
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.cli", description="ZORO server operator commands")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("pairing-code", help="create a one-time device pairing code")
    commands.add_parser("init-db", help="first run: bring the database to the latest schema")
    migrate_cmd = commands.add_parser("migrate", help="apply database migrations")
    migrate_cmd.add_argument("--revision", default="head", help="target revision (default: head)")
    migrate_cmd.add_argument(
        "--downgrade", metavar="REV", default=None, help="downgrade to REV (e.g. -1, base)"
    )
    migrate_cmd.add_argument("--status", action="store_true", help="show the current revision only")
    commands.add_parser("capabilities", help="print the capability registry as Markdown")
    commands.add_parser("openapi", help="print the OpenAPI document as JSON")
    commands.add_parser("verify-audit", help="verify the audit log hash chain")
    commands.add_parser("gen-keys", help="print new secret and data keys")
    args = parser.parse_args(argv)

    if args.command == "gen-keys":
        return _gen_keys()
    settings = get_settings()
    if args.command == "pairing-code":
        return asyncio.run(_pairing_code(settings))
    if args.command == "init-db":
        return _init_db(settings)
    if args.command == "migrate":
        return _migrate(settings, args.revision, args.downgrade, args.status)
    if args.command == "capabilities":
        from app.core.docs import capability_markdown

        print(capability_markdown(settings), end="")
        return 0
    if args.command == "openapi":
        from app.core.docs import openapi_json

        print(openapi_json(settings))
        return 0
    return asyncio.run(_verify_audit(settings))


if __name__ == "__main__":
    raise SystemExit(main())
