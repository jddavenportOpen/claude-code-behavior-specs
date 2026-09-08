# SPEC-001 — A headless invocation must not orphan its MCP-server children

| | |
|---|---|
| **Area** | Process lifecycle · MCP |
| **Severity** | High — unbounded resource leak, machine-fatal at scale |
| **First observed** | 2026-09-06 |
| **Reproduced** | 2026-09-08, offline, tool-independent |
| **Affects** | Every non-interactive `claude -p` / `claude --print` caller with stdio MCP servers configured |

## 1. Summary

`claude -p` spawns MCP-server child processes. When the `claude` process itself
dies **without a clean exit** — killed by a caller's `subprocess.run(timeout=)`,
by `SIGKILL`, or by the OS's memory manager — those children are reparented to
PID 1 and run forever. They keep their full resident memory and are never
reaped.

At any meaningful call volume this is not a leak, it is a **positive feedback
loop**: memory pressure makes the OS kill parents → each kill produces more
permanent orphans → pressure rises → more kills. On the machine described below
that loop ended in seven kernel panics in three days, with the interval between
them collapsing from 55 hours to 19 minutes.

The trap is that the caller looks correct. `subprocess.run(cmd, timeout=T)` is
the textbook way to bound a subprocess, and it does exactly what its
documentation says: it kills the process it started. It is wrong here only
because `claude` leaves descendants that outlive it. **A tool that spawns
unmanaged grandchildren makes every naive caller wrong**, and there is nothing
in the CLI's output, docs, or exit behavior that tells the caller so.

## 2. Observed behavior

1. A headless `claude` invocation spawns one child process per configured stdio
   MCP server.
2. Those children are in the **caller's** process group, not a group `claude`
   owns.
3. If `claude` exits cleanly, it appears to shut them down.
4. If `claude` dies any other way — `SIGKILL` from a timeout, an OS memory kill
   — the children are **not** signalled. They are reparented to PID 1 and
   continue running with their full RSS, indefinitely.
5. There is no way for the caller to clean up after the fact: the CLI never
   discloses its children's PIDs, on any output format.
6. A second, easily-missed case: **a clean exit is not sufficient either.** A
   parent process that exits normally does not reap its own grandchildren. Any
   supervisor that relies on "the parent finished, so the tree is gone" is
   wrong.

## 3. Expected behavior

**A headless invocation must not be able to outlive itself.** Concretely, in
descending order of value:

1. **Each stdio MCP server should exit when its stdin closes.** This is the
   portable, robust fix and it needs no cooperation from the caller: when the
   parent dies for any reason including `SIGKILL`, the pipe closes, and a
   correctly-written stdio server sees EOF and exits. This belongs in the MCP
   server template and the SDK's default server loop, not only in the CLI.
2. **`claude` should own a process group / job object containing its children**,
   so that a single `killpg` from a supervisor reaches the whole tree. Today a
   caller cannot do this safely because the children share the caller's group —
   `killpg` on that group would kill the caller.
3. **A parent-death watch as defence in depth** — `PR_SET_PDEATHSIG` on Linux,
   a `kqueue` `EVFILT_PROC`/`NOTE_EXIT` watch on macOS. This covers a child that
   holds stdin open for its own reasons.
4. **Failing all of the above, disclose the PIDs.** If the CLI emitted its MCP
   child PIDs in the `--output-format json` envelope, a caller could at least
   clean up. Today the leak is not merely unmanaged, it is invisible.

The line to draw: **the CLI's process tree is the CLI's responsibility.** A
caller should be able to `SIGKILL` a headless invocation — the one signal that
cannot be caught, and the one the OS itself uses — and be left with nothing.

## 4. Minimal reproduction

[`reproductions/repro-001-orphaned-grandchild.py`](reproductions/repro-001-orphaned-grandchild.py)
— offline, ~6 seconds, needs no Claude Code install, credential, or network. It
uses `sleep` as the stand-in for an MCP child so the reproduction is safe and
free, and it guarantees its own cleanup (every process it creates carries a
unique marker; a `finally:` sweep kills anything still carrying it, on every
path including `Ctrl-C`).

```
$ python3 repro-001-orphaned-grandchild.py
repro-001  marker=CCBS001-90244-1ffb977f

PHASE A  subprocess.run(argv, timeout=2)   [the default]
    parent pid 90302 killed; 1 marked process(es) still alive, 1 of them reparented to pid 1
      orphan pid=90306 ppid=1   <- would live forever
    => LEAK REPRODUCED
    [cleanup:A] reaped 1 marked process(es)

PHASE B  Popen(..., start_new_session=True) + os.killpg   [the fix]
    parent group 94437 killed; 0 marked process(es) still alive
    => NO LEAK

RESULT: matches SPEC-001. The default orphans the grandchild; the process-group
form does not.
```

**To see it with the real tool** (costs one trivial call): configure at least
one stdio MCP server, run `claude -p 'hello' &`, note the PID, `kill -9` it
after the MCP servers have started, then
`ps -Ao pid=,ppid=,command= | awk '$2==1'` and look for the server processes.

## 5. Evidence

### 5.1 Re-measured for this document (2026-09-08)

- **The orphan mechanism itself** — reproduced above, deterministically, in
  isolation from Claude Code.
- **Prevalence of the caller-side shape in one codebase.** After the shared fix
  landed, an AST lint over that estate's `agents/`, `scripts/` and `bridge/`
  trees still finds **23 call sites across 21 files** that spawn `claude` as a
  subprocess without putting it in its own process group. That is the residue in
  a single repository, written by one author, *after* the bug was understood and
  a drop-in replacement existed. The natural rate at which this shape gets
  written is high, because it is the correct shape for every other subprocess.

### 5.2 Recorded during the incident

From an incident audit written 2026-09-08 covering panics #2–#7 (panic #1 was
audited separately on 2026-09-06). Machine: Apple M3 Max, 36 GB unified memory,
macOS 26.6.2.

- **Seven kernel panics, 2026-09-06 → 2026-09-08.** Uptime before each: 55.3 h,
  21.6 h, 2.1 h, 3.5 h, **0.31 h**, 0.72 h, 8.1 h. The interval collapses and
  then partially recovers — a race between how fast pressure rebuilds and how
  long the box survives, which is the signature of a feedback loop rather than a
  single hog.
- **Identical panic string on all seven:** `watchdog timeout: no checkins from
  watchdogd in 90–94 seconds`, with
  `Compressor Info: 4X% of compressed pages limit (OK) and 100% of segments
  limit (BAD)`.
- **A jetsam event 7 minutes before panic #4:** 94 MB free, 12.99 GiB held in
  the VM compressor, **1,953 processes jettisoned** across 51 jetsam
  generations. The prefs daemon `cfprefsd` was killed three times — the system
  was well past any healthy equilibrium.
- **Fixing one call site did not stop it.** The first process-group fix landed
  in a single caller at 21:09 on 2026-09-07, four minutes after that evening's
  panic. The machine panicked again 8 hours later, because the shared client and
  ~20 other call sites had the same shape. The fix has to be in the tool or in a
  shared rail; per-caller fixes do not converge.
- **~2,210 orphaned processes holding 88.30 GB** — this figure was recorded by
  the incident responder and appears in three independent artifacts written
  during the response (the shared fix module's rationale, the reaper script's
  header, and the lint's docstring). ⚠️ **The raw process census that produced it
  was not preserved**, so unlike everything else in this section it cannot be
  re-derived. It is reported here because it is the responder's contemporaneous
  measurement and it is consistent with the panic-time compressor state, not
  because it was independently verified.

### 5.3 A monitoring finding that explains why nobody caught it

**Free RAM and swap usage look fine right into the collapse.** Compressed pages
leave a process's RSS, so a dashboard watching free memory, swap %, or top-RSS
sees a healthy machine while the compressor's *segment table* fills. Of the
available signals, only compressor segment percentage predicted the panics — and
the panic logs show it pinned at `100% of segments limit (BAD)` while the
adjacent pages counter still read a reassuring `44% (OK)`.

This matters for the spec because it is why the leak ran for days: the standard
memory metrics are blind to it.

### 5.4 Prior art

`anthropics/claude-code#68647` — orphaned child processes exhausting RAM and
triggering a watchdog panic — was cited in the incident audit as an existing
public report of the same class. Referenced here for triage convenience; **not
independently verified in this document.**

## 6. Impact

- **Seven machine-fatal outages in 72 hours**, each an unclean shutdown. Every
  panic also forced a full Spotlight re-index on the next boot, which is itself a
  multi-hour multi-GB memory draw — so each outage made the next one arrive
  sooner. That amplifier is the reason the interval collapsed to 19 minutes.
- **All work in flight at each panic was lost**, across ~30 concurrent sessions.
- The blast radius is not proportional to the leaking caller. One misbehaving
  pipeline takes down every unrelated agent, session and daemon on the machine.

## 7. Proposed eval / check

A regression suite for this should assert:

1. **Kill-tree contract.** Start `claude -p` with ≥1 stdio MCP server. Once the
   server has started, `SIGKILL` the `claude` PID. Assert that within 5 s no
   descendant survives with `ppid == 1`. Run the same test with `SIGTERM` and
   with a caller-side `subprocess.run(timeout=)`.
2. **Clean-exit contract.** Run a `claude -p` to normal completion. Assert the
   process count returns to the pre-invocation baseline — specifically that no
   MCP server survives the parent's clean exit.
3. **OOM-shaped kill.** Same as (1) but with the parent killed by an external
   supervisor while mid-turn, to cover the memory-manager path rather than only
   the caller path.
4. **Soak.** 500 headless invocations, half killed mid-flight at random. Assert
   final process count ≤ baseline + small constant, and final RSS returns to
   baseline. This is the test that would have caught it: no single-invocation
   test can see a leak whose harm is cumulative.
5. **Disclosure.** If the fix is not full lifecycle ownership, assert that
   `--output-format json` includes the MCP child PIDs so a caller can implement
   its own reaper.

Add to the MCP server conformance suite: **a stdio server must exit within N
seconds of stdin reaching EOF.** That single assertion, enforced on the server
template, closes the class regardless of what the CLI does.

## 8. Workaround shipped

Four layers, because no single one was sufficient:

1. **A shared spawn rail.** A drop-in replacement for `subprocess.run` /
   `Popen` that forces `start_new_session=True` (making the child a process-group
   leader) and `killpg`s the whole group on timeout, on any exception, **and
   after a clean exit**. It refuses to `killpg` a process it cannot prove is a
   group leader, because `killpg` on a non-leader targets whichever group holds
   that ID — for a plain `Popen`, the caller's own.
2. **An AST lint** that flags any `subprocess.run/Popen/call/check_call/
   check_output` whose argument source mentions `claude` and which does not pass
   `start_new_session=True`. Scoped to the files in a given diff, so pre-existing
   debt does not block unrelated work but touching a leaky file converts it.
3. **An independent orphan reaper** on a 30-second timer that kills
   `ppid == 1` processes matching known agent-spawned shapes, gated on
   compressor segment percentage. Deliberately ignorant of *who* leaked — it is
   a ceiling, not a fix.
4. **A 5-second compressor circuit breaker**, because the ramp from 10 % to 55 %
   segments was measured at 89 seconds — faster than a 30-second cadence can
   reliably step into.

**The shape of that workaround is the argument for the spec.** Four layers of
defence, an AST lint, and a kernel-metric circuit breaker are what it took to
make a documented, ordinary way of calling a subprocess safe.
