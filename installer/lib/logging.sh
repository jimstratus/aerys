# Logging helpers — sourced by install.sh and other lib/ modules.
# Colors only when stdout is a TTY.

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
  AERYS_COLOR_RED=$'\033[31m'
  AERYS_COLOR_GREEN=$'\033[32m'
  AERYS_COLOR_YELLOW=$'\033[33m'
  AERYS_COLOR_BLUE=$'\033[34m'
  AERYS_COLOR_BOLD=$'\033[1m'
  AERYS_COLOR_RESET=$'\033[0m'
else
  AERYS_COLOR_RED=""
  AERYS_COLOR_GREEN=""
  AERYS_COLOR_YELLOW=""
  AERYS_COLOR_BLUE=""
  AERYS_COLOR_BOLD=""
  AERYS_COLOR_RESET=""
fi

log_info()    { printf "%s→%s %s\n"  "$AERYS_COLOR_BLUE"   "$AERYS_COLOR_RESET" "$*"; }
log_success() { printf "%s✓%s %s\n"  "$AERYS_COLOR_GREEN"  "$AERYS_COLOR_RESET" "$*"; }
log_warn()    { printf "%s⚠%s %s\n"  "$AERYS_COLOR_YELLOW" "$AERYS_COLOR_RESET" "$*" >&2; }
log_error()   { printf "%s✗%s %s\n"  "$AERYS_COLOR_RED"    "$AERYS_COLOR_RESET" "$*" >&2; }
log_section() { printf "\n%s%s%s\n"  "$AERYS_COLOR_BOLD"   "$*" "$AERYS_COLOR_RESET"; }
