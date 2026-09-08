#!/usr/bin/env bash
# repro-002 — a transport/credential failure is delivered on the same channel,
# and in the same field, as a model answer.
#
# WHAT IT DOES
#   Runs `claude -p` three times against a THROWAWAY, EMPTY config directory
#   (HOME and CLAUDE_CONFIG_DIR both point at a fresh mktemp dir), so it can
#   never read, write, refresh or invalidate a real credential, and never
#   touches a live session. Each run asks a trivial question that the model
#   would answer with one word.
#
#     1. no credential at all      -> "not logged in" class
#     2. a syntactically-valid but bogus OAuth token -> "auth failed" class
#     3. no credential, --output-format json  -> shows the JSON envelope
#
#   For each it prints the exit code, and which stream the message came out on.
#
# COST
#   Zero tokens. Every call fails before reaching the model.
#
# SAFETY
#   The temp dir is removed on every exit path. Nothing is written to the real
#   ~/.claude. The bogus token is not a real credential and is rejected server
#   side. No live session, pane, or daemon is contacted.
#
# USAGE
#   ./repro-002-transport-failure-on-stdout.sh [path-to-claude]
set -uo pipefail

CLAUDE_BIN="${1:-$(command -v claude || true)}"
if [[ -z "$CLAUDE_BIN" || ! -x "$CLAUDE_BIN" ]]; then
  echo "usage: $0 /path/to/claude    (could not find one on PATH)" >&2
  exit 2
fi

echo "repro-002   binary: $CLAUDE_BIN"
"$CLAUDE_BIN" --version 2>/dev/null || true
echo

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/repro002.XXXXXX")"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

probe() {
  local label="$1"; shift
  local token="$1"; shift
  local d; d="$(mktemp -d "$TMPD/run.XXXXXX")"
  local out err rc
  out="$(env -i HOME="$d" PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
          CLAUDE_CONFIG_DIR="$d" \
          ${token:+CLAUDE_CODE_OAUTH_TOKEN="$token"} \
          timeout 90 "$CLAUDE_BIN" -p 'Reply with only the word OK' "$@" \
          </dev/null 2>"$d/stderr")"
  rc=$?
  err="$(cat "$d/stderr" 2>/dev/null)"
  echo "── $label"
  echo "   exit code : $rc"
  echo "   stdout    : ${out:-<empty>}"
  if [[ -n "$err" ]]; then
    echo "   stderr    : $(printf '%s' "$err" | head -c 200)"
  else
    echo "   stderr    : <empty>"
  fi
  echo
}

probe "1. no credential (text mode)"          ""
probe "2. bogus OAuth token (text mode)"      "sk-ant-oat01-REPRO002-INVALID-TOKEN-NOT-A-SECRET"
probe "3. no credential (--output-format json)" "" --output-format json

cat <<'NOTE'
WHAT TO LOOK FOR
  * In text mode the failure prose arrives on STDOUT — the same stream, with no
    prefix, marker or structure, that a model answer arrives on. A caller doing
    capture_output and reading stdout gets human prose where an answer belongs.
    stderr is empty or carries unrelated warnings.
  * In JSON mode the envelope sets  "is_error": true  and
    "terminal_reason": "api_error"  -- but ALSO  "subtype": "success" , and it
    puts the failure prose in  "result" , the very field that carries the
    model's answer on a good run. A caller that reads .result (the documented
    way to get the answer) still gets the notice as the answer.
  * Compare the exit codes across the three. Whether a given failure class exits
    non-zero has changed between CLI versions; the CHANNEL has not.
NOTE
