"""Encrypted storage for integration credentials (`integration_credentials`).

Values are sealed with AES-256-GCM under `ZORO_DATA_KEY`; the ciphertext is bound to its
``provider|account`` so it cannot be copied onto another row. Never store a UPI PIN, OTP, bank
password, CVV or broker password here or anywhere else.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import delete, select

from app.core.clock import Clock, SystemClock
from app.core.ids import new_id
from app.db.session import SessionFactory, affected_rows
from app.security.crypto import FieldCipher
from app.security.models import IntegrationCredential

__all__ = ["FieldCipher", "SecretStore"]


def _aad(provider: str, account: str) -> str:
    return f"{provider}|{account}"


class SecretStore:
    def __init__(
        self, session_factory: SessionFactory, cipher: FieldCipher, clock: Clock | None = None
    ) -> None:
        self._sf = session_factory
        self._cipher = cipher
        self._clock = clock or SystemClock()

    async def put(
        self, provider: str, value: str, *, account: str = "default", expires_at: datetime | None = None
    ) -> None:
        """Store or replace the credential for `provider` / `account`."""
        if not provider or not value:
            raise ValueError("provider and value are required")
        sealed = self._cipher.encrypt(value, aad=_aad(provider, account))
        now = self._clock.now()
        async with self._sf() as session:
            row = (
                await session.execute(
                    select(IntegrationCredential).where(
                        IntegrationCredential.provider == provider, IntegrationCredential.account == account
                    )
                )
            ).scalar_one_or_none()
            if row is None:
                session.add(
                    IntegrationCredential(
                        id=new_id("cred"),
                        provider=provider,
                        account=account,
                        ciphertext=sealed,
                        expires_at=expires_at,
                        created_at=now,
                        updated_at=now,
                    )
                )
            else:
                row.ciphertext = sealed
                row.expires_at = expires_at
                row.updated_at = now
            await session.commit()

    async def get(
        self, provider: str, *, account: str = "default", allow_expired: bool = False
    ) -> str | None:
        """The decrypted credential, or None when absent (or expired, unless `allow_expired`)."""
        async with self._sf() as session:
            row = (
                await session.execute(
                    select(IntegrationCredential).where(
                        IntegrationCredential.provider == provider, IntegrationCredential.account == account
                    )
                )
            ).scalar_one_or_none()
        if row is None:
            return None
        if not allow_expired and row.expires_at is not None and row.expires_at <= self._clock.now():
            return None
        return self._cipher.decrypt_str(row.ciphertext, aad=_aad(provider, account))

    async def expires_at(self, provider: str, *, account: str = "default") -> datetime | None:
        async with self._sf() as session:
            return (
                await session.execute(
                    select(IntegrationCredential.expires_at).where(
                        IntegrationCredential.provider == provider, IntegrationCredential.account == account
                    )
                )
            ).scalar_one_or_none()

    async def delete(self, provider: str, *, account: str | None = None) -> int:
        """Remove one account's credential, or every account of the provider. Returns rows removed."""
        stmt = delete(IntegrationCredential).where(IntegrationCredential.provider == provider)
        if account is not None:
            stmt = stmt.where(IntegrationCredential.account == account)
        async with self._sf() as session:
            result = await session.execute(stmt)
            await session.commit()
            return affected_rows(result)

    async def accounts(self, provider: str) -> list[str]:
        async with self._sf() as session:
            rows = await session.execute(
                select(IntegrationCredential.account)
                .where(IntegrationCredential.provider == provider)
                .order_by(IntegrationCredential.account)
            )
            return [str(account) for account in rows.scalars().all()]

    async def providers(self) -> list[str]:
        """Names only: this never returns secret values."""
        async with self._sf() as session:
            rows = await session.execute(select(IntegrationCredential.provider).distinct())
            return sorted(str(name) for name in rows.scalars().all())
