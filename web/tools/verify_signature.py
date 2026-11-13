"""Check signatures made by the web app with the server's own verifier.

Reads JSON from stdin: ``[{"public_key_b64": ..., "message": ..., "signature_b64": ...}, ...]``
and prints a JSON list of booleans, one per item, from `app.security.crypto.verify_signature`.
Used by `web/tests/signing.test.mjs`:

    cd backend && PYTHONPATH=. uv run --no-sync python ../web/tools/verify_signature.py < items.json
"""

from __future__ import annotations

import json
import sys

from app.security.crypto import verify_signature


def main() -> int:
    items = json.load(sys.stdin)
    results = [
        verify_signature(item["public_key_b64"], item["message"], item["signature_b64"]) for item in items
    ]
    json.dump(results, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
