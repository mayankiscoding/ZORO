"""Google integration: OAuth (authorization code + PKCE, installed-app style) and a Gmail REST client."""

from app.communications.google.gmail import GmailClient, GmailMessage
from app.communications.google.oauth import GoogleError, GoogleOAuth

__all__ = ["GmailClient", "GmailMessage", "GoogleError", "GoogleOAuth"]
