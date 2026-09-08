# Changelog

Spec revisions are recorded here, including corrections. A spec whose evidence
turns out to be weaker than claimed gets narrowed in place with the reason
stated — see the "Evidence discipline" section of the README.

## 2026-09-08

- 12:27 — Published 3 Claude Code target-behavior specs with runnable reproductions to github.com/jddavenportOpen/claude-code-behavior-specs — SPEC-001 headless invocations orphan MCP children (7 kernel panics in 3 days), SPEC-002 transport failures indistinguishable from model output (63 corrupted documents, 7 to human approval), SPEC-003 silent out-of-enum settings discard. ISSUE-DRAFTS.md written but deliberately unfiled pending JD's approval.
- Initial publication: SPEC-001 (headless invocations orphan MCP-server
  children), SPEC-002 (transport failures are indistinguishable from model
  output), SPEC-003 (out-of-enum settings values are silently discarded).
- Three runnable reproductions added, all verified against Claude Code 2.1.263
  on macOS 26.6.2 / Apple M3 Max.
- **Correction carried into SPEC-002 at publication.** The spec was drafted from
  an internal note asserting these transport failures exit `0`. Re-testing on
  2.1.263 showed both the no-credential and invalid-credential cases exit `1`.
  The spec was narrowed to claim only the output *channel* and *field*, which do
  reproduce, and the correction is stated in the spec body rather than dropped.
- **Figure labeled as unverifiable in SPEC-001.** The "~2,210 orphaned processes
  holding 88.30 GB" count was recorded by the incident responder in three
  artifacts, but the raw process census was not preserved. It is reported as a
  contemporaneous measurement, distinguished from the panic-log and jetsam
  figures, which are re-derivable.
- ISSUE-DRAFTS.md added with issue-ready text for `anthropics/claude-code`.
  Deliberately unfiled.
