# Issue drafts — `anthropics/claude-code`

> **These are drafts. None has been filed.** Outward actions on someone else's
> repository require the repository owner's explicit approval, and this document
> exists so that approval can be given against exact text rather than a summary.
>
> Before filing any of these: **search open and closed issues first.** SPEC-001
> in particular has at least one prior report (`#68647`, cited in this repo's
> audit but not independently verified). If a matching issue exists, the right
> action is a comment adding the reproduction and the measurements — not a new
> issue.

---

## Draft 1 — SPEC-001

**Title:** `claude -p` orphans its MCP-server children when the parent is killed; at volume this is a machine-fatal feedback loop

**Labels:** `bug`, `mcp`, `cli`

**Body:**

### What happened

`claude -p` spawns one child process per configured stdio MCP server. Those
children live in the *caller's* process group. If the `claude` process dies
without a clean exit — a caller's `subprocess.run(timeout=)`, a `SIGKILL`, or an
OS memory-pressure kill — the children are reparented to PID 1 and run forever,
holding their full resident memory. The caller has no way to clean them up: the
CLI never discloses their PIDs in any output format.

A separate case is easy to miss: **a clean exit is not sufficient either**, since
a process that exits normally does not reap its own grandchildren.

At volume this is a positive feedback loop rather than a leak. Memory pressure
causes the OS to kill parents; each kill creates permanent orphans; pressure
rises. On a 36 GB Apple M3 Max running macOS 26.6.2 with a few hundred headless
invocations a day, that loop produced **seven kernel panics in three days**
(2026-09-06 → 2026-09-08), with the interval collapsing from 55 hours to 19
minutes. All seven panic strings were
`watchdog timeout: no checkins from watchdogd in 90–94 seconds` with
`Compressor Info: … 100% of segments limit (BAD)`. A jetsam event seven minutes
before one of them recorded 94 MB free, 12.99 GiB in the VM compressor, and 1,953
processes jettisoned across 51 jetsam generations.

Worth flagging for anyone trying to detect this: **free RAM and swap look healthy
right into the collapse**, because compressed pages leave a process's RSS. Only
the compressor's *segment* percentage tracked the real state — it read
`100% (BAD)` while the adjacent pages counter read `44% (OK)`.

### Why this is a tool problem, not a caller problem

`subprocess.run(cmd, timeout=T)` is the documented, ordinary way to bound a
subprocess, and it does exactly what it promises: it kills the process it
started. It is wrong here only because `claude` leaves descendants that outlive
it, and nothing in the CLI's docs, output, or exit behavior says so. A tool that
spawns unmanaged grandchildren makes every naive caller wrong.

Empirically, the caller-side shape is written constantly: in one codebase, *after*
the bug was diagnosed and a drop-in safe replacement existed, an AST lint still
found **23 call sites across 21 files** spawning `claude` without a process
group.

### Reproduction

A tool-independent, self-cleaning reproduction (no Claude Code, credential, or
network needed) is here:
`reproductions/repro-001-orphaned-grandchild.py` in
`jddavenportOpen/claude-code-behavior-specs`. It shows a grandchild surviving a
`subprocess.run(timeout=)` with `ppid == 1`, and the same call surviving nothing
when `start_new_session=True` + `killpg` are used.

With the real tool: configure ≥1 stdio MCP server, run `claude -p 'hi' &`, wait
for the servers to start, `kill -9` the claude PID, then
`ps -Ao pid=,ppid=,command= | awk '$2==1'`.

### Suggested fix, in order of value

1. **Stdio MCP servers should exit on stdin EOF.** Portable, needs no cooperation
   from the caller, and covers `SIGKILL` and OOM kills — the pipe closes when the
   parent dies for any reason. Best placed in the MCP server template / SDK
   default loop, and enforceable as an MCP conformance assertion: *a stdio server
   must exit within N seconds of stdin reaching EOF.*
2. `claude` should own a process group / job object containing its children, so
   one `killpg` from a supervisor reaches the tree. A caller cannot do this today
   because the children share the caller's group.
3. Parent-death watch as defence in depth (`PR_SET_PDEATHSIG` on Linux, kqueue
   `NOTE_EXIT` on macOS).
4. At minimum, **disclose the child PIDs** in the `--output-format json`
   envelope, so callers can implement their own reaper. Today the leak is not
   just unmanaged, it is invisible.

### Suggested regression test

A soak is the test that catches this — no single-invocation test can see a leak
whose harm is cumulative. 500 headless invocations, half `SIGKILL`ed mid-flight,
assert the process count and RSS return to baseline. Plus a direct kill-tree
assertion for `SIGKILL` / `SIGTERM` / caller-timeout, and a clean-exit assertion
that no MCP server survives normal completion.

---

## Draft 2 — SPEC-002

**Title:** Transport failures are delivered on stdout (and in the JSON `result` field) — indistinguishable from a model answer

**Labels:** `bug`, `cli`, `headless`

**Body:**

### What happens

When a headless invocation fails **before reaching the model** — no credential,
invalid credential, expired session, usage limit, org policy denial — the CLI
prints a human-readable notice to **stdout**, the same stream that carries the
model's answer. `stderr` stays empty.

On CLI **2.1.263**, against an empty throwaway config dir:

```
no credential,      text : exit 1, stdout = "Not logged in · Please run /login"
bogus OAuth token,  text : exit 1, stdout = "Failed to authenticate. API Error: 401 OAuth access token is invalid."
no credential,      json : exit 1, envelope below
no credential, stream-json: exit 1, stdout EMPTY
```

The JSON envelope is self-contradicting:

```json
{
  "type": "result",
  "subtype": "success",                              // contradicts is_error
  "is_error": true,
  "terminal_reason": "api_error",
  "api_error_status": null,                          // null on an api_error
  "result": "Not logged in · Please run /login",     // the ANSWER field
  "stop_reason": "stop_sequence"                     // a normal-completion value
}
```

So even a caller that opts into JSON gets the failure prose in `result` — the
documented field for the model's answer — while `subtype` says `success`. And
there is no stable machine-readable error code: nothing distinguishes *retry on
another credential* (usage limit) from *this credential is broken* (auth) from
*the org forbade it* (policy). `stream-json` returns nothing at all.

### Why it matters

A programmatic caller cannot tell "the model answered" from "the model was never
reached" without pattern-matching English error prose.

Measured consequence on one estate: an OS directory-services daemon wedged for
six hours; `claude -p` could not read its credential and printed the notice; two
independent callers took it as the model's answer. **63 generated documents
carried `Not logged in · Please run /login` as their body text.** 48 were
auto-rejected downstream on quality grounds, **7 reached a human approval queue
as candidate outbound documents**, 6 were flagged for review. The pipeline's own
health metric reported **zero transport failures** for the entire window.

The corruption travelled far enough that a downstream LLM grader — with no
knowledge of the outage — wrote *"stray application-UI text embedded in the
header suggests the document was exported from an automated pipeline without a
final human read."* It was graded as a writing defect because nothing in the
stack was ever able to classify it as a transport failure.

A second, independent instance of the same class: the weekly plan cap printed
`You've hit your weekly limit · resets <date>` to stdout, the caller returned it
as the model's response and therefore **never failed over to an account that
still had quota** — capacity sat unused during a partial cap.

### The workaround, offered as evidence

The only defence available in text mode is a substring blocklist of English
failure phrases. The one in production reads:

```
"organization has disabled", "OAuth session expired", "Failed to authenticate",
"Use an Anthropic API key instead", "usage limit", "session limit",
"Credit balance is too low", "weekly limit", "hit your",
"Not logged in", "Please run /login"
```

Eleven entries, each added reactively after an incident the previous ten missed.
One of them, `"hit your"`, is a two-word English fragment that would false-positive
on ordinary model output in almost any other pipeline; it is only tolerable
because the expected output there is strict JSON, a fact that had to be reasoned
about and written down in a code comment to justify the entry.

When a caller's correctness depends on grepping the vendor's error prose, and the
grep needs a paragraph explaining why one entry is not too dangerous, the contract
is missing.

### Requested behavior

1. **Text mode:** failure notices to `stderr`; `stdout` stays empty.
2. **JSON mode:** `subtype` must never be `"success"` when `is_error` is true;
   `result` must be absent or `null` on a transport failure; failure text belongs
   in an `error` object.
3. **A stable, documented `error.code` enum** — `not_authenticated`,
   `credential_invalid`, `session_expired`, `usage_limit_reached`,
   `org_policy_denied` — each documented as retryable or not, and on what.
   Locale and wording must not be part of the contract.
4. **`stream-json` must emit a terminal error event**, never an empty stream.
5. Distinct, documented exit codes per class.

### Suggested regression test

Table-driven, one row per induceable failure class × each output format,
asserting the five points above. Plus the property test that captures the goal:

> a reference caller inspecting only `is_error` and `error.code`, containing no
> substring matching of any kind, must correctly classify every row.

Today that test cannot be written in any output format.

### Note on a prior claim

An earlier internal note asserted these failures exit `0`. On 2.1.263 they exit
`1`; the exit-`0` observation came from a distinct path (the credential store
being *unreadable* rather than absent) that could not be re-probed. This issue
claims only the channel and field, which reproduce today.

### Reproduction

`reproductions/repro-002-transport-failure-on-stdout.sh` in
`jddavenportOpen/claude-code-behavior-specs`. Runs against a fresh `mktemp -d`
used as both `HOME` and `CLAUDE_CONFIG_DIR`, so it cannot touch a real
credential. Costs zero tokens — every call fails before the model.

---

## Draft 3 — SPEC-003

**Title:** `settings.json` silently discards an out-of-enum `effortLevel` (e.g. `"max"`) instead of warning

**Labels:** `bug`, `settings`, `dx`

**Body:**

The persisted settings schema validates `effortLevel` against
`["low","medium","high","xhigh"]` with `.catch(void 0)`, so an out-of-enum value
is coerced to `undefined` — parsed as if the key were absent. The session starts
at the model default while the file says otherwise, and nothing reports it.

`"max"` is the value that bites, because `--effort max` **is** valid: the same
binary contains a second enum, `["low","medium","high","xhigh","max"]`, for the
flag. Users reasonably infer the flag's value space is the file's.

Three things make this a silence bug rather than a docs gap:

1. `.catch(void 0)` is an explicit decision to swallow a parse failure on
   user-authored configuration.
2. The same binary emits `apply_flag_settings: unrecognized effortLevel` for the
   same class of input on a *different* code path — so one route warns and the
   persisted-settings route does not.
3. Neither `/status`, `/doctor`, nor startup surfaces the discarded value.

One estate carried `"effortLevel": "max"` in four settings files for about a
month, believing sessions were pinned to the top tier. They were not, and
thousands of sessions started without a single diagnostic. It also masked a
second-order problem: two processes were both writing the key with different
values, rewriting the file 30–70 times a day for 27 days, and neither noticed,
because the invalid write produced no signal that anything was contested.

**Requested:**

1. A visible diagnostic naming the file, key, rejected value, and accepted set.
   Silent `.catch` is right for unknown *keys* (forward compatibility), wrong for
   known keys with unparseable values.
2. `/doctor` should list settings entries that were parsed away — that is
   precisely the "my config isn't doing anything" question it exists to answer.
3. Either accept `max` as persistable, or document the divergence between the
   persisted and flag enums.
4. Build-time check: for any setting also expressible as a CLI flag, assert the
   enums are equal or that the difference is registered with a reason. That would
   have caught this at build time.

**Reproduction:** `reproductions/repro-003-effort-enum-schema-probe.sh` in
`jddavenportOpen/claude-code-behavior-specs` — read-only `strings` probe of the
installed binary, zero cost.
