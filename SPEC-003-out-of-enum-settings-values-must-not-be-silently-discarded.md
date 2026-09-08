# SPEC-003 — An out-of-enum settings value must not be silently discarded

| | |
|---|---|
| **Area** | Settings parsing |
| **Severity** | Medium — silent config no-op, no data loss |
| **Reproduced** | 2026-09-08 on CLI **2.1.263**, statically |
| **Scope note** | Shorter than SPEC-001/002 on purpose: real and reproducible, but the harm is wasted intent rather than corrupted output. |

## 1. Summary

`settings.json` validates `effortLevel` against `["low","medium","high","xhigh"]`
with a `.catch(void 0)` fallback. A value outside that set — notably `"max"`,
which *is* valid for the session-scoped `--effort` flag — is coerced to
`undefined`, i.e. parsed as if the key were **absent**. The session then starts
at the model default while the file on disk says otherwise, and nothing anywhere
reports the mismatch.

## 2. Observed behavior

From the installed 2.1.263 binary:

```
effortLevel:X(["low","medium","high","xhigh"]).optional().catch(void 0)
            .describe("Persisted effort level for supported models.")
effortLevel:X(["low","medium","high","xhigh"]).optional().catch(void 0)
            .describe("Persisted effort level for this model.")
```

and, elsewhere in the same binary, a **different** effort enum that does include
`max`:

```
["low","medium","high","xhigh","max"]
```

So `max` is a real, valid effort tier — just not a persistable one. The two
enums are never reconciled and the asymmetry is undocumented.

Three things make this specifically a *silence* bug rather than a documentation
gap:

1. `.catch(void 0)` is an explicit decision to swallow the parse failure.
2. The **same binary contains a warning string for the same class of input on a
   different code path** — `apply_flag_settings: unrecognized effortLevel` — so
   one route reports it and the persisted-settings route does not.
3. Neither `/status`, `/doctor`, nor startup surfaces the discarded value. The
   only way to notice is to observe that sessions behave at the default tier and
   go looking.

## 3. Expected behavior

1. **An out-of-enum value in a settings file must produce a visible diagnostic**
   naming the file, the key, the rejected value, and the accepted set. A silent
   `.catch` on user-authored configuration is the wrong default; silence is
   appropriate for forward-compatibility with *unknown keys*, not for known keys
   with unparseable values.
2. **`/doctor` should report settings entries that were parsed away**, since that
   is exactly the "my config isn't doing anything" question it exists to answer.
3. Either **accept `max` as a persistable value**, or **document why the
   persisted and flag enums differ** — currently a user reasonably infers from
   `--effort max` that `"effortLevel": "max"` is valid.

## 4. Minimal reproduction

[`reproductions/repro-003-effort-enum-schema-probe.sh`](reproductions/repro-003-effort-enum-schema-probe.sh)
— read-only static probe of the installed binary. Zero cost, no model call, no
config written.

```
$ ./repro-003-effort-enum-schema-probe.sh
── persisted settings.json schema for effortLevel
effortLevel:X(["low","medium","high","xhigh"]).optional().catch(void 0).describe("Persisted effort level for supported models.")
effortLevel:X(["low","medium","high","xhigh"]).optional().catch(void 0).describe("Persisted effort level for this model.")

── every effort-shaped enum present in the binary
["low","medium","high","immediate"]
["low","medium","high","xhigh","max"]
["low","medium","high","xhigh"]
["low","medium","high"]
```

**Behavioral confirmation:** with `"effortLevel": "max"` in a settings layer,
that layer is dropped and the session falls through to the next layer's value —
or, with no other layer, to the model default. No warning is printed.

## 5. Evidence

- The estate carried `"effortLevel": "max"` in four settings files **for
  approximately one month**, believing sessions were pinned to the top tier. They
  were not. The value was out-of-schema the entire time and produced no
  diagnostic on any of the thousands of sessions started from it.
- The misconfiguration was itself self-inflicted by the asymmetry: `--effort max`
  works, so `"effortLevel": "max"` was assumed to.
- It was compounded by a second-order effect worth noting for anyone building on
  this: two independent processes on that machine both wrote `effortLevel` — one
  asserting `xhigh`, one asserting the invalid `max` — and **rewrote the same
  settings file 30–70 times a day for 27 days** without either noticing the
  other, because the invalid write produced no error and therefore no signal that
  anything was contested.

## 6. Impact

No data corruption. The cost is **wasted intent and a month of misplaced
confidence** — every downstream decision that assumed a top-tier session was
reasoning from a false premise, and no telemetry anywhere contradicted it.

## 7. Proposed eval / check

1. For each settings key with an enum, assert that an out-of-enum value produces
   a diagnostic on stderr naming file, key, value, and accepted set.
2. Assert `/doctor` lists any settings entry that failed to parse.
3. A schema-consistency test: for any setting whose value space is also
   expressible as a CLI flag, assert the two enums are equal, or that the
   difference is explicitly registered in an allow-list with a reason. This is
   the check that would have caught the `max` divergence at build time.

## 8. Workaround shipped

The value now lives in **one** registry key read by both writers, and the writer
that previously wrote `max` was changed to **refuse any value the CLI cannot
persist** — validating against the CLI's own enum rather than against its
author's assumption. A 15-minute integrity check asserts the persisted value
matches the registry.

That is a reasonable fix for one operator. It does not generalize: every other
user of this setting is still one plausible typo away from a month of silently
ignored configuration.
