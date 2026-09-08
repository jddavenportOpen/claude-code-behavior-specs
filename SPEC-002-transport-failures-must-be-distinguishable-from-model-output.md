# SPEC-002 — Transport failures must be distinguishable from model output

| | |
|---|---|
| **Area** | Headless output contract · `--print` / `--output-format` |
| **Severity** | High — silent data corruption; failures propagate into deliverables |
| **First observed** | 2026-08-31 |
| **Reproduced** | 2026-09-08 on CLI **2.1.263** |
| **Affects** | Every programmatic `claude -p` caller |

## 1. Summary

When a headless invocation fails **before reaching the model** — no credential,
invalid credential, expired session, plan or usage limit reached, org policy
denial — the CLI delivers a human-readable notice **on stdout**, the same stream
that carries the model's answer. Under `--output-format json` it delivers that
notice **in the `result` field**, the same field that carries the model's answer,
inside an envelope that simultaneously reports `"is_error": true` and
`"subtype": "success"`.

A programmatic caller therefore cannot tell "the model answered" from "the model
was never reached" without pattern-matching the vendor's English error prose.
One such caller did not, and shipped 63 documents whose body text was the string
`Not logged in · Please run /login`. Seven of them reached a human for approval
to send externally.

### A correction to the claim this spec was drafted from

An internal note asserted these failures exit **0**. **That does not reproduce on
CLI 2.1.263**: both the no-credential and invalid-credential cases exit **1**
(see §4). The exit-`0` behavior was recorded during a *different* code path — a
condition where the OS directory-services daemon had wedged and the CLI could not
*read* an existing Keychain credential, which is not the same as the credential
being absent. That path could not be re-probed here without deliberately wedging
a system daemon.

**This spec therefore claims only what reproduces today: the channel and the
field, not the exit code.** That is also the more important half — an exit code
can be checked once, but a caller that reads stdout is reading the failure *as
content*, and no exit-code fix reaches a caller that already trusted the stream.

## 2. Observed behavior

On CLI 2.1.263, with a throwaway empty config directory:

| case | exit | stream | payload |
|---|---|---|---|
| no credential, text mode | `1` | **stdout** | `Not logged in · Please run /login` |
| invalid OAuth token, text mode | `1` | **stdout** | `Failed to authenticate. API Error: 401 OAuth access token is invalid.` |
| no credential, `--output-format json` | `1` | **stdout** | JSON envelope, below |
| no credential, `--output-format stream-json` | `1` | — | **stdout is empty** |

`stderr` is empty in all four cases (apart from unrelated workspace-trust
warnings).

The JSON envelope, verbatim, with the load-bearing fields extracted:

```json
{
  "type": "result",
  "subtype": "success",              // <- contradicts is_error
  "is_error": true,
  "terminal_reason": "api_error",
  "api_error_status": null,          // <- null on an api_error
  "result": "Not logged in · Please run /login",   // <- the answer field
  "num_turns": 1,
  "total_cost_usd": 0,
  "stop_reason": "stop_sequence"     // <- a normal-completion stop reason
}
```

Four separate problems in one object:

1. `subtype` is `"success"`. A caller keying on `subtype` — a reasonable choice,
   it is the field that names *what kind of result this is* — is told the run
   succeeded.
2. `result` carries the failure prose. This is the documented field for the
   model's answer, so `.result` is exactly what a caller reads.
3. There is **no stable machine-readable error code**. `terminal_reason` is
   `"api_error"` for a purely local not-logged-in condition, and
   `api_error_status` is `null`. Nothing distinguishes *retry on another
   credential* (usage limit) from *this credential is broken* (auth) from *the
   org forbade it* (policy) — three cases that need opposite handling.
4. `stop_reason` is `"stop_sequence"`, a normal-completion value.

And `stream-json` returns an **empty stdout**, which is worse than either: a
streaming consumer gets no terminal event at all and must infer failure from
silence.

## 3. Expected behavior

**A result that is not a model answer must not be delivered where a model answer
is delivered.** Specifically:

1. **Text mode: the failure notice goes to stderr, and stdout stays empty.**
   This is the ordinary Unix contract and it is what makes `$(claude -p ...)`
   safe to use at all.
2. **JSON mode: `subtype` must never be `"success"` when `is_error` is true**,
   and **`result` must be absent or `null`** on a transport failure. Failure text
   belongs in an `error` object, not in the answer field.
3. **A stable, documented, machine-readable error code** that a caller can
   switch on without matching English — e.g. `not_authenticated`,
   `credential_invalid`, `session_expired`, `usage_limit_reached`,
   `org_policy_denied`, each with a documented "is this retryable, and on what."
   Locale, wording and punctuation must not be part of the contract.
4. **`stream-json` must emit a terminal error event**, never an empty stream.
5. **Distinct exit codes per class**, documented. Partly true today; the classes
   are still not distinguishable from each other.

The general form of the rule: **the harness must never make a caller's
correctness depend on parsing the harness's prose.**

## 4. Minimal reproduction

[`reproductions/repro-002-transport-failure-on-stdout.sh`](reproductions/repro-002-transport-failure-on-stdout.sh)
— runs `claude -p` three times against a fresh `mktemp` directory used as both
`HOME` and `CLAUDE_CONFIG_DIR`, so it cannot read, write, refresh or invalidate a
real credential and never touches a live session. Every call fails before
reaching the model, so it costs **zero tokens**.

```
$ ./repro-002-transport-failure-on-stdout.sh "$(command -v claude)"
repro-002   binary: .../claude
2.1.263 (Claude Code)

── 1. no credential (text mode)
   exit code : 1
   stdout    : Not logged in · Please run /login
   stderr    : <empty>

── 2. bogus OAuth token (text mode)
   exit code : 1
   stdout    : Failed to authenticate. API Error: 401 OAuth access token is invalid.
   stderr    : <empty>

── 3. no credential (--output-format json)
   exit code : 1
   stdout    : {... "terminal_reason":"api_error", "is_error":true,
                "subtype":"success", "result":"Not logged in · Please run /login" ...}
   stderr    : <empty>
```

The string in case 1 is **33 characters**, byte-identical to the one recorded in
the 2026-08-31 incident below.

## 5. Evidence

### 5.1 The incident, 2026-08-31

A host OS directory-services daemon (`opendirectoryd`) wedged at ~21:00 local.
Among other effects, `claude -p` could no longer read its Keychain credential and
began printing the not-logged-in notice. Two independent callers on that machine
— a document-tailoring step and a separate grading step — each treated the CLI's
stdout as the model's answer, because in text mode there is nothing else to treat
as the answer.

**Measured, from the machine-written recovery ledger** (a JSON artifact created
by the recovery routine, 65 rows) and from the quarantine directory:

| | |
|---|---|
| Documents built in the outage window (21:00–03:00) | 77 |
| **Documents whose body carried the login notice as their generated summary** | **63** |
| Those PDFs, still present in the quarantine directory (counted for this document) | 63 |
| Auto-rejected below the quality bar | 48 |
| **Surfaced to the human for approval to send externally** | **7** |
| Flagged needs-human | 6 |
| Blocked / building / skipped | 2 / 1 / 1 |

> Footnote on a discrepancy: the contemporaneous human incident note says 47
> below-bar; the machine ledger says 48. The ledger is used here.

**Three details that make this worse than a simple bug:**

1. **The pipeline's own health metric said everything was fine.** Its lane logs
   reported `transport=0m/4cli/0fail` for the entire six-hour window. From the
   caller's perspective every call returned a 200-shaped success with content.
2. **The corruption propagated far enough to be graded as a writing problem.** A
   downstream LLM grader, with no knowledge of the incident, produced rationales
   like *"the header carries a stray 'Not logged in · Please run /login' line"*
   and *"stray application-UI text embedded in the header suggests the document
   was exported from an automated pipeline without a final human read."* A
   transport failure had travelled all the way into a document-quality judgment.
   Nothing in the stack ever got to classify it as a transport failure, because
   nothing in the stack was ever *told* it was one.
3. **The last line of defence was a human.** Seven of these reached a human
   approval queue as candidate outbound documents.

### 5.2 A second, independent instance of the same class

On the same rail, the account's weekly plan cap printed
`You've hit your weekly limit · resets <date>` to stdout. The grading client
returned that string as the model's response — and, believing it had a valid
answer, **never failed over to one of the other accounts that still had quota.**
So during a partial cap, grading failed estate-wide while capacity sat unused.
Different failure class, same root cause, same silent corruption, discovered
weeks apart.

## 6. Impact

- **63 corrupted documents**, of which 7 reached a human approval queue as
  candidate outbound artifacts, and a manual quarantine + rebuild was required.
- **Six hours of undetected failure** with a health metric reporting zero
  failures throughout.
- **A capacity failover silently defeated** during the weekly-limit instance.
- The general form: any pipeline that stores or forwards `claude -p` output
  will, on the day its credential lapses, **persist an English error string into
  its data**. Depending on the pipeline that is a corrupted document, a poisoned
  cache, a bad database row, or an email.

## 7. Proposed eval / check

Table-driven, one row per induceable failure class — no credential, invalid
credential, expired session, usage limit, org policy denial. For each, and for
each of `text`, `json`, `stream-json`, assert:

1. **Text mode:** `stdout` is empty; the notice is on `stderr`.
2. **JSON mode:** `is_error == true` **and** `subtype != "success"`;
   `result` is absent or `null`; an `error.code` field is present and is one of a
   documented, stable enum.
3. **Stream-json:** at least one terminal event is emitted; the stream is never
   empty.
4. **Exit code** is non-zero and matches the documented code for that class.
5. **Cross-version stability:** `error.code` values are compared against a
   checked-in golden file, so a rename is a deliberate, visible change.

Plus one property test that captures the actual goal:

> **A reference caller written to inspect only `is_error` and `error.code` —
> containing no substring matching of any kind — must correctly classify every
> row in the table.**

If that test can be written and passes, the spec is satisfied. Today it cannot
be, in any output format.

## 8. Workaround shipped — and why it is evidence, not a solution

The only defence available to a text-mode caller is a **substring blocklist of
English failure phrases**. The one on that estate now reads, in full:

```
"organization has disabled", "OAuth session expired", "Failed to authenticate",
"Use an Anthropic API key instead", "usage limit", "session limit",
"Credit balance is too low", "weekly limit", "hit your",
"Not logged in", "Please run /login"
```

Eleven entries, each added reactively after a production incident that the
previous ten did not catch. It is:

- **wording-fragile** — any rephrase, any punctuation change, silently reopens
  the hole;
- **locale-fragile** — it assumes the CLI speaks English;
- **and it has to accept known false-positive risk.** The entry `"hit your"` is a
  two-word English fragment that would match ordinary model output in almost any
  other pipeline. It is only tolerable there because the expected output is
  strict JSON that provably never contains the phrase — a property that had to be
  *reasoned about and written down in a comment* to justify the entry.

Callers were also hardened to walk to another credential on a detected failure
rather than returning the first bad result — but that failover can only fire on
what the blocklist catches.

**When a caller's correctness depends on grepping the vendor's error prose, and
the grep is documented with a paragraph explaining why one of its entries is not
too dangerous, the contract is missing.** That is the finding.
