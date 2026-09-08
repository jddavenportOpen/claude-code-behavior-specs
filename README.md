# Claude Code — target-behavior specs from real usage

Behavior specs for the [Claude Code](https://github.com/anthropics/claude-code) CLI,
written from incidents in a production agent estate rather than from synthetic
testing. Each spec pairs an observed behavior with the expected behavior, a
minimal reproduction you can run yourself, the measured downstream impact, a
proposed eval, and the workaround that was actually shipped.

**Where the evidence comes from.** A single-operator agent system: ~55 named
agents, up to ~30 concurrent Claude Code sessions across three machines, plus a
few hundred scheduled headless `claude -p` invocations a day driving recruiting,
research, ops and QA pipelines. That workload is unusual in exactly the way that
surfaces these bugs — it runs the CLI as a *library*, unattended, at
concurrency, for months. The failures below are not "the model said something
wrong." They are harness-contract failures, and each one silently corrupted
downstream work before anyone noticed.

## The specs

| | Spec | One line | Status |
|---|---|---|---|
| **001** | [A headless invocation must not orphan its MCP-server children](SPEC-001-headless-invocation-must-not-orphan-mcp-children.md) | When `claude` dies without a clean exit, its MCP child processes reparent to PID 1 and live forever; under load this is a positive feedback loop that took a machine down 7 times in 3 days. | Reproduced 2026-09-08 |
| **002** | [Transport failures must be distinguishable from model output](SPEC-002-transport-failures-must-be-distinguishable-from-model-output.md) | Credential/quota failures are delivered as prose on stdout — and in JSON mode, in the `result` field alongside `"subtype":"success"`. 63 documents were generated with a login notice as their body. | Reproduced 2026-09-08 on CLI 2.1.263 |
| **003** | [An out-of-enum settings value must not be silently discarded](SPEC-003-out-of-enum-settings-values-must-not-be-silently-discarded.md) | `{"effortLevel":"max"}` parses as *absent*, not as an error. Sessions ran at the default tier for weeks while the config said otherwise. | Reproduced 2026-09-08 · lower impact, included for completeness |

## How a spec is structured

Every spec has the same eight sections, in this order:

1. **Summary** — one paragraph an engineer can triage from.
2. **Observed behavior** — what the tool does, stated without interpretation.
3. **Expected behavior** — the target behavior being proposed, and why that
   line is the right one to draw.
4. **Minimal reproduction** — a script in [`reproductions/`](reproductions/),
   plus its verbatim output on a known version.
5. **Evidence** — dates, counts, and what artifact each number came from.
   Numbers that were *recorded during an incident* but whose raw measurement was
   not preserved are labeled as such, separately from numbers that were
   *re-measured for this document*.
6. **Impact** — what broke, measured, not estimated.
7. **Proposed eval / check** — what a regression test for this should assert.
8. **Workaround shipped** — what a downstream operator had to build to survive
   it, which is itself a measure of the gap.

## Reproducing

```bash
cd reproductions

# SPEC-001 — offline, no Claude Code needed, ~6 s, self-cleaning
python3 repro-001-orphaned-grandchild.py

# SPEC-002 — runs claude against a throwaway empty config dir; zero tokens
./repro-002-transport-failure-on-stdout.sh "$(command -v claude)"

# SPEC-003 — read-only static probe of the installed binary
./repro-003-effort-enum-schema-probe.sh
```

All three are read-only with respect to your real configuration. See
[`reproductions/README.md`](reproductions/README.md) for the safety design of
each, particularly repro-001, which deliberately creates and then guarantees the
cleanup of the very orphan class the spec is about.

## Evidence discipline

These are the rules this document was written under, stated so you can check it:

- **Reproduced beats recorded.** Where a claim could be re-tested on today's
  CLI, it was, and the version is named. Where it could not, the spec says so.
- **Corrections are kept, not quietly dropped.** SPEC-002 was drafted from an
  internal note asserting these failures exit `0`. On CLI 2.1.263 they exit `1`.
  The spec says that plainly and narrows its claim to the part that still
  reproduces. That correction is in the document rather than in a changelog
  because a spec that overstates its evidence is worth less than no spec.
- **Machine ledgers beat prose notes.** Where a contemporaneous human note and a
  machine-written recovery ledger disagreed on a count (47 vs 48), the ledger is
  used and the discrepancy is footnoted.
- **No inference presented as measurement.** "Recorded by the incident
  responder" and "counted for this document" are labeled differently throughout.

## Scope and non-goals

- These are **harness** behaviors — process lifecycle, output channels, config
  parsing. Nothing here is about model quality or output content.
- No customer data, credentials, employer names, or personal identifiers appear
  in this repository. Counts are preserved; identifying detail is not.
- Nothing here has been filed as an issue. [`ISSUE-DRAFTS.md`](ISSUE-DRAFTS.md)
  contains issue-ready versions for `anthropics/claude-code`, deliberately
  unfiled.

## Versions this was checked against

| | |
|---|---|
| Claude Code | 2.1.263 |
| OS | macOS 26.6.2, Apple M3 Max, 36 GB unified memory |
| Incident window | 2026-08-31 (SPEC-002) · 2026-09-06 → 2026-09-08 (SPEC-001) |
| Document date | 2026-09-08 |

## Changes and corrections

[`CHANGELOG.md`](CHANGELOG.md) records spec revisions, including any spec
narrowed after re-testing. Corrections stay in the document.

## License

MIT. See [LICENSE](LICENSE).
