"""Signing vectors for the web app tests, produced by the backend's own functions.

Run from the backend folder, so the strings come from the code the server verifies with:

    cd backend && PYTHONPATH=. uv run --no-sync python ../web/tools/make_vectors.py > ../web/tests/vectors/signing.json

The keys are generated fresh on every run and exist only to prove that a DER signature made by
the server's library verifies in WebCrypto after conversion (and the reverse). They protect
nothing: no device, token or secret is derived from them.
"""

from __future__ import annotations

import base64
import json
import sys
from datetime import UTC, datetime, timedelta, timezone

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.schemas.common import iso_seconds
from app.security.crypto import action_message, approval_message, auth_message, verify_signature

IST = timezone(timedelta(hours=5, minutes=30))

TIMES = [
    datetime(2026, 11, 13, 6, 30, 0, tzinfo=UTC),
    datetime(2026, 11, 13, 12, 0, 5, 987654, tzinfo=IST),  # offset and fractional seconds
    datetime(2026, 12, 31, 23, 59, 59, tzinfo=UTC),
    datetime(2027, 1, 1, 5, 29, 59, 999999, tzinfo=IST),  # crosses the year in UTC
    datetime(2026, 3, 1, 0, 0, 0, tzinfo=UTC),
]


def stamp(value: datetime) -> str:
    return value.isoformat()


def main() -> int:
    private_key = ec.generate_private_key(ec.SECP256R1())
    public_point = private_key.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    public_b64 = base64.b64encode(public_point).decode("ascii")

    auth = [
        {"device_id": device_id, "nonce": nonce, "message": auth_message(device_id, nonce)}
        for device_id, nonce in [
            ("dev_01HZXK3V9Q", "n0nce-AbC_123"),
            ("dev_web_companion", "9f8e7d6c5b4a39281706f5e4d3c2b1a0"),
            ("dev_देवनागरी", "nonce with spaces"),
        ]
    ]
    approvals = [
        {
            "approval_id": approval_id,
            "action_digest": digest,
            "approved": approved,
            "signed_at": stamp(when),
            "message": approval_message(approval_id, digest, approved, when),
        }
        for approval_id, digest, approved, when in [
            ("apr_01HZXK3V9Q", "a" * 64, True, TIMES[0]),
            ("apr_01HZXK3V9Q", "a" * 64, False, TIMES[0]),
            ("apr_7c1d", "0123456789abcdef" * 4, True, TIMES[1]),
            ("apr_year_end", "f" * 64, False, TIMES[3]),
        ]
    ]
    actions = [
        {
            "action": action,
            "subject": subject,
            "signed_at": stamp(when),
            "message": action_message(action, subject, when),
        }
        for action, subject, when in [
            ("set_privacy_mode", "cloud_intelligence", TIMES[0]),
            ("set_kill_switch", "true", TIMES[1]),
            ("set_permission", "finance.read=false", TIMES[2]),
            ("revoke_device", "dev_01HZXK3V9Q", TIMES[4]),
        ]
    ]
    timestamps = [{"input": stamp(when), "iso_seconds": iso_seconds(when)} for when in TIMES]

    signed = []
    for message in (auth[0]["message"], approvals[0]["message"], "नमस्ते ZORO | ₹1,23,456.50"):
        der = private_key.sign(message.encode("utf-8"), ec.ECDSA(hashes.SHA256()))
        signature_b64 = base64.b64encode(der).decode("ascii")
        if not verify_signature(public_b64, message, signature_b64):
            print("the backend refused its own signature", file=sys.stderr)
            return 1
        signed.append({"message": message, "signature_der_b64": signature_b64})

    document = {
        "generated_by": "web/tools/make_vectors.py using backend/app/security/crypto.py",
        "auth": auth,
        "approval": approvals,
        "action": actions,
        "timestamps": timestamps,
        "python_signed": {"public_key_x963_b64": public_b64, "signatures": signed},
    }
    json.dump(document, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
