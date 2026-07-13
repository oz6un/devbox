# Vite dev-server host check: allow the tailnet hostname.
# FOOTGUN: Vite reads this env var as EXACTLY ONE host — a comma-separated
# list is treated as a single literal hostname and silently matches nothing.
set -gx __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS "devbox"
