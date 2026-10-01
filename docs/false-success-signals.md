# False success signals — four measured instances of one shape

A check that cannot fail is not a check. This file records the specific way that happened here
**four times in one session**, because each instance looked different and the shape only became
obvious after the fourth.

**The shape: a success signal the system did not produce.**

In every case something printed, exited zero, or read as confirmation — and in every case the thing
that produced it was not the system being tested. The failure is invisible by construction: there is
nothing to notice, because the signal says it worked.

## The four

| # | What was trusted | Why it was not evidence |
|---|---|---|
| 1 | `--help` exiting zero as proof an MCP server works | `arxiv-mcp-server` has no `--help`; it goes straight to stdio listening, so it **hangs** (exit 124, zero bytes). Piped through `sed`, `$?` reported the *pipeline's* exit code, not the timeout's |
| 2 | `cmd && echo "<success>"` after a `gh` mutation | `gh issue edit --remove-label` succeeds **silently on a no-op**. The echo printed whether or not anything changed — so a state change was asserted from a string written by the asserter |
| 3 | A commit message disclaiming a fix | `Does NOT claim to fix #683's root cause` — GitHub matched `fix #683` and closed the issue. The **negation is invisible to the keyword scanner**; the sentence written to disclaim the change performed it |
| 4 | `PIPESTATUS` for a `nix flake check` exit code | An intervening `echo` had already clobbered it, so the reported code belonged to the echo |

Instances 1, 2 and 3 were this session's main agent; 4 was a peer session. The split matters only
because it shows the shape is not one person's habit.

## The rule

> **If the claim matters, the next read is the evidence.**

Not the exit code of a pipeline, not a message you wrote yourself, not the absence of an error. Run
the query that observes the *state*, and quote what it returned.

Concretely, for the four above:

| Instead of | Read |
|---|---|
| `--help` exits zero | a real protocol handshake — `initialize` over stdio, and check `serverInfo` comes back |
| `gh … && echo "done"` | re-query the object: `gh issue view N --json labels` |
| "the body says it does not close it" | `closingIssuesReferences` **and** the body as a commit message — see [`auto-merge-and-merge-queue.md`](auto-merge-and-merge-queue.md), a squash merge closes on the commit text, not the PR link |
| `${PIPESTATUS[0]}` after other commands | capture it into a variable on the same line, or avoid the pipeline |

## The corollary that costs the most to learn

**A gate only ever seen green is not known to gate.** Three checks were added this session and each
was proven to *fail* before being trusted:

- `checks.<system>.actionlint` — injected `ls $BAD` into a real `run:` block, confirmed SC2086 failed
  the build, reverted to a zero diff
- the `claude-plugins` always-on assertion — renamed a member to a nonexistent plugin, confirmed the
  build failed naming it
- `claude-state-gc` — ran the dry run and confirmed the cache was **byte-identical** afterwards, then
  confirmed 0 of 38 live plugin versions were flagged for deletion

In each case the negative control was cheap and the positive result alone would have proved nothing.
The same logic applies to a guard inherited from someone else: if you cannot say how it fails, you do
not know that it does.

## Why `nix build`, not `nix eval`, for a fail-closed guard

`nix eval` can hide a `throw`. A guard verified by eval is not known to fire. This is recorded
separately in the repo's own memory of the incident; it belongs here too because it is the same
question — *what would failure look like, and did I actually observe it?*
