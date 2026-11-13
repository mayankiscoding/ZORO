"""Security settings changes. Each one needs a `SignedProof` made with the approval key of the
signed-in device, and each one is audited. Routers call this; no logic lives in them."""

from __future__ import annotations

from collections.abc import Callable
from typing import Protocol

from app.core.errors import ZoroError
from app.core.types import PrivacyMode
from app.schemas.common import SignedProof
from app.schemas.security import PermissionGrant, SecurityState
from app.security.audit import AuditLog
from app.security.devices import DeviceRegistry
from app.security.permissions import PermissionService
from app.security.policy import PolicyConfig
from app.security.privacy import PrivacyStateService
from app.security.proofs import ProofVerifier
from app.security.sessions import AuthedDevice
from app.security.state import KillSwitch

ACTION_SET_PRIVACY_MODE = "set_privacy_mode"
ACTION_SET_KILL_SWITCH = "set_kill_switch"
ACTION_SET_PERMISSION = "set_permission"
ACTION_REVOKE_DEVICE = "revoke_device"


class OnlineProbe(Protocol):
    def is_online(self, device_id: str) -> bool: ...


class SecurityAdmin:
    def __init__(
        self,
        *,
        devices: DeviceRegistry,
        proofs: ProofVerifier,
        permissions: PermissionService,
        privacy: PrivacyStateService,
        kill_switch: KillSwitch,
        audit: AuditLog,
        config: Callable[[], PolicyConfig],
        online: Callable[[], OnlineProbe] | None = None,
    ) -> None:
        self._devices = devices
        self._proofs = proofs
        self._permissions = permissions
        self._privacy = privacy
        self._kill_switch = kill_switch
        self._audit = audit
        self._config = config
        self._online = online

    async def _prove(self, caller: AuthedDevice, proof: SignedProof, action: str, subject: str) -> None:
        try:
            await self._proofs.verify(
                proof, action=action, subject=subject, require_key="approval",
                expected_device_id=caller.device_id,
            )  # fmt: skip
        except ZoroError as exc:
            await self._audit.append(
                actor=caller.device_id, action=f"security.{action}", decision="denied",
                detail=f"{exc.error_code} subject={subject}",
            )  # fmt: skip
            raise

    async def state(self, caller: AuthedDevice) -> SecurityState:
        config = self._config()
        probe = self._online() if self._online is not None else None
        devices = await self._devices.list()
        return SecurityState(
            privacy_mode=await self._privacy.stored_mode(),
            kill_switch=await self._kill_switch.is_on(),
            strict_allow_public_external=config.toggles.strict_allow_public_external,
            biometric_for_high_risk=config.toggles.biometric_for_high_risk,
            session_expires_at=caller.expires_at,
            permissions=await self._permissions.list(),
            devices=[
                d.to_info(online=probe.is_online(d.id) if probe is not None else False) for d in devices
            ],
        )

    async def set_privacy_mode(
        self, caller: AuthedDevice, mode: PrivacyMode, proof: SignedProof
    ) -> SecurityState:
        await self._prove(caller, proof, ACTION_SET_PRIVACY_MODE, mode.value)
        await self._privacy.set_mode(mode, actor=caller.device_id)
        await self._audit.append(
            actor=caller.device_id, action=f"security.{ACTION_SET_PRIVACY_MODE}", decision="approved",
            detail=f"mode={mode.value}",
        )  # fmt: skip
        return await self.state(caller)

    async def set_kill_switch(self, caller: AuthedDevice, enabled: bool, proof: SignedProof) -> bool:
        """Returns the new value. Turning it on ends every session, including the caller's."""
        await self._prove(caller, proof, ACTION_SET_KILL_SWITCH, "true" if enabled else "false")
        await self._kill_switch.set(enabled, actor=caller.device_id)
        await self._audit.append(
            actor=caller.device_id, action=f"security.{ACTION_SET_KILL_SWITCH}", decision="approved",
            detail=f"enabled={'true' if enabled else 'false'}",
        )  # fmt: skip
        return enabled

    async def set_permission(
        self, caller: AuthedDevice, key: str, granted: bool, proof: SignedProof
    ) -> PermissionGrant:
        subject = f"{key}={'true' if granted else 'false'}"
        await self._prove(caller, proof, ACTION_SET_PERMISSION, subject)
        grant = await self._permissions.set(key, granted, actor=caller.device_id)
        await self._audit.append(
            actor=caller.device_id, action=f"security.{ACTION_SET_PERMISSION}", decision="approved",
            detail=subject,
        )  # fmt: skip
        return grant

    async def revoke_device(self, caller: AuthedDevice, device_id: str, proof: SignedProof) -> None:
        await self._prove(caller, proof, ACTION_REVOKE_DEVICE, device_id)
        await self._devices.revoke(device_id)
        await self._audit.append(
            actor=caller.device_id, action=f"security.{ACTION_REVOKE_DEVICE}", decision="approved",
            detail=f"device={device_id}",
        )  # fmt: skip
