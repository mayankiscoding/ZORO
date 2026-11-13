"""Pairing, sessions and the security endpoints over HTTP."""

from __future__ import annotations

from datetime import timedelta

import httpx
import jwt
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import FixedClock
from app.core.types import DataClass, PrivacyMode
from app.plugins import PluginRegistry
from app.schemas.security import Capability
from app.security.devices import normalise_code
from app.security.models import AuthChallenge, PairingCode
from tests.conftest import PairDevice, PairedDevice
from tests.fakes.devices import DeviceSigner


async def _pair(client: httpx.AsyncClient, registry: PluginRegistry, signer: DeviceSigner) -> httpx.Response:
    issued = await registry.service("devices").create_pairing_code()
    return await client.post("/v1/auth/pair", json=signer.pair_request(issued.code).model_dump(mode="json"))


async def _login(client: httpx.AsyncClient, signer: DeviceSigner) -> httpx.Response:
    challenge = await client.post("/v1/auth/challenge", json={"device_id": signer.device_id})
    assert challenge.status_code == 200, challenge.text
    request = signer.sign_auth(challenge.json()["nonce"])
    return await client.post("/v1/auth/token", json=request.model_dump(mode="json"))


def _proof(device: PairedDevice, action: str, subject: str, **kwargs: object) -> dict[str, object]:
    return device.signer.sign_proof(action, subject, **kwargs).model_dump(mode="json")  # type: ignore[arg-type]


# ---------------------------------------------------------------- pairing


async def test_pair_then_sign_in(
    client: httpx.AsyncClient, registry: PluginRegistry, clock: FixedClock
) -> None:
    signer = DeviceSigner(now=clock.now)
    paired = await _pair(client, registry, signer)
    assert paired.status_code == 200, paired.text
    signer.device_id = paired.json()["device_id"]
    assert paired.json()["server_name"] == "ZORO"

    token = await _login(client, signer)
    assert token.status_code == 200, token.text
    body = token.json()
    assert body["token_type"] == "bearer" and body["expires_in"] == 900
    claims = jwt.decode(body["access_token"], options={"verify_signature": False})
    assert claims["sub"] == signer.device_id and claims["sid"].startswith("ses_")
    assert claims["exp"] - claims["iat"] == 900
    assert jwt.get_unverified_header(body["access_token"])["alg"] == "HS256"

    state = await client.get(
        "/v1/security/state", headers={"Authorization": f"Bearer {body['access_token']}"}
    )
    assert state.status_code == 200, state.text
    assert state.json()["privacy_mode"] == "strict_private"
    assert state.json()["kill_switch"] is False
    assert [d["device_id"] for d in state.json()["devices"]] == [signer.device_id]
    assert {p["key"] for p in state.json()["permissions"]} == {
        "cloud.sensitive",
        "cloud.financial",
        "cloud.health",
    }
    assert all(p["granted"] is False for p in state.json()["permissions"])


async def test_pairing_code_is_hashed_single_use_and_expires(
    client: httpx.AsyncClient, registry: PluginRegistry, db: AsyncSession, clock: FixedClock
) -> None:
    devices = registry.service("devices")
    issued = await devices.create_pairing_code()
    assert issued.expires_at == clock.now() + timedelta(minutes=10)
    stored = (await db.execute(select(PairingCode))).scalar_one()
    assert normalise_code(issued.code) not in stored.code_hash and len(stored.code_hash) == 64

    first = await client.post(
        "/v1/auth/pair", json=DeviceSigner().pair_request(issued.code.lower()).model_dump(mode="json")
    )
    assert first.status_code == 200  # case and dash insensitive
    again = await client.post(
        "/v1/auth/pair", json=DeviceSigner().pair_request(issued.code).model_dump(mode="json")
    )
    assert again.status_code == 400 and again.json()["code"] == "pairing_code_invalid"

    expired = await devices.create_pairing_code()
    clock.advance(601)
    late = await client.post(
        "/v1/auth/pair", json=DeviceSigner().pair_request(expired.code).model_dump(mode="json")
    )
    assert late.status_code == 400 and late.json()["code"] == "pairing_code_invalid"

    wrong = await client.post(
        "/v1/auth/pair", json=DeviceSigner().pair_request("AAAA-AAAA").model_dump(mode="json")
    )
    assert wrong.status_code == 400 and wrong.json()["code"] == "pairing_code_invalid"


async def test_pairing_rejects_bad_keys_without_burning_the_code(
    client: httpx.AsyncClient, registry: PluginRegistry
) -> None:
    issued = await registry.service("devices").create_pairing_code()
    signer = DeviceSigner()
    body = signer.pair_request(issued.code).model_dump(mode="json")
    bad_key = await client.post("/v1/auth/pair", json={**body, "auth_public_key_b64": "AAAA"})
    assert bad_key.status_code == 400 and bad_key.json()["code"] == "public_key_invalid"
    reused = await client.post(
        "/v1/auth/pair", json={**body, "approval_public_key_b64": body["auth_public_key_b64"]}
    )
    assert reused.status_code == 400 and reused.json()["code"] == "public_key_reused"
    missing = await client.post("/v1/auth/pair", json={"pairing_code": issued.code})
    assert missing.status_code == 422 and missing.json()["code"] == "validation_error"
    assert issued.code not in missing.text
    assert (await client.post("/v1/auth/pair", json=body)).status_code == 200


async def test_wrong_pairing_codes_are_throttled(client: httpx.AsyncClient, registry: PluginRegistry) -> None:
    body = DeviceSigner().pair_request("ZZZZ-ZZZZ").model_dump(mode="json")
    for _ in range(10):
        assert (await client.post("/v1/auth/pair", json=body)).json()["code"] == "pairing_code_invalid"
    blocked = await client.post("/v1/auth/pair", json=body)
    assert blocked.status_code == 429 and blocked.json()["code"] == "rate_limited"
    assert blocked.json()["retryable"] is True


# ---------------------------------------------------------------- sessions


async def test_bad_signature_and_challenge_reuse(
    client: httpx.AsyncClient, registry: PluginRegistry, paired_device: PairedDevice, db: AsyncSession
) -> None:
    signer = paired_device.signer
    challenge = (await client.post("/v1/auth/challenge", json={"device_id": signer.device_id})).json()
    stored = (await db.execute(select(AuthChallenge).where(AuthChallenge.used_at.is_(None)))).scalar_one()
    assert challenge["nonce"] != stored.nonce_hash  # only a keyed hash is stored

    wrong_key = signer.sign_auth(challenge["nonce"], key="approval")  # not the auth key
    bad = await client.post("/v1/auth/token", json=wrong_key.model_dump(mode="json"))
    assert bad.status_code == 401 and bad.json()["code"] == "invalid_signature"
    assert bad.headers["www-authenticate"] == "Bearer"

    # the challenge was consumed by the failed attempt: a correct signature cannot reuse it
    reuse = await client.post(
        "/v1/auth/token", json=signer.sign_auth(challenge["nonce"]).model_dump(mode="json")
    )
    assert reuse.status_code == 401 and reuse.json()["code"] == "challenge_invalid"

    stranger = DeviceSigner(device_id=signer.device_id)  # right id, different keys
    fresh = (await client.post("/v1/auth/challenge", json={"device_id": signer.device_id})).json()
    forged = await client.post(
        "/v1/auth/token", json=stranger.sign_auth(fresh["nonce"]).model_dump(mode="json")
    )
    assert forged.status_code == 401 and forged.json()["code"] == "invalid_signature"

    made_up = await client.post(
        "/v1/auth/token", json=signer.sign_auth("made-up-nonce").model_dump(mode="json")
    )
    assert made_up.status_code == 401 and made_up.json()["code"] == "challenge_invalid"
    unknown = await client.post("/v1/auth/challenge", json={"device_id": "dev_missing"})
    assert unknown.status_code == 404 and unknown.json()["code"] == "device_not_found"


async def test_challenge_and_token_expire(
    client: httpx.AsyncClient, paired_device: PairedDevice, clock: FixedClock
) -> None:
    signer = paired_device.signer
    challenge = (await client.post("/v1/auth/challenge", json={"device_id": signer.device_id})).json()
    clock.advance(121)
    late = await client.post(
        "/v1/auth/token", json=signer.sign_auth(challenge["nonce"]).model_dump(mode="json")
    )
    assert late.status_code == 401 and late.json()["code"] == "challenge_invalid"

    assert (await client.get("/v1/security/state", headers=paired_device.headers)).status_code == 200
    clock.advance(900)
    expired = await client.get("/v1/security/state", headers=paired_device.headers)
    assert expired.status_code == 401 and expired.json()["code"] == "token_invalid"
    assert (await _login(client, signer)).status_code == 200  # no refresh token: sign again


async def test_requests_without_a_valid_token_are_refused(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    for headers in (
        {},
        {"Authorization": "Basic abc"},
        {"Authorization": "Bearer"},
        {"Authorization": "Bearer x.y.z"},
    ):
        response = await client.get("/v1/security/state", headers=headers)
        assert response.status_code == 401, headers
        assert response.json()["code"] in {"unauthorized", "token_invalid"}
    claims = jwt.decode(paired_device.token, options={"verify_signature": False})
    forged = jwt.encode(claims, "another-secret-key-that-is-long-enough-000", algorithm="HS256")
    assert (
        await client.get("/v1/security/state", headers={"Authorization": f"Bearer {forged}"})
    ).status_code == 401
    unsigned = jwt.encode(claims, "", algorithm="none")
    assert (
        await client.get("/v1/security/state", headers={"Authorization": f"Bearer {unsigned}"})
    ).status_code == 401
    for path in ("/v1/capabilities", "/v1/approvals/pending", "/v1/security/audit"):
        assert (await client.get(path)).status_code == 401


async def test_revoked_device_loses_its_session_and_cannot_sign_in(
    client: httpx.AsyncClient, paired_device: PairedDevice, pair_device: PairDevice
) -> None:
    mac = await pair_device(name="Test Mac")
    assert (await client.get("/v1/security/state", headers=mac.headers)).status_code == 200

    # a proof signed by the other device, or with the auth key, cannot revoke
    for proof in (
        _proof(mac, "revoke_device", mac.device_id),
        _proof(paired_device, "revoke_device", mac.device_id, key="auth"),
        _proof(paired_device, "revoke_device", paired_device.device_id),  # wrong subject
    ):
        refused = await client.post(
            f"/v1/security/devices/{mac.device_id}/revoke",
            json={"proof": proof},
            headers=paired_device.headers,
        )
        assert refused.status_code == 403 and refused.json()["code"] == "proof_invalid"

    revoked = await client.post(
        f"/v1/security/devices/{mac.device_id}/revoke",
        json={"proof": _proof(paired_device, "revoke_device", mac.device_id)},
        headers=paired_device.headers,
    )
    assert revoked.status_code == 204

    dead = await client.get("/v1/security/state", headers=mac.headers)  # immediately
    assert dead.status_code == 401 and dead.json()["code"] == "token_invalid"
    challenge = await client.post("/v1/auth/challenge", json={"device_id": mac.device_id})
    assert challenge.status_code == 403 and challenge.json()["code"] == "device_revoked"
    token = await client.post("/v1/auth/token", json=mac.signer.sign_auth("x").model_dump(mode="json"))
    assert token.status_code == 403 and token.json()["code"] == "device_revoked"

    state = (await client.get("/v1/security/state", headers=paired_device.headers)).json()
    assert {d["device_id"]: d["revoked"] for d in state["devices"]} == {
        paired_device.device_id: False,
        mac.device_id: True,
    }
    missing = await client.post(
        "/v1/security/devices/dev_missing/revoke",
        json={"proof": _proof(paired_device, "revoke_device", "dev_missing")},
        headers=paired_device.headers,
    )
    assert missing.status_code == 404 and missing.json()["code"] == "device_not_found"


# ---------------------------------------------------------------- signed settings changes


async def test_privacy_mode_needs_a_fresh_single_use_proof(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry, clock: FixedClock
) -> None:
    url = "/v1/security/privacy-mode"
    privacy = registry.service("privacy_state")

    stale = _proof(
        paired_device,
        "set_privacy_mode",
        "cloud_intelligence",
        signed_at=clock.now() - timedelta(seconds=121),
    )
    response = await client.put(
        url, json={"mode": "cloud_intelligence", "proof": stale}, headers=paired_device.headers
    )
    assert response.status_code == 403 and response.json()["code"] == "proof_stale"
    future = _proof(
        paired_device,
        "set_privacy_mode",
        "cloud_intelligence",
        signed_at=clock.now() + timedelta(seconds=121),
    )
    response = await client.put(
        url, json={"mode": "cloud_intelligence", "proof": future}, headers=paired_device.headers
    )
    assert response.json()["code"] == "proof_stale"

    # a proof for another mode or another action does not authorise this change
    for proof in (
        _proof(paired_device, "set_privacy_mode", "strict_private"),
        _proof(paired_device, "set_kill_switch", "cloud_intelligence"),
    ):
        response = await client.put(
            url, json={"mode": "cloud_intelligence", "proof": proof}, headers=paired_device.headers
        )
        assert response.status_code == 403 and response.json()["code"] == "proof_invalid"
    assert (await privacy.get_mode()).value == "strict_private"

    proof = _proof(
        paired_device,
        "set_privacy_mode",
        "cloud_intelligence",
        signed_at=clock.now() - timedelta(seconds=100),
    )
    ok = await client.put(
        url, json={"mode": "cloud_intelligence", "proof": proof}, headers=paired_device.headers
    )
    assert ok.status_code == 200, ok.text
    assert ok.json()["privacy_mode"] == "cloud_intelligence"
    assert (await privacy.get_mode()).value == "cloud_intelligence"

    replay = await client.put(
        url, json={"mode": "cloud_intelligence", "proof": proof}, headers=paired_device.headers
    )
    assert replay.status_code == 409 and replay.json()["code"] == "proof_replayed"

    audit = (await client.get("/v1/security/audit", headers=paired_device.headers)).json()["items"]
    actions = [(item["action"], item["decision"]) for item in audit]
    assert ("security.set_privacy_mode", "approved") in actions
    assert ("security.set_privacy_mode", "denied") in actions


async def test_permissions_and_egress_overrides(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    privacy = registry.service("privacy_state")
    assert await privacy.egress_overrides() == (False, frozenset())

    granted = await client.put(
        "/v1/security/permissions/cloud.financial",
        json={"granted": True, "proof": _proof(paired_device, "set_permission", "cloud.financial=true")},
        headers=paired_device.headers,
    )
    assert granted.status_code == 200, granted.text
    assert granted.json()["key"] == "cloud.financial" and granted.json()["granted"] is True
    strict_public, extra = await privacy.egress_overrides()
    assert strict_public is False
    assert {c.value for c in extra} == {"financial"}

    # the signed subject states the value: a "grant" proof cannot be used for another key or value
    crossed = await client.put(
        "/v1/security/permissions/cloud.health",
        json={"granted": True, "proof": _proof(paired_device, "set_permission", "cloud.financial=true")},
        headers=paired_device.headers,
    )
    assert crossed.status_code == 403
    unknown = await client.put(
        "/v1/security/permissions/ghost.key",
        json={"granted": True, "proof": _proof(paired_device, "set_permission", "ghost.key=true")},
        headers=paired_device.headers,
    )
    assert unknown.status_code == 404 and unknown.json()["code"] == "permission_unknown"

    withdrawn = await client.put(
        "/v1/security/permissions/cloud.financial",
        json={"granted": False, "proof": _proof(paired_device, "set_permission", "cloud.financial=false")},
        headers=paired_device.headers,
    )
    assert withdrawn.json()["granted"] is False
    assert await privacy.egress_overrides() == (False, frozenset())


async def test_kill_switch_stops_everything_but_auth_and_security(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    registry.add_capability(
        Capability(id="test.cap", title="Test", domain="test", status="working_local")  # type: ignore[arg-type]
    )
    listed = await client.get("/v1/capabilities", headers=paired_device.headers)
    assert listed.status_code == 200 and [c["id"] for c in listed.json()["items"]] == ["test.cap"]
    assert (await client.get("/v1/approvals/pending", headers=paired_device.headers)).json() == {
        "items": [],
        "next_cursor": None,
    }

    on = await client.post(
        "/v1/security/kill-switch",
        json={"enabled": True, "proof": _proof(paired_device, "set_kill_switch", "true")},
        headers=paired_device.headers,
    )
    assert on.status_code == 200 and on.json() == {"kill_switch": True}

    # external inference is cut off through the privacy state the gateway reads
    await registry.service("privacy_state").set_mode(PrivacyMode.CLOUD_INTELLIGENCE)
    await registry.service("permissions").set("cloud.health", True)
    assert await registry.service("privacy_state").get_mode() is PrivacyMode.STRICT_PRIVATE
    assert await registry.service("privacy_state").stored_mode() is PrivacyMode.CLOUD_INTELLIGENCE
    assert await registry.service("privacy_state").egress_overrides() == (False, frozenset())
    # every session ended at once
    assert (await client.get("/v1/security/state", headers=paired_device.headers)).status_code == 401
    # auth still answers, so the owner can come back
    token = (await _login(client, paired_device.signer)).json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}
    assert (await client.get("/v1/security/state", headers=headers)).json()["kill_switch"] is True
    assert (await client.get("/healthz")).status_code == 200
    # everything else is closed
    for path in ("/v1/capabilities", "/v1/approvals/pending"):
        closed = await client.get(path, headers=headers)
        assert closed.status_code == 503 and closed.json()["code"] == "kill_switch_active"

    off = await client.post(
        "/v1/security/kill-switch",
        json={
            "enabled": False,
            "proof": paired_device.signer.sign_proof("set_kill_switch", "false").model_dump(mode="json"),
        },
        headers=headers,
    )
    assert off.status_code == 200 and off.json() == {"kill_switch": False}
    assert await registry.service("privacy_state").get_mode() is PrivacyMode.CLOUD_INTELLIGENCE
    assert await registry.service("privacy_state").egress_overrides() == (
        False,
        frozenset({DataClass.HEALTH}),
    )
    assert (await client.get("/v1/capabilities", headers=headers)).status_code == 200


async def test_healthz_and_error_shapes(client: httpx.AsyncClient) -> None:
    health = await client.get("/healthz")
    assert health.status_code == 200
    assert health.json()["status"] == "ok" and health.json()["database"] == "ok"
    missing = await client.get("/v1/nope")
    assert missing.status_code == 404
    assert missing.json() == {"code": "not_found", "message": "Not Found", "retryable": False, "detail": None}
    wrong_method = await client.delete("/v1/auth/pair")
    assert wrong_method.status_code == 405 and wrong_method.json()["code"] == "method_not_allowed"
