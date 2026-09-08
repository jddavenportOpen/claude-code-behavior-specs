#!/usr/bin/env bash
# repro-003 — an out-of-enum settings value is silently discarded.
#
# Static probe. It reads printable strings out of the installed Claude Code
# binary and shows the two effort enums that exist in it:
#
#   * the PERSISTED settings schema, which does not include "max", and which
#     ends in .catch(void 0) — i.e. an unparseable value becomes undefined
#     rather than an error;
#   * a separate five-value enum that DOES include "max", used by the
#     session-scoped --effort flag.
#
# So `{"effortLevel": "max"}` in settings.json is accepted by the file, ignored
# by the parser, and reported nowhere: the session silently starts at the model
# default instead of at the tier the file names.
#
# COST / SAFETY
#   Zero. Read-only, offline, no model call, no config written.
#
# USAGE
#   ./repro-003-effort-enum-schema-probe.sh [path-to-claude-binary]
set -uo pipefail

BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  CLI="$(command -v claude || true)"
  # resolve a wrapper/symlink down to the real executable
  if [[ -n "$CLI" ]]; then
    BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLI" 2>/dev/null || echo "$CLI")"
  fi
fi
if [[ -z "$BIN" || ! -f "$BIN" ]]; then
  echo "usage: $0 /path/to/claude-code-binary" >&2
  echo "  (on a Homebrew npm install this is usually" >&2
  echo "   \$(brew --prefix)/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe)" >&2
  exit 2
fi

echo "repro-003   binary: $BIN"
echo

echo "── persisted settings.json schema for effortLevel"
strings -a "$BIN" 2>/dev/null \
  | grep -o 'effortLevel:[A-Za-z$_]*(\["low".\{0,170\}' \
  | grep -F '.catch' \
  | sed 's/\.describe("\([^"]*\)".*/.describe("\1")/' \
  | sort -u \
  || echo "  (pattern not found — the binary may be a different build/shape)"
echo

echo "── every effort-shaped enum present in the binary"
strings -a "$BIN" 2>/dev/null \
  | grep -o '\["low","medium","high"[^]]*\]' \
  | sort -u
echo

cat <<'NOTE'
WHAT TO LOOK FOR
  The persisted schema line ends in .catch(void 0): an out-of-enum value is
  coerced to undefined, not rejected. "max" appears only in the longer enum,
  which is the --effort flag's, not the settings file's.

  Consequence: a settings.json saying "max" is parsed as if the key were
  absent. There is no warning on stdout, on stderr, in /doctor, or in /status;
  the only way to notice is to observe that sessions behave at the default
  tier. (The Remote Control path DOES emit "apply_flag_settings: unrecognized
  effortLevel" for the same class of input — the string is in this binary too.
  The persisted-settings path emits nothing.)
NOTE
