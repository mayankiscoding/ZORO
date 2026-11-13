"""`/v1/devices/channel` (WebSocket), `GET /v1/devices` and the REST result fallback, end to end."""

from __future__ import annotations

from collections.abc import Iterator
from concurrent.futures import Future
from typing import Any

import pytest
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.core.clock import FixedClock
from app.core.settings import Settings
from app.core.types import DevicePlatform
from app.devices.hub import DeviceHub
from app.main import create_app
from app.plugins import PluginRegistry
from app.schemas.turns import DeviceActionResult
from tests.devices.conftest import NOW, make_request
from tests.fakes.devices import DeviceSigner


class Paired:
    def __init__(self, device_id: str, token: str) -> None:
        self.device_id = device_id
        self.token = token

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}


@pytest.fixture
def tc(settings: Settings) -> Iterator[TestClient]:
    app = create_app(settings, plugin_modules=("app.devices.plugin",), clock=FixedClock(NOW))
    with TestClient(app) as client:
        yield client


def _reg(tc: TestClient) -> PluginRegistry:
    reg: PluginRegistry = tc.app.state.registry  # type: ignore[attr-defined]
    return reg


def _pair(tc: TestClient, platform: DevicePlatform = DevicePlatform.IOS) -> Paired:
    reg = _reg(tc)

    async def run() -> Paired:
        signer = DeviceSigner(platform=platform, now=reg.service("clock").now)
        issued = await reg.service("devices").create_pairing_code()
        record = await reg.service("devices").pair(signer.pair_request(issued.code))
        signer.device_id = record.id
        challenge = await reg.service("sessions").create_challenge(record.id)
        token = await reg.service("sessions").issue_token(signer.sign_auth(challenge.nonce))
        return Paired(record.id, token.access_token)

    assert tc.portal is not None
    return tc.portal.call(run)


def _dispatch(tc: TestClient, device_id: str, action_id: str, timeout: float = 5) -> Future[Any]:
    hub: DeviceHub = _reg(tc).service("device_hub")
    request = make_request(action_id, device_id, NOW)
    assert tc.portal is not None
    return tc.portal.start_task_soon(hub.dispatch, device_id, request, timeout)


def _result(action_id: str) -> dict[str, Any]:
    return DeviceActionResult(
        action_id=action_id, ok=True, result={"timer_id": "t9"}, executed_at=NOW
    ).model_dump(mode="json")


def test_unauthenticated_channel_is_refused(tc: TestClient) -> None:
    attempts: list[dict[str, Any]] = [{}, {"headers": {"Authorization": "Bearer nonsense"}}]
    for kwargs in attempts:
        with (
            pytest.raises(WebSocketDisconnect) as refused,
            tc.websocket_connect("/v1/devices/channel", **kwargs),
        ):
            pass
        assert refused.value.code == 1008
    with pytest.raises(WebSocketDisconnect), tc.websocket_connect("/v1/devices/channel?token=bad"):
        pass


def test_hello_dispatch_result_over_socket(tc: TestClient) -> None:
    phone = _pair(tc)
    with tc.websocket_connect("/v1/devices/channel", headers=phone.headers) as ws:
        ws.send_json({"type": "hello", "capabilities": ["ios.timer.start"]})
        ws.send_json({"type": "ping"})
        listing = tc.get("/v1/devices", headers=phone.headers).json()["items"]
        assert listing[0]["device_id"] == phone.device_id and listing[0]["online"] is True
        assert listing[0]["capabilities"] == ["ios.timer.start"]

        pending = _dispatch(tc, phone.device_id, "act_ws")
        frame = ws.receive_json()
        assert frame["type"] == "device_action" and frame["action"]["tool"] == "ios.timer.start"
        ws.send_json({"type": "device_action_result", "result": _result("act_ws")})
        assert pending.result(timeout=5).result == {"timer_id": "t9"}

    listing = tc.get("/v1/devices", headers=phone.headers).json()["items"]
    assert listing[0]["online"] is False


def test_token_query_parameter_and_rest_fallback(tc: TestClient) -> None:
    phone = _pair(tc)
    with tc.websocket_connect(f"/v1/devices/channel?token={phone.token}") as ws:
        ws.send_json({"type": "hello", "capabilities": []})
        pending = _dispatch(tc, phone.device_id, "act_rest")
        assert ws.receive_json()["action"]["action_id"] == "act_rest"

    url = "/v1/devices/actions/act_rest/result"
    first = tc.post(url, json=_result("act_rest"), headers=phone.headers)
    assert first.status_code == 200 and first.json() == {"action_id": "act_rest", "status": "accepted"}
    assert pending.result(timeout=5).ok
    again = tc.post(url, json=_result("act_rest"), headers=phone.headers)
    assert again.json()["status"] == "duplicate"

    mismatch = tc.post(url, json=_result("act_other"), headers=phone.headers)
    assert mismatch.status_code == 400 and mismatch.json()["code"] == "action_id_mismatch"
    unknown = tc.post("/v1/devices/actions/act_none/result", json=_result("act_none"), headers=phone.headers)
    assert unknown.status_code == 404 and unknown.json()["code"] == "device_action_not_found"
    anonymous = tc.post(url, json=_result("act_rest"))
    assert anonymous.status_code == 401


def test_rest_result_from_another_device_is_forbidden(tc: TestClient) -> None:
    phone, mac = _pair(tc), _pair(tc, DevicePlatform.MACOS)
    with tc.websocket_connect("/v1/devices/channel", headers=phone.headers) as ws:
        pending = _dispatch(tc, phone.device_id, "act_x")
        ws.receive_json()
        wrong = tc.post("/v1/devices/actions/act_x/result", json=_result("act_x"), headers=mac.headers)
        assert wrong.status_code == 403 and wrong.json()["code"] == "wrong_device"
        ws.send_json({"type": "device_action_result", "result": _result("act_x")})
        assert pending.result(timeout=5).ok


def test_expired_result_over_rest_is_gone(tc: TestClient) -> None:
    phone = _pair(tc)
    with tc.websocket_connect("/v1/devices/channel", headers=phone.headers) as ws:
        pending = _dispatch(tc, phone.device_id, "act_late", timeout=0.05)
        ws.receive_json()
        with pytest.raises(Exception, match="no answer"):
            pending.result(timeout=5)
    late = tc.post("/v1/devices/actions/act_late/result", json=_result("act_late"), headers=phone.headers)
    assert late.status_code == 410 and late.json()["code"] == "device_action_expired"


def test_revoked_device_is_disconnected_at_next_frame(tc: TestClient) -> None:
    phone = _pair(tc)
    reg = _reg(tc)
    with tc.websocket_connect("/v1/devices/channel", headers=phone.headers) as ws:
        ws.send_json({"type": "ping"})
        assert tc.portal is not None
        tc.portal.call(reg.service("devices").revoke, phone.device_id)
        ws.send_json({"type": "ping"})
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_json()
        assert closed.value.code == 1008
    assert not reg.service("device_hub").is_online(phone.device_id)
