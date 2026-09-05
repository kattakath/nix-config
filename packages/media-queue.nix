# media-queue — the durable work queue behind the Finder Services.
#
#   media-enqueue <--video|--image> <file-or-dir>...   write jobs, return at once
#   media-worker                                       drain the queue (launchd)
#   media-queue-pause                                  freeze the in-flight job
#   media-queue-resume                                 unfreeze it
#   media-queue-status                                 what's running/queued/failed
#
# WHY A QUEUE AT ALL. Re-encoding two hundred videos is hours of ffmpeg. Doing
# that inside the Automator Service means the work dies at logout, cannot be
# paused or cancelled, reports nothing until it ends, and competes with the
# user's foreground apps for CPU. Moving it behind launchd fixes all four with
# no scheduler of our own.
#
# EVERY MECHANISM HERE IS launchd's, NOT OURS — see modules/shared/media-queue.nix:
#
#   QueueDirectories               the queue: launchd starts the worker whenever
#                                  the directory is non-empty
#   ProcessType = "Background"     the load control: the OS throttles CPU and
#                                  I/O bandwidth so a batch cannot make the Mac
#                                  feel slow
#   KeepAlive.SuccessfulExit=false the crash retry, with ThrottleInterval as the
#   + ThrottleInterval             backoff
#   RunAtLoad                      drains whatever a logout interrupted
#   StandardOutPath                the log, in the place Console.app reads
#
# What is left for this file is the part launchd has no opinion about: what a
# job IS, and what to do with one that fails.
#
# ONE FILE PER JOB, not one job per selection. It costs a process per file and
# buys everything else: progress is just the queue depth, retry and cancellation
# are per file, and one hopeless file cannot drag its neighbours down with it. A
# DIRECTORY argument stays a single job — expanding it at enqueue time would put
# a recursive walk inside the Finder click, which is the one thing enqueueing
# must never do.
#
# A FAILED JOB IS REQUEUED WITH A FRESH TIMESTAMP, not its original one. Jobs
# are picked oldest-first by the epoch in their name, so keeping the old stamp
# would hand the same failing file straight back to the worker and spin. Three
# attempts, then it moves to `failed/` — a dead-letter directory, the standard
# shape, so a permanent failure stops costing anything but stays inspectable.
#
# The worker requeues its in-flight job on SIGTERM, so a logout or a
# `launchctl kill` costs at most a repeat of one file rather than the batch.
#
# PAUSE IS SIGSTOP ON THE JOB'S PROCESS GROUP, NOT SIGTERM ON THE WORKER.
# SIGTERM is already spoken for above — it means "give this job back to the
# queue", which is right for a logout but wrong for "hold on a second": it
# throws away everything the current file (or, for `describe`, the current
# BATCH — a directory is one job) has done and restarts it from the top on
# resume. SIGSTOP instead freezes the job exactly where it is — mid-`exiftool`
# write, mid-`curl` to Ollama — and SIGCONT picks it back up from that same
# byte, no progress lost, no requeue, no fresh attempt counted against
# MAX_TRIES.
#
# `-$pid`, NEVER bare `$pid`. `set -m` in media-worker gives the backgrounded
# job its own process group (pgid == its own pid) specifically so the
# existing `kill -TERM -"$child"` in the SIGTERM path can reach grandchildren
# like fix-google-video's ffmpeg. The negative pid is what makes a signal hit
# the whole group instead of only the immediate child; pause/resume reuse that
# same convention so a stop actually freezes exiftool/curl/ffmpeg too, not
# just the shell driving them.
#
# THE WORKER LOOP PAUSES FOR FREE. `media-worker` calls `wait "$child"`, and
# POSIX `wait` only returns on termination, never on stop — so a SIGSTOPped
# job leaves the worker parked in that syscall rather than moving on to the
# next queued file. Nothing extra is needed to stop the QUEUE, only the job.
#
# FOUND VIA `running-<worker-pid>.job`, THE SAME MARKER THE WORKER USES FOR
# ITS OWN ORPHAN RECOVERY. `pgrep -P` on that pid is a DIRECT child by
# construction (the job is backgrounded once, from that exact process), so
# this can never accidentally reach into some other worker's job.
#
# KNOWN GAP: the brief window between one job finishing and the next being
# claimed has no `running-*.job` file, so a pause issued in that instant finds
# nothing to freeze and the next file starts anyway. Harmless for the case
# this exists for — pausing a long batch mid-flight — and not worth a second
# mechanism to close a race measured in milliseconds.
#
# KNOWN COST: a job frozen past Ollama's own read timeout, or past whatever a
# paused `curl` call's peer decides to give up on, resumes into a failed
# request rather than a completed one. That is not a new failure mode — the
# per-file retry/backoff loop above already exists to absorb exactly this —
# it only means a very long pause can cost the one file that was mid-caption
# when it started, not the batch.
{
  lib,
  symlinkJoin,
  writeShellApplication,
  callPackage,
  coreutils,
  findutils,
  media-toolkit ? callPackage ./media-toolkit.nix { },
}:
let
  # Spliced into all three, so the layout is stated once. INLINED rather than
  # sourced from a `writeText`: shellcheck cannot follow a `.` into /nix/store
  # (SC1091) and would then treat every shared variable as unassigned, so the
  # lint gate would have to be switched off for exactly the code most worth
  # linting. $HOME at RUNTIME — these are paths the tools read and write, not
  # Nix source paths.

  common = ''
    STATE="$HOME/Library/Application Support/nix-media-queue"
    QUEUE="$STATE/queue"
    STAGE="$STATE/staging"
    FAILED="$STATE/failed"

    # `staging` is a SIBLING of `queue`, never a dotfile inside it: launchd
    # starts the worker the moment `queue` is non-empty, so a job written in
    # place could be picked up half-written. Jobs land by rename, which is
    # atomic within a filesystem.
    ensure_dirs() {
      mkdir -p "$QUEUE" "$STAGE" "$FAILED" "$HOME/Library/Logs"
    }

    # THE STANDARD WAY TO READ LOW POWER MODE FROM A SHELL, VERIFIED ON THIS
    # MAC. Apple's real API is `ProcessInfo.isLowPowerModeEnabled` +
    # `NSProcessInfoPowerStateDidChangeNotification`, but that notification
    # is explicitly UNAVAILABLE ON MACOS (iOS-only) — so there is no
    # event-driven alternative to poll for anyway. `pmset -g`'s "Currently
    # in use" block already merges AC/battery into one live value, which is
    # why this respects Low Power Mode regardless of power source for free
    # — no separate AC/battery branch needed. Reading it needs no
    # privilege; only WRITING it (`pmset -a/-b/-c`) needs root. Fails OPEN
    # on any parse hiccup — every caller compares the result against the
    # literal string "1", so a missing/empty/unexpected value reads as "not
    # active" rather than blocking work. An optional efficiency signal must
    # never be able to wedge the whole queue. Used by media-worker (the
    # gate + watchdog) and media-queue-resume (the refusal check) — shared
    # here rather than duplicated, per this file's own "common holds what
    # more than one script needs" rule.
    lowpower_active() {
      /usr/bin/pmset -g 2>/dev/null | awk '/lowpowermode/{print $2; exit}'
    }

    # THE JOB HAS A SIBLING NOW: THE WATCHDOG. `pgrep -P "$wpid"` used to be
    # enough on its own — a worker backgrounds exactly one child, the job —
    # but the power watchdog is a second `(...)  &` subshell of the SAME
    # media-worker script, forked from the same process, so it is an
    # equally direct child. Left unfiltered, media-queue-pause/-resume/
    # -status all start treating the watchdog as if it were a second
    # running job. MEASURED the distinguishing signal: `ps -o args=` on the
    # watchdog shows the literal `.../bin/media-worker` command line
    # (identical to the worker itself, since a subshell never re-execs) —
    # the real job's args always start with `photo-describe` or
    # `fix-media`. Filtering on that basename is what `job_child_of` does,
    # shared here rather than tripled across the three callers.
    job_child_of() {
      local wpid="$1" cpid
      /usr/bin/pgrep -P "$wpid" 2>/dev/null | while IFS= read -r cpid; do
        case "$(/bin/ps -o args= -p "$cpid" 2>/dev/null)" in
          */bin/media-worker) continue ;;
          *) printf '%s\n' "$cpid" ;;
        esac
      done
    }

  '';
in
symlinkJoin {
  name = "media-queue";
  paths = [
    (writeShellApplication {
      name = "media-enqueue";
      runtimeInputs = [ coreutils ];
      text = ''
        ${common}
        prog=media-enqueue
        usage="usage: $prog <--video|--image|--describe> <file-or-directory>..."
        die() { echo "$prog: error: $*" >&2; exit 1; }

        # `--describe` is a class like the other two, not a flag on --image: it
        # ENRICHES a working file rather than repairing a broken one, and it is
        # the only class whose work needs a vision model, so an operator asking
        # to repair photos must never be made to wait on one.
        case "''${1:-}" in
          --video) class=video; shift ;;
          --image) class=image; shift ;;
          --describe) class=describe; shift ;;
          --help|-h) echo "$usage" >&2; exit 0 ;;
          *) die "$usage" ;;
        esac
        [ $# -ge 1 ] || die "$usage"

        ensure_dirs
        stamp=$(date +%s)
        n=0
        for p in "$@"; do
          # Absolute, but NOT resolved: the worker runs with a different working
          # directory, while `realpath` would also follow symlinks and rename
          # something the operator did not select.
          case "$p" in
            /*) ;;
            *) p="$PWD/$p" ;;
          esac
          n=$((n + 1))
          job="$stamp-$$-$n.t1.job"
          printf '%s\0' "$class" "$p" > "$STAGE/$job"
          mv "$STAGE/$job" "$QUEUE/$job"
        done

        # Ask launchd to run the worker NOW. QueueDirectories gets there on its
        # own, but only after ThrottleInterval, which spaces every start of the
        # job rather than only its respawns — measured, a right-click waited a
        # full minute at 60s. `kickstart` is launchd's own "run this now", so the
        # fast path is still launchd's mechanism rather than a private one.
        # Failure is ignored deliberately: the CLI must work where the agent is
        # not installed, and the directory watch is the fallback either way.
        /bin/launchctl kickstart "gui/$(id -u)/org.nix-community.home.media-queue" \
          >/dev/null 2>&1 || true
      '';
    })

    (writeShellApplication {
      name = "media-worker";
      runtimeInputs = [
        coreutils
        findutils
        media-toolkit
      ];
      text = ''
        ${common}
        ensure_dirs

        # The prelude holds only what ALL THREE scripts use; anything narrower
        # lives with its user, because an unused variable is a lint failure —
        # and rightly so, since it is usually a leftover.
        LOCK="$STATE/worker.lock"
        MAX_TRIES=3
        # How often the in-flight-job watchdog re-checks Low Power Mode.
        # Cheap either way — one `pmset -g` call is sub-10ms — so this is
        # about responsiveness, not overhead. 20s catches a toggle quickly
        # without adding a meaningful wake-up burden of its own.
        POWER_POLL_INTERVAL=20

        log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

        # THE LOCK IS THE KERNEL'S, NOT OURS. `/usr/bin/lockf` ships with macOS and
        # takes a `flock(2)` lock, which the kernel releases when the holder dies
        # — INCLUDING on SIGKILL, where no trap can run. That makes a stale lock
        # structurally impossible, so the whole hand-written mutex this replaces
        # (mkdir + a pid file + a `kill -0` liveness probe + a "breaking stale
        # lock" branch) has nothing left to do.
        #
        # That code was not merely redundant, it was a reimplementation of a
        # DEPRECATED Apple utility: /usr/bin/shlock does link(2)+PID-liveness,
        # exactly the same algorithm, and its own man page points at lockf.
        #
        # `-t 0` means fail immediately rather than wait, and lockf then exits 75
        # (EX_TEMPFAIL) — measured. Any other status is the worker's own, passed
        # through untouched, so launchd's KeepAlive still sees real failures.
        #
        # Re-exec rather than wrap: the lock must cover this whole script, and the
        # env guard is what stops the re-exec recursing.
        if [ -d "$LOCK" ]; then
          # Migration: the previous implementation made $LOCK a DIRECTORY, and
          # lockf cannot take a lock on one. Left in place it would break every
          # worker start on the first activation after this change.
          rm -rf "$LOCK"
        fi
        if [ -z "''${MEDIA_QUEUE_LOCK_HELD:-}" ]; then
          export MEDIA_QUEUE_LOCK_HELD=1
          lock_rc=0
          /usr/bin/lockf -t 0 -k "$LOCK" "$0" "$@" || lock_rc=$?
          if [ "$lock_rc" -eq 75 ]; then
            log "another worker holds the lock — exiting"
            exit 0
          fi
          exit "$lock_rc"
        fi

        # Same reasoning one level down: a job the previous worker was holding
        # when it was killed is still sitting in `running-<pid>.job`. If that pid
        # is gone, the job is ours to put back.
        for orphan in "$STATE"/running-*.job; do
          [ -e "$orphan" ] || continue
          opid=''${orphan##*/running-}
          opid=''${opid%%.job}
          if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then
            continue
          fi
          log "recovering orphaned job from pid $opid"
          mv "$orphan" "$QUEUE/$(date +%s)-recovered-$opid.t1.job" 2>/dev/null || true
        done

        # And one level further: a job waiting out a retry backoff lives in
        # staging/, which launchd does NOT watch, and the timer that moves it back
        # is a backgrounded sleep. If that sleep dies — logout, reboot, launchd
        # reaping the process group — the job is stranded where nothing will ever
        # look at it again. Any retry job already older than a generous ceiling is
        # therefore reclaimed on the next worker start, which is the one moment we
        # know a worker exists to do it.
        for held in "$STAGE"/*-retry.t*.job; do
          [ -e "$held" ] || continue
          if [ -n "$(find "$held" -mmin +2 2>/dev/null)" ]; then
            log "reclaiming stranded retry job $(basename "$held")"
            mv "$held" "$QUEUE/$(date +%s)-reclaimed.t$MAX_TRIES.job" 2>/dev/null || true
          fi
        done

        running=""
        child=""
        watchdog=""
        power_marker=""
        cleanup() {
          # The watchdog first, before the encode: it also sends signals to
          # `$child`, and killing it late could race a STOP/CONT against the
          # TERM below. It self-terminates within one poll interval anyway
          # (its own `kill -0 "$child"` check fails once the child is gone),
          # but a logout shouldn't leave even a short-lived loop dangling.
          [ -n "$watchdog" ] && kill "$watchdog" 2>/dev/null || true
          [ -n "$power_marker" ] && rm -f "$power_marker"
          # Kill the encode FIRST. Without this the trap would not even run until
          # ffmpeg finished on its own, and launchd escalates SIGTERM to SIGKILL
          # long before a two-hour batch is done.
          # The whole PROCESS GROUP, not just the child: fix-media's own ffmpeg is
          # a GRANDchild, and killing only the middle process orphans an encode
          # that keeps burning CPU and leaves its temp file behind. `set -m`
          # below puts each job in its own group so the negative pid reaches all
          # of it — including fix-google-video, whose trap then removes the
          # partial encode.
          [ -n "$child" ] && kill -TERM -"$child" 2>/dev/null || true
          # An interrupted job goes BACK to the queue rather than being lost: a
          # logout mid-batch should cost one repeated file, not the batch.
          if [ -n "$running" ] && [ -f "$running" ]; then
            mv "$running" "$QUEUE/$(date +%s)-requeued-$$.t1.job" 2>/dev/null || true
          fi
          # The lock is NOT released here. It is a flock(2) held by the lockf
          # parent, and the kernel drops it when that process exits — which it
          # does whether we got here by a clean exit, a trap, or a SIGKILL that
          # never ran this function at all. Deleting the lock FILE here would be
          # worse than useless: it would unlink a path another worker may already
          # have opened, handing two workers a lock on two different inodes.
        }
        trap cleanup EXIT
        trap 'cleanup; exit 143' INT TERM

        changed=0
        skipped=0
        failures=0
        jobs=0
        reason=

        while :; do
          # NO `| head` HERE. Under `pipefail`, `head -1` exits after its line,
          # `sort` takes SIGPIPE, and the pipeline returns 141 — which errexit
          # turns into a dead worker. It only bites once the listing exceeds the
          # 64 KB pipe buffer, so it is invisible in testing and appears in
          # production: measured with 761 jobs queued, the worker drained 1-3 of
          # them per launch instead of the whole queue, and launchd paid a
          # restart between each. Taking the first line by parameter expansion
          # keeps `sort` writing to a variable, where it can finish and exit 0.
          job=$(find "$QUEUE" -maxdepth 1 -name '*.job' -type f 2>/dev/null | sort)
          job=''${job%%$'\n'*}
          [ -n "$job" ] || break

          base=''${job##*/}
          tries=''${base##*.t}
          tries=''${tries%%.job}
          case "$tries" in
            ""|*[!0-9]*) tries=1 ;;   # "" for the empty pattern: a bare shell
                                     # two-quote is unlexable in a Nix
                                     # indented string.
          esac

          # The pid is IN THE NAME so the next worker can tell a live job from
          # one whose owner was killed.
          running="$STATE/running-$$.job"
          # If the rename loses a race with another worker, just move on.
          mv "$job" "$running" 2>/dev/null || { running=""; continue; }

          items=()
          while IFS= read -r -d "" x; do items+=("$x"); done < "$running"
          class=''${items[0]:-}
          path=''${items[1]:-}

          if [ -z "$class" ] || [ -z "$path" ]; then
            log "malformed job '$base' — discarding"
            rm -f "$running"; running=""
            continue
          fi

          # LOW POWER MODE GATES STARTING NEW WORK, not only work already
          # running — the watchdog below only exists once a job is already
          # forked, so without this a fresh job would always get to start
          # at least once before being frozen. Put back with a FRESH t1,
          # the same reset `…-recovered-*.t1.job` already uses, so
          # deferring for power never costs a retry attempt. `break`,
          # not a sleep loop: `ThrottleInterval` already retries this
          # worker every ~10s, so this reuses launchd's own mechanism
          # instead of adding a private one.
          if [ "$(lowpower_active)" = "1" ]; then
            mv "$running" "$QUEUE/$(date +%s)-lowpower.t1.job" 2>/dev/null || true
            running=""
            log "Low Power Mode is on — deferring '$path', not starting new work"
            break
          fi

          log "start $class '$path' (attempt $tries)"

          # Backgrounded and waited on, NOT `out=$(...)`: bash defers a trap
          # until the running foreground child returns, so a synchronous call
          # here would ignore SIGTERM for the length of an encode and get
          # SIGKILLed instead — losing the job and the lock with it. `wait` is
          # interruptible, so the trap fires at once.
          scratch=$(mktemp)
          # Job control on, so this background job becomes its own process group
          # leader and `kill -TERM -$child` can take the whole tree down.
          set -m
          # Dispatch by class rather than always calling fix-media: `describe`
          # is an ENRICHMENT, not a repair, so it has its own CLI. Both speak
          # the same done:/skip:/OK: grammar, so everything downstream — the
          # counters, the reason extraction, the notification — is unchanged.
          case "$class" in
            describe) photo-describe "$path" > "$scratch" 2>&1 & ;;
            *)        fix-media "--$class" "$path" > "$scratch" 2>&1 & ;;
          esac
          child=$!
          set +m

          # THE WATCHDOG: the ONLY thing that can notice Low Power Mode
          # turning on mid-batch. The gate above only runs once, before a
          # job starts; `wait "$child"` below blocks this whole loop until
          # the job exits, so nothing else in this script can poll while a
          # long describe/encode is in flight. A second background process
          # is therefore the only way to react during the job, not just
          # before or after it.
          #
          # THE MARKER FILE IS WHAT MAKES THIS SAFE TO AUTOMATE. Without
          # it, this loop could not tell "a job I paused for power" from "a
          # job the operator paused by hand" (`media-queue-pause`), and
          # would either fight a manual pause by resuming it, or need to
          # ask a human every 20s. `power-paused-<pid>` names the exact job
          # it belongs to, so a manual pause (no marker) is recognised by
          # the `T*` case below and left alone — this watchdog only ever
          # touches what it marked itself.
          #
          # `-$child`, matching the SIGTERM path above and `media-queue-
          # pause`/`-resume`: `set -m` gave the job its own process group
          # (pgid == its pid), and the negative pid is what makes a signal
          # reach ffmpeg/exiftool/curl grandchildren too, not just the
          # shell driving them.
          power_marker="$STATE/power-paused-$child"
          ( while kill -0 "$child" 2>/dev/null; do
              sleep "$POWER_POLL_INTERVAL"
              kill -0 "$child" 2>/dev/null || break
              if [ "$(lowpower_active)" = "1" ]; then
                if [ ! -f "$power_marker" ]; then
                  st=$(/bin/ps -o stat= -p "$child" 2>/dev/null | tr -d ' ')
                  case "$st" in
                    T*) : ;;
                    *)
                      if kill -STOP -"$child" 2>/dev/null; then
                        touch "$power_marker"
                        log "power: paused '$path' — Low Power Mode is on"
                      fi
                      ;;
                  esac
                fi
              elif [ -f "$power_marker" ]; then
                if kill -CONT -"$child" 2>/dev/null; then
                  log "power: resumed '$path' — Low Power Mode is off"
                fi
                rm -f "$power_marker"
              fi
            done
            rm -f "$power_marker"
          ) &
          watchdog=$!

          rc=0
          wait "$child" || rc=$?
          kill "$watchdog" 2>/dev/null || true
          rm -f "$power_marker"
          child=""
          watchdog=""
          power_marker=""
          out=$(cat "$scratch")
          rm -f "$scratch"
          printf '%s\n' "$out"

          d=$(printf '%s\n' "$out" | grep -c ': done:' || true)
          s=$(printf '%s\n' "$out" | grep -cE ': (skip|OK):' || true)
          # Counted ONCE PER JOB, not once per ATTEMPT. This loop retries a
          # failing job up to MAX_TRIES, and accumulating here meant a file that
          # succeeded on its third try was reported three times — "12 change(s)"
          # for four photos. Hold this attempt's numbers and fold them in only
          # when the job reaches a terminal outcome below.
          job_d=$d
          job_s=$s

          # Keep the FIRST reason a job declined to do anything, so a batch that
          # changed nothing can say why instead of just how many. The CLIs
          # decline for unrelated reasons — the target name is taken by a
          # different file, the bytes are already correct, it is not downloaded
          # from iCloud — and collapsing those into one number is what made a
          # correct refusal look like a no-op.
          #
          # The em-dash is stripped by ALTERNATION, never a bracket range. A
          # launchd job inherits no locale, so sed runs in the C locale, where
          # `—` is three bytes and `[—-]` is a malformed range that strips only
          # the FIRST of them — leaving two orphan bytes that the notification
          # rendered as `??`. Measured: `[—-]` leaves `M-^@M-^T` under LC_ALL=C
          # and is clean only under a UTF-8 locale the worker does not have.
          if [ "$d" -eq 0 ] && [ -z "$reason" ]; then
            reason=$(printf '%s\n' "$out" | grep -m1 -E ': (skip|OK):' \
              | sed -E "s/^[^:]*: (skip|OK): '[^']*' *//; s/^(—|-) *//" || true)
          fi

          # TERMINAL OUTCOMES fold the attempt's counts in; a requeue does not,
          # so a file that succeeds on attempt three is counted once, not three
          # times.
          if [ "$rc" -eq 0 ]; then
            changed=$((changed + job_d))
            skipped=$((skipped + job_s))
            jobs=$((jobs + 1))
            rm -f "$running"
          elif [ "$tries" -ge "$MAX_TRIES" ]; then
            log "giving up on '$path' after $tries attempts"
            changed=$((changed + job_d))
            skipped=$((skipped + job_s))
            jobs=$((jobs + 1))
            mv "$running" "$FAILED/$base" 2>/dev/null || rm -f "$running"
            failures=$((failures + 1))
          else
            # A FRESH timestamp, so the retry goes to the BACK of the queue.
            # Reusing the original would hand the same failing file straight
            # back and spin.
            #
            # HELD IN staging/ FOR A BACKOFF, not requeued immediately. Two
            # reasons, and the second is the one that bites:
            #   - Three attempts fired back-to-back are not a retry policy. The
            #     failures this can actually recover from are transient — Ollama
            #     restarting, a volume remounting — and none of them heal inside
            #     the microseconds an immediate requeue allows.
            #   - queue/ is what launchd WATCHES. A job sitting there waiting out
            #     a backoff keeps the directory non-empty, so launchd re-fires the
            #     agent continuously (ThrottleInterval only rate-limits it). Other
            #     people have hit exactly this and abandoned QueueDirectories over
            #     it. staging/ is not watched, so the wait is quiet.
            # The sleep is BACKGROUNDED and disowned so this worker can finish
            # its remaining jobs and exit; the move back is what re-arms launchd.
            next=$((tries + 1))
            backoff=$((next * next * 5))
            held="$STAGE/$(date +%s)-$$-retry.t$next.job"
            if mv "$running" "$held" 2>/dev/null; then
              log "requeueing '$path' for attempt $next after ''${backoff}s"
              ( sleep "$backoff"
                mv "$held" "$QUEUE/$(date +%s)-$$-retry.t$next.job" 2>/dev/null || true
              ) &
              disown 2>/dev/null || true
            else
              rm -f "$running"
            fi
          fi
          running=""
        done


        # The log line IS the report now. Notifications were removed entirely,
        # so there is no branching left to do: `reason` still exists because the
        # per-job loop lifts it, but nothing consumes it beyond this summary.
        log "idle — $changed changed, $skipped skipped, $failures failed''${reason:+ ($reason)}"
      '';
    })

    (writeShellApplication {
      name = "media-queue-pause";
      runtimeInputs = [ coreutils ];
      text = ''
        ${common}
        prog=media-queue-pause
        [ $# -eq 0 ] || { echo "usage: $prog" >&2; exit 1; }

        found=0
        for running in "$STATE"/running-*.job; do
          [ -e "$running" ] || continue
          wpid=''${running##*/running-}
          wpid=''${wpid%%.job}
          # A stale marker (worker already gone) has nothing left to freeze.
          if [ -z "$wpid" ] || ! kill -0 "$wpid" 2>/dev/null; then
            continue
          fi
          while IFS= read -r jpid; do
            [ -n "$jpid" ] || continue
            if kill -STOP -"$jpid" 2>/dev/null; then
              echo "$prog: paused pid $jpid (and its subprocesses)" >&2
              found=1
            fi
          done < <(job_child_of "$wpid")
        done

        if [ "$found" -eq 0 ]; then
          echo "$prog: nothing running right now — queue is idle or between jobs" >&2
        fi
      '';
    })

    (writeShellApplication {
      name = "media-queue-resume";
      runtimeInputs = [ coreutils ];
      text = ''
        ${common}
        prog=media-queue-resume
        [ $# -eq 0 ] || { echo "usage: $prog" >&2; exit 1; }

        # A HARD REFUSAL, not a race against the watchdog. media-worker's
        # own watchdog will just re-freeze this within one
        # POWER_POLL_INTERVAL if Low Power Mode is still on, so resuming
        # anyway would look like it worked for a few seconds and then
        # silently undo itself — worse than refusing outright and saying
        # why. Checked directly here rather than via the power-paused
        # marker: "must be paused on low power" is meant as a rule with no
        # loophole, including for a job that happened to be paused
        # manually while Low Power Mode was already on.
        if [ "$(lowpower_active)" = "1" ]; then
          echo "$prog: refusing — Low Power Mode is on" >&2
          echo "$prog: turn it off first (System Settings > Battery, or 'sudo pmset -a lowpowermode 0'), then resume" >&2
          exit 1
        fi

        found=0
        for running in "$STATE"/running-*.job; do
          [ -e "$running" ] || continue
          wpid=''${running##*/running-}
          wpid=''${wpid%%.job}
          if [ -z "$wpid" ] || ! kill -0 "$wpid" 2>/dev/null; then
            continue
          fi
          while IFS= read -r jpid; do
            [ -n "$jpid" ] || continue
            # CONT on a job that was never stopped is a harmless no-op, so this
            # never needs to first confirm the job was paused by us.
            if kill -CONT -"$jpid" 2>/dev/null; then
              echo "$prog: resumed pid $jpid" >&2
              found=1
            fi
          done < <(job_child_of "$wpid")
        done

        if [ "$found" -eq 0 ]; then
          echo "$prog: nothing running right now — nothing to resume" >&2
        fi
      '';
    })

    (writeShellApplication {
      name = "media-queue-status";
      runtimeInputs = [
        coreutils
        findutils
      ];
      text = ''
        ${common}
        prog=media-queue-status
        [ $# -eq 0 ] || { echo "usage: $prog" >&2; exit 1; }
        ensure_dirs

        pending=$(find "$QUEUE" -maxdepth 1 -name '*.job' -type f 2>/dev/null | wc -l | tr -d ' ')
        backoff=$(find "$STAGE" -maxdepth 1 -name '*-retry.t*.job' -type f 2>/dev/null | wc -l | tr -d ' ')
        dead=$(find "$FAILED" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')

        any_running=0
        for running in "$STATE"/running-*.job; do
          [ -e "$running" ] || continue
          wpid=''${running##*/running-}
          wpid=''${wpid%%.job}
          if [ -z "$wpid" ] || ! kill -0 "$wpid" 2>/dev/null; then
            # A crashed worker leaves this marker behind; the next worker start
            # reclaims it (see media-worker), so it is transient, not a bug.
            echo "$prog: stale marker $(basename "$running") — worker $wpid is gone (will self-heal on next worker start)"
            continue
          fi

          items=()
          while IFS= read -r -d "" x; do items+=("$x"); done < "$running"
          class=''${items[0]:-unknown}
          path=''${items[1]:-unknown}
          # NOT the attempt number: media-worker renames the job to
          # running-$$.job the moment it dequeues it, which drops the
          # original `.tN` suffix that carried the attempt count. That
          # number exists only in the worker's own `log "start ... (attempt
          # N)"` line, not in any state this tool can read without coupling
          # to the log's format — so it is left out rather than guessed.

          while IFS= read -r jpid; do
            [ -n "$jpid" ] || continue
            any_running=1
            state=$(/bin/ps -o stat= -p "$jpid" 2>/dev/null | tr -d ' ')
            case "$state" in
              T*)
                # The marker is media-worker's own watchdog leaving a trail:
                # present only for a pause IT made, never for one the
                # operator made by hand with media-queue-pause.
                if [ -f "$STATE/power-paused-$jpid" ]; then
                  label="PAUSED (Low Power Mode, auto)"
                else
                  label="PAUSED (SIGSTOP, manual)"
                fi
                ;;
              "") label="gone" ;;
              *)  label="running" ;;
            esac
            echo "$prog: $class '$path' — $label, pid $jpid"

            # The scratch file is a bare mktemp with no name this tool ever
            # recorded — media-worker's own choice, on purpose (see its
            # comment on `scratch=$(mktemp)`), so the only way to find it
            # after the fact is the same place the kernel keeps it: the job's
            # own open stdout fd. `-Fn` gives just the name field, one write
            # NUL-free line, which survives a path full of spaces.
            scratch=$(/usr/sbin/lsof -a -p "$jpid" -d 1 -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1)
            if [ -n "$scratch" ] && [ -f "$scratch" ]; then
              d=$(grep -c ': done:' "$scratch" 2>/dev/null || true)
              sk=$(grep -cE ': (skip|OK):' "$scratch" 2>/dev/null || true)
              er=$(grep -c ': error:' "$scratch" 2>/dev/null || true)
              last=$(tail -n1 "$scratch" 2>/dev/null || true)
              echo "$prog:   progress so far: $((d + sk + er)) processed ($d done, $sk skip/OK, $er error)"
              [ -n "$last" ] && echo "$prog:   last: $last"
            fi
          done < <(job_child_of "$wpid")
        done

        if [ "$any_running" -eq 0 ]; then
          echo "$prog: worker idle — nothing in flight"
        fi

        echo "$prog: queue: $pending pending, $backoff backing off (retry), $dead dead-letter (failed/)"
      '';
    })

  ];
  meta = {
    description = "Durable Finder-to-launchd work queue for the media toolkit: media-enqueue, media-worker, media-queue-pause, media-queue-resume, media-queue-status";
    mainProgram = "media-enqueue";
    platforms = lib.platforms.darwin;
  };
}
