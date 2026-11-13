"""Voice errors (all become `ErrorBody` with a stable code)."""

from __future__ import annotations

from app.core.errors import BadRequest, Forbidden, RateLimited, Unavailable


class EgressBlocked(Forbidden):
    """Privacy policy forbids sending this to the external voice provider."""

    code = "egress_blocked"
    default_message = "Privacy settings do not allow this to go to an online voice service."


class RequiresCredentials(Unavailable):
    code = "requires_credentials"
    retryable = False
    default_message = "This voice service needs an API key on the server."


class VoiceProviderError(Unavailable):
    code = "voice_provider_error"
    default_message = "The voice service did not answer. Try again, or use the on-device voice."


class VoiceProviderAuth(Unavailable):
    code = "voice_provider_auth"
    retryable = False
    default_message = "The voice service rejected the server's key. Check the key and try again."


class VoiceRateLimited(RateLimited):
    code = "voice_rate_limited"
    default_message = "The voice service is rate limited. Try again shortly."


class NoVoiceEngine(Unavailable):
    code = "no_voice_engine"
    retryable = False
    default_message = "No online voice engine is available. ZORO will use the on-device voice."


class VoiceNotFound(BadRequest):
    code = "voice_not_found"
    default_message = "That voice is not configured."
