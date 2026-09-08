# Reproductions

Three scripts, one per spec. All are safe to run on a working machine: none
writes to your real Claude Code configuration, none contacts a live session, and
none costs tokens.

| script | for | needs | cost | runtime |
|---|---|---|---|---|
| `repro-001-orphaned-grandchild.py` | [SPEC-001](../SPEC-001-headless-invocation-must-not-orphan-mcp-children.md) | python3 only | none | ~6 s |
| `repro-002-transport-failure-on-stdout.sh` | [SPEC-002](../SPEC-002-transport-failures-must-be-distinguishable-from-model-output.md) | a `claude` binary | none — every call fails before the model | ~10 s |
| `repro-003-effort-enum-schema-probe.sh` | [SPEC-003](../SPEC-003-out-of-enum-settings-values-must-not-be-silently-discarded.md) | a `claude` binary, `strings` | none | ~2 s |

```bash
python3 repro-001-orphaned-grandchild.py
./repro-002-transport-failure-on-stdout.sh "$(command -v claude)"
./repro-003-effort-enum-schema-probe.sh
```

## Safety design

**repro-001 deliberately creates the very leak the spec is about**, so its
cleanup guarantee is the load-bearing part:

- Every process it spawns carries a **unique marker** in its `argv` — this
  process's PID plus a random token — so the sweep can never match a process it
  did not create.
- A `finally:` block sweeps and `SIGKILL`s anything still carrying that marker,
  on every exit path including `KeyboardInterrupt`. It sweeps after each phase
  and again at the end.
- The stand-in processes `sleep 60`, not indefinitely, so even a total failure of
  the sweep self-limits to one minute.
- It uses `sleep` rather than a real MCP server: no Claude Code install,
  credential, or network is involved, and the leak it demonstrates is a property
  of POSIX process semantics, not of any particular child program.
- **Do not add `exec` to the shell snippet.** `exec` replaces the marked shell
  with a bare `sleep`, which removes the marker from `argv` and makes the orphan
  invisible to the sweep — i.e. unkillable by this script. The comment in the
  source says the same thing, for the same reason.

**repro-002** runs the real CLI, so it is isolated a different way:

- `HOME` **and** `CLAUDE_CONFIG_DIR` both point at a fresh `mktemp -d`, inside
  `env -i`, so the process cannot see, read, refresh, or invalidate your real
  credential. The temp tree is removed on every exit path via `trap`.
- The "bogus token" is a syntactically-shaped placeholder, not a real credential,
  and is rejected server-side.
- No live session, pane, or daemon is contacted; it only ever runs `claude -p`.
- Because every invocation fails before reaching the model, it consumes no
  tokens and no plan quota.

**repro-003** only reads: `strings` over the installed binary. It writes nothing
and executes nothing.

## Interpreting a different result

These were captured on **Claude Code 2.1.263 / macOS 26.6.2 / Apple M3 Max**. If
your output differs:

- **repro-001** is version-independent — it demonstrates POSIX process
  reparenting, not Claude Code behavior. If Phase A reports no leak on your
  system, something in your environment is already reaping orphans.
- **repro-002**'s exit codes have changed between CLI versions; the specs claim
  only the *channel* and *field*, which is the part that has been stable. If
  stdout is empty and the notice appears on stderr, SPEC-002's primary ask has
  been implemented — please open an issue on this repo so the spec can be
  updated.
- **repro-003** greps a minified binary, so the variable name in the schema line
  (`X(` above) will differ across builds. The pattern is written to tolerate
  that; if it finds nothing, the binary shape has changed and the spec needs
  re-verification.
