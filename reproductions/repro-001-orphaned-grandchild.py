#!/usr/bin/env python3
"""repro-001 — a timed-out subprocess kills the direct child, not the tree.

This is the minimal, tool-independent shape of SPEC-001. It uses `sleep` as a
stand-in for a Claude Code MCP-server child so the reproduction is safe,
offline, costs nothing, and does not require a Claude Code install or a
credential.

WHAT IT SHOWS
  Phase A (what the default does): `subprocess.run(argv, timeout=T)` raises
    TimeoutExpired and kills only the process it spawned. A grandchild that
    process spawned is reparented to init/launchd (ppid == 1) and survives
    forever. This is exactly what `claude -p` + its MCP servers do under a
    caller-side timeout, or when the OS kills the parent under memory pressure.

  Phase B (what the fix does): the same call with `start_new_session=True`
    makes the child a process-group leader, so `os.killpg(pid, SIGKILL)`
    reaches every descendant. The grandchild dies with its parent.

SAFETY
  * Every process it creates carries a unique marker string in its argv, and a
    `finally:` sweep SIGKILLs anything still carrying that marker before exit,
    on every path including Ctrl-C. It cannot leave a process behind.
  * The stand-in processes sleep for 60s max, so even a catastrophic failure of
    the sweep self-limits.
  * It never signals anything it did not itself spawn: the marker contains this
    process's own pid and a random token.

USAGE
    python3 repro-001-orphaned-grandchild.py

EXIT
    0  both phases behaved as documented (leak in A, no leak in B)
    1  behavior differed from the spec (print says how)
"""
from __future__ import annotations

import os
import secrets
import signal
import subprocess
import sys
import time

MARK = f"CCBS001-{os.getpid()}-{secrets.token_hex(4)}"

# sh -c: spawn a marked grandchild in the background, then block. The `: <MARK>`
# no-op keeps the marker in each process's own argv so `ps` can find it — do NOT
# add `exec`, which would replace the marked shell with a bare `sleep` and make
# the leak invisible to the sweep (i.e. unkillable by this script).
CHILD_SCRIPT = (
    f"/bin/sh -c ': {MARK}-grandchild ; sleep 60' & "
    f": {MARK}-child ; sleep 60"
)
ARGV = ["/bin/sh", "-c", CHILD_SCRIPT]


def marked_pids() -> list[int]:
    """Every live pid whose argv carries our marker. Read-only."""
    out = subprocess.run(["/bin/ps", "-Ao", "pid=,command="],
                         capture_output=True, text=True).stdout
    pids = []
    for line in out.splitlines():
        line = line.strip()
        if MARK in line and "ps -Ao" not in line:
            head = line.split(None, 1)[0]
            if head.isdigit():
                pids.append(int(head))
    return pids


def ppid_of(pid: int) -> int | None:
    out = subprocess.run(["/bin/ps", "-o", "ppid=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else None


def sweep(label: str) -> int:
    """SIGKILL anything still carrying our marker. Returns how many."""
    killed = 0
    for pid in marked_pids():
        try:
            os.kill(pid, signal.SIGKILL)
            killed += 1
        except (ProcessLookupError, PermissionError):
            pass
    if killed:
        print(f"    [cleanup:{label}] reaped {killed} marked process(es)")
    return killed


def phase_a() -> bool:
    """Default subprocess.run(timeout=) — expect the grandchild to survive."""
    print("PHASE A  subprocess.run(argv, timeout=2)   [the default]")
    proc = subprocess.Popen(ARGV, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()          # exactly what subprocess.run(timeout=) does
        proc.wait()
    time.sleep(0.7)          # let the reparent land

    survivors = marked_pids()
    orphans = [p for p in survivors if ppid_of(p) == 1]
    print(f"    parent pid {proc.pid} killed; {len(survivors)} marked "
          f"process(es) still alive, {len(orphans)} of them reparented to pid 1")
    for p in orphans:
        print(f"      orphan pid={p} ppid=1   <- would live forever")
    leaked = len(orphans) > 0
    print("    => LEAK REPRODUCED" if leaked else "    => no leak (unexpected)")
    sweep("A")
    return leaked


def phase_b() -> bool:
    """start_new_session=True + killpg — expect no survivors."""
    print("PHASE B  Popen(..., start_new_session=True) + os.killpg   [the fix]")
    proc = subprocess.Popen(ARGV, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)   # the whole group, not one pid
        except ProcessLookupError:
            pass
        proc.wait()
    time.sleep(0.7)

    survivors = marked_pids()
    print(f"    parent group {proc.pid} killed; {len(survivors)} marked "
          f"process(es) still alive")
    clean = not survivors
    print("    => NO LEAK" if clean else "    => LEAKED (unexpected)")
    sweep("B")
    return clean


def main() -> int:
    print(f"repro-001  marker={MARK}")
    print("stand-in for `claude -p` + its MCP-server children; no Claude Code "
          "install, credential, or network needed.\n")
    try:
        leaked = phase_a()
        print()
        clean = phase_b()
    finally:
        sweep("final")

    print()
    if leaked and clean:
        print("RESULT: matches SPEC-001. The default orphans the grandchild; "
              "the process-group form does not.")
        return 0
    print("RESULT: behavior differed from SPEC-001 — see the phase output above.")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sweep("interrupt")
        sys.exit(130)
