---
name: detached-launch-and-process-proof
description: macOS has NO setsid, and `pgrep -f <pattern>` matches your own monitor shell — both produced a false "process is up" on 2026-10-06. Use nohup+disown and `pgrep -x`
metadata:
  type: feedback
---

Two instrument failures hit in one task (2026-10-06) while launching `nix run .#nixvm`
detached. Both exit 0 having measured nothing.

| Trap | What happened | Use instead |
|---|---|---|
| `setsid nohup <cmd> &` | **macOS ships no `setsid`** — the script died with `setsid: command not found`, and the reported `pid=$!` was the dead subshell. Nothing ever launched. | `nohup <cmd> >log 2>&1 </dev/null & disown` — then `kill -0 "$PID"` a few seconds later to prove it survived |
| `until pgrep -f 'qemu-system-aarch64'; do sleep; done` | The loop's **own shell command line contains the pattern**, so `pgrep -f` matched itself and printed "QEMU UP" with no VM running. | `pgrep -x <procname>` (exact process name), or `pgrep -f '/bin/<name>'` with a path anchor |

**Why:** `-f` matches the full command line of *every* process, including the monitoring
one. A self-match is indistinguishable from a hit. And `$!` is set by the shell regardless
of whether the command it launched exists.

**A PID handed down in a brief is a claim, not a fact.** 2026-10-06, a later task: the brief
stated "nixvm QEMU is LIVE (PID 148), the operator is working in it" and told me to protect
it. `kill -0 148` returned `no such process`, and `pgrep -x qemu-system-aarch64` found only
the Android emulator I had just started. The VM had exited between tasks. **Re-verify any
inherited PID before reasoning about it** — and never signal a PID you only have on
authority. (The protective instruction was still right in shape: `pgrep -x
qemu-system-aarch64` genuinely cannot tell the Android emulator from nixvm, since the
emulator's binary is `.../android-commandlinetools/emulator/qemu/darwin-aarch64/qemu-system-aarch64`.
`adb devices` distinguishes them; a bare process name does not.)

**How to apply:** after any detached launch, prove liveness with a **differently shaped**
instrument than the one that started it — `pgrep -x` plus
`ps -ww -o command= -p <pid>` to confirm the expected *arguments* are on the live process,
not just that something is running. For a long `nix run .#nixvm` in particular, expect
minutes of `Creating Nix store image...` before QEMU appears at all; the runner `exec`s
into `qemu-system-aarch64`, so the PID does not change.
