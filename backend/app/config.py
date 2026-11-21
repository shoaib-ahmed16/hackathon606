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
ASK_MODEL = os.environ.get("ASK_MODEL", "claude-haiku-5-5")  # cheapest/fastest; override with ASK_MODEL for harder questions
# --- token / cost guards for free-text questions (predefined questions never call the API)
ASK_MAX_TOKENS = int(os.environ.get("ASK_MAX_TOKENS", "400"))            # cap on the reply length
ASK_MAX_QUESTION_CHARS = int(os.environ.get("ASK_MAX_QUESTION_CHARS", "300"))
ASK_FLIGHTS_IN_PROMPT = int(os.environ.get("ASK_FLIGHTS_IN_PROMPT", "40"))  # flights sent as context
ASK_CACHE_TTL_SEC = int(os.environ.get("ASK_CACHE_TTL_SEC", "300"))      # identical question + identical data = no API call
ASK_RATE_PER_MIN = int(os.environ.get("ASK_RATE_PER_MIN", "6"))          # AI calls per user per minute
ASK_DAILY_LIMIT = int(os.environ.get("ASK_DAILY_LIMIT", "150"))          # AI calls per day, whole server
