# Claude Code behavior specs

Three Claude Code CLI bugs I hit running agents headless. Each one has a repro script and the workaround I shipped.

I run my own agent system on [Claude Code](https://github.com/anthropics/claude-code). I've built 100+ agents for it since February 2026, and a lot of them run unattended as `claude -p` jobs. Running the CLI that way, as a library with nobody watching, is what surfaced these. All three are in the CLI itself: how it cleans up child processes, which stream an error comes out on, and how it reads a settings file. And each one quietly broke downstream work before I noticed.

Each spec pairs what the CLI does with what I think it should do, a small repro you can run yourself, the impact I measured, a proposed eval, and the workaround I built.

## The specs

| | Spec | One line | Status |
|---|---|---|---|
| **001** | [A headless invocation must not orphan its MCP-server children](SPEC-001-headless-invocation-must-not-orphan-mcp-children.md) | When `claude` dies without a clean exit, its MCP child processes reparent to PID 1 and keep running. Under load that feeds on itself. It took my machine down 7 times in 3 days. | Reproduced 2026-09-08 on 2.1.263. The repro is a stand-in that needs no Claude Code, and it still shows the leak (2026-11-22) |
| **002** | [Transport failures must be distinguishable from model output](SPEC-002-transport-failures-must-be-distinguishable-from-model-output.md) | Login and quota failures come out as prose on stdout. In JSON mode they land in the `result` field next to `"subtype":"success"`. 63 documents got generated with a login notice as their body. | Reproduced on 2.1.263 (2026-09-08) and 2.1.323 (2026-11-22) |
| **003** | [An out-of-enum settings value must not be silently discarded](SPEC-003-out-of-enum-settings-values-must-not-be-silently-discarded.md) | `{"effortLevel":"max"}` in settings.json is read as if the key were missing, with no error. My sessions ran at the default level for weeks while the config said otherwise. | Reproduced on 2.1.263 (2026-09-08) and 2.1.323 (2026-11-22). Lower impact |

## How a spec is structured

Every spec has the same eight sections, in this order:

1. **Summary.** One paragraph an engineer can triage from.
2. **Observed behavior.** What the tool does, without interpretation.
3. **Expected behavior.** What I'm proposing, and why the line sits there.
4. **Minimal reproduction.** A script in [`reproductions/`](reproductions/),
   plus its verbatim output on a known version.
5. **Evidence.** Dates, counts, and the artifact each number came from.
   Numbers recorded during an incident whose raw measurement wasn't kept are
   labeled separately from numbers I re-measured for the document.
6. **Impact.** What broke, as measured.
7. **Proposed eval.** What a regression test for this should assert.
8. **Workaround shipped.** What I had to build to live with it.

## Reproducing

```bash
cd reproductions

# SPEC-001: offline, no Claude Code needed, ~6 s, self-cleaning
python3 repro-001-orphaned-grandchild.py

# SPEC-002: runs claude against a throwaway empty config dir; zero tokens
./repro-002-transport-failure-on-stdout.sh "$(command -v claude)"

# SPEC-003: read-only static probe of the installed binary
./repro-003-effort-enum-schema-probe.sh
```

All three are read-only with respect to your real configuration. See
[`reproductions/README.md`](reproductions/README.md) for the safety design of
each, particularly repro-001, which deliberately creates and then guarantees the
cleanup of the very orphan class the spec is about.

## Evidence discipline

The rules I wrote this under, so you can check it:

- **Reproduced beats recorded.** Where a claim could be re-tested on today's
  CLI, it was, and the version is named. Where it could not, the spec says so.
- **Corrections are kept, not quietly dropped.** SPEC-002 was drafted from an
  internal note asserting these failures exit `0`. On CLI 2.1.263 they exit `1`.
  The spec says that plainly and narrows its claim to the part that still
  reproduces. The correction sits in the spec itself, where a reader will see it.
- **Machine ledgers beat prose notes.** Where a contemporaneous human note and a
  machine-written recovery ledger disagreed on a count (47 vs 48), the ledger is
  used and the discrepancy is footnoted.
- **No inference presented as measurement.** "Recorded by the incident
  responder" and "counted for this document" are labeled differently throughout.

## Scope and non-goals

- These are **CLI** behaviors: process lifecycle, output channels, config
  parsing. Model quality and output content are out of scope.
- No customer data, credentials, employer names, or personal identifiers appear
  in this repository. Counts are preserved; identifying detail is not.
- Nothing here has been filed as an issue. [`ISSUE-DRAFTS.md`](ISSUE-DRAFTS.md)
  has issue-ready text for `anthropics/claude-code` that I haven't filed.

## Versions this was checked against

| What | Version |
|---|---|
| Claude Code | 2.1.263 (written). Repros re-run 2026-11-22: SPEC-002 and SPEC-003 still reproduce on 2.1.323, and the SPEC-001 stand-in still leaks |
| OS | macOS 26.6.2 |
| Incident window | 2026-08-31 (SPEC-002), 2026-09-06 to 2026-09-08 (SPEC-001) |
| Document date | 2026-09-08 |

## Changes and corrections

[`CHANGELOG.md`](CHANGELOG.md) records spec revisions, including any spec
narrowed after re-testing. Corrections stay in the document.

## License

MIT. See [LICENSE](LICENSE).
