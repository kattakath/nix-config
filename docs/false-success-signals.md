# False success signals — six measured instances of two shapes

A check that cannot fail is not a check. This file records the specific way that happened here
**six times in one session**, because each instance looked different and the shape only became
obvious after the fourth. Instances 5 and 6 then showed it has a **second half** that is harder to
see than the first.

**Shape A — a success signal the system did not produce.** (Instances 1-4.)
**Shape B — a FALSE ABSENCE: the thing you looked for was not there, and you concluded it does not
exist.** (Instances 5-6.) Shape A hands you a confirmation you should not trust; shape B hands you
nothing at all, and nothing reads exactly like "fine".

Under shape A something printed, exited zero, or read as confirmation, and the thing that produced it
was not the system being tested. Under shape B nothing was produced at all. Either way the failure is
invisible by construction: there is nothing to notice, because the signal says it worked — or because
there is no signal, and no signal is indistinguishable from a quiet success.

## The four

| # | What was trusted | Why it was not evidence |
|---|---|---|
| 1 | `--help` exiting zero as proof an MCP server works | `arxiv-mcp-server` has no `--help`; it goes straight to stdio listening, so it **hangs** (exit 124, zero bytes). Piped through `sed`, `$?` reported the *pipeline's* exit code, not the timeout's |
| 2 | `cmd && echo "<success>"` after a `gh` mutation | `gh issue edit --remove-label` succeeds **silently on a no-op**. The echo printed whether or not anything changed — so a state change was asserted from a string written by the asserter |
| 3 | A commit message disclaiming a fix | `Does NOT claim to fix #683's root cause` — GitHub matched `fix #683` and closed the issue. The **negation is invisible to the keyword scanner**; the sentence written to disclaim the change performed it |
| 4 | `PIPESTATUS` for a `nix flake check` exit code | An intervening `echo` had already clobbered it, so the reported code belonged to the echo |

Instances 1, 2 and 3 were this session's main agent; 4 was a peer session. The split matters only
because it shows the shape is not one person's habit.

## The two of shape B — a false ABSENCE

| # | What was concluded | Why the absence was not evidence |
|---|---|---|
| 5 | `ls docs/false-success-signals.md` → *No such file*, therefore **this file does not exist** | It existed, on `main`, merged as #715 and indexed in `repo-map.md`. The `ls` ran in a **worktree branched before that merge**, and the confirming `git log -1 -- <path>` was scoped to the same stale tree, so it agreed. A working tree is not the repo |
| 6 | `build-installers` CI looked clean, therefore the SD image was being republished | **Ten consecutive `startup_failure` runs.** A startup failure creates **no job**, so it runs no check, writes no log, and `gh run view` offers only "likely a workflow file issue". `installer-latest` silently stopped being refreshed for ~10 h while every PR stayed green |

Instance 5 was a peer session; 6 was this session's main agent — and 6 was caused by **#697, whose
own evidence was sound about the wrong half**: the attestation gate was confirmed *present in the
built script* and shellcheck accepted it. Both true, both about the **consuming** side. Nothing
exercised the **publishing** side, where the break was.

The cure for shape B is the mirror of the rule below: **name where the absence would have to show up,
and read THAT**, rather than reading somewhere it merely could.

| Instead of | Read |
|---|---|
| `ls <path>` / `git log -- <path>` in your checkout | `git ls-tree origin/main <path>` — the branch you are actually claiming about |
| "CI is green, so the job ran" | the run list's **conclusion** per run (`gh run list --workflow=X`), since a `startup_failure` is absent from the checks a PR shows |
| "the artifact publishes on every merge" | the artifact's own `updatedAt` on the release |

## The rule

> **If the claim matters, the next read is the evidence.**

Not the exit code of a pipeline, not a message you wrote yourself, not the absence of an error. Run
the query that observes the *state*, and quote what it returned.

For shape B the same rule reads: **silence is not a measurement.** A thing that never emitted a
failure may never have run, and a file missing from your tree may only be missing from your tree.

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

## Instance 3 RECURRED — and the "just backtick it" cure is UNPROVEN

The PR that documented instance 3 **reproduced it while describing it**. Because the example has to
appear verbatim, the one document most likely to contain a live closing keyword is the one explaining
that closing keywords fire.

Measured on `#683`, whose timeline carries two bot closures and two manual reopens:

| Squash commit | How the example appeared | Closed the issue? |
|---|---|---|
| `83629cf` (#713) | `Does NOT claim to fix` + the number — negated, unquoted | **YES** — 12:53:18Z |
| `7362596` (#714) | the same sentence in **plain double quotes** | **YES** — 13:10:42Z |
| `361091c` (#697) | an ordinary unquoted `Closes` + number, meant to close | **YES** — as intended |

And the two forms that did **not** fire — which is what makes the safe rule measured rather than
merely reasoned:

| Evidence | Form | Result |
|---|---|---|
| `847f86b8` (#720) | the reference **omitted entirely** | **no close** — zero matches for the number anywhere in its commit message |
| #697's body + `361091c` | `…carried a closing keyword for issue 674` — **no `#`, and the verb not adjacent** | **no link, no close.** Its `closingIssuesReferences` is `[682]` alone; 674 was closed 20 minutes earlier **by a person, with no commit attached** |

So three things are measured and settled:

> **Negation does not suppress. Plain double quotes do not suppress. Dropping the `#` and keeping
> the verb away from the number does.**

### A confounder, so the archive is not read backwards

That same #697 line records an earlier case: *"#687 carried a closing keyword for issue 674, was
bot-merged, and that issue **stayed open**"*. That is **not** evidence that closing keywords are
unreliable, and reading it that way would invert the whole table. It predates the shared App being
granted `Issues: Write` — before that grant a bot merge could not close anything, which is the
subject of the auto-close investigation in
[`auto-merge-and-merge-queue.md`](auto-merge-and-merge-queue.md). Both #683 closures happened
**after** the grant. So the rows above are measured in the post-grant world, and any non-closure
from before it says nothing about phrasing.

### What is NOT established, and why saying so matters here

A natural next move is "put the reference in backticks". **This file does not have evidence for
that**, and the near-miss is worth recording:

- The third doc PR (`847f86b8`, #720) closed nothing — but its commit message **does not mention the
  issue at all**. It is evidence that *omitting* the reference works, **not** that backticking does.
  Reaching for it as a positive control would have been this file's own shape: a confirmation that
  proves something adjacent to the claim.
- A **commit message is not markdown.** GitHub renders code spans in issue and PR *bodies*, where a
  backticked reference plausibly is skipped; a squash commit message is plain text, so there is no
  reason to assume the scanner treats backticks as anything but characters.

Treat backticks in a **body** as plausible-but-unverified, and in a **commit message** as no
protection at all until someone measures it against a throwaway issue.

### The form that IS safe, because it needs no scanner behaviour

**Keep the verb away from the number.** Write "the `#683` example", or "the negated-keyword case",
or put the number on a different line from the verb. That works regardless of what the scanner
does, which is the only property worth relying on.

### The pre-merge check reports nothing

`closingIssuesReferences` was **empty on all three PRs** — 0 even on the two that closed the issue.
The signal exists only in the squash commit message, which GitHub assembles at merge time, so the
PR's own link list has nothing to show beforehand. See
[`auto-merge-and-merge-queue.md`](auto-merge-and-merge-queue.md).

### Why prose is the wrong guard

Instance 3 was documented, and the very next document about it fired again. The mechanical form,
for whoever wants it:

```
(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+
```

grepped against a prospective commit message or PR body and refused unless the verb and number are
separated. That would have caught **both** instances; this repo already has the place for it (the
`PreToolUse` Bash guard, whose test suite is a required check). Not built here — recorded so the
next person does not re-derive it from two closed issues.

## The gate that structurally cannot catch instance 6

`checks.<system>.actionlint` is a real gate — it was proven to fail (see the corollary above). It
still cannot see instance 6, and the reason generalises:

```
actionlint, on the caller + called workflow exactly as they stood on main  ->  exit 0, no diagnostics
```

A called workflow may not request more permission than its caller grants; GitHub refuses the whole
run at startup rather than trimming the excess. `actionlint` lints **each file independently** and
has no cross-file caller/callee permission model, so the invariant lives in a comment at the caller
in `build-installers.yml` instead.

That is the honest limit worth recording: **some invariants span two files, and a per-file linter
cannot hold them.** When that is the case, say so where the reader is, rather than assuming the gate
has it covered.
