import os

DSN = os.environ.get("FOGOPS_DSN", "postgresql://postgres:postgres@localhost:5433/fogops")
DEFAULT_ACTOR_ID = os.environ.get("DEFAULT_ACTOR_ID", "1")
# default = local UI; add the server origin via CORS_ORIGINS when deploying
_DEFAULT_ORIGINS = "http://localhost:3000,http://127.0.0.1:3000"
CORS_ORIGINS = [o.strip() for o in os.environ.get("CORS_ORIGINS", _DEFAULT_ORIGINS).split(",") if o.strip()]
# search_path lets us use bare names (v_flight_watch) whichever schema the views live in
SEARCH_PATH = "fogops,hist,public"

# --- auth
AUTH_SECRET = os.environ.get("AUTH_SECRET", "dev-only-change-me")
TOKEN_TTL_SEC = int(os.environ.get("TOKEN_TTL_HOURS", "12")) * 3600
# initial password for every demo user that has no credential yet (change it in production)
DEMO_PASSWORD = os.environ.get("DEMO_PASSWORD", "FogOps@2026")

WORKER_ENABLED = os.environ.get("WORKER_ENABLED", "true").lower() == "true"

# --- Ask (Claude). Leave the key unset and only the predefined questions work.
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "").strip()
ASK_MODEL = os.environ.get("ASK_MODEL", "claude-opus-5-5")
