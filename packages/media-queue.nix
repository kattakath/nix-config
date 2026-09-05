# media-queue — the durable work queue behind the Finder Services.
#
#   media-enqueue <--video|--image> <file-or-dir>...   write jobs, return at once
#   media-worker                                       drain the queue (launchd)
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
{
  lib,
  symlinkJoin,
  writeShellApplication,
  callPackage,
  coreutils,
  findutils,
  writeText,
  media-toolkit ? callPackage ./media-toolkit.nix { },
}:
let
  # Spliced into all three, so the layout is stated once. INLINED rather than
  # sourced from a `writeText`: shellcheck cannot follow a `.` into /nix/store
  # (SC1091) and would then treat every shared variable as unassigned, so the
  # lint gate would have to be switched off for exactly the code most worth
  # linting. $HOME at RUNTIME — these are paths the tools read and write, not
  # Nix source paths.
  # Own file rather than a heredoc: the script must survive a Nix indented
  # string, and quoting it twice is how you get a notifier that silently does
  # nothing. Same reasoning as media-quick-actions.nix.
  notifyScript = writeText "media-queue-notify.applescript" ''
    on run argv
      display notification (item 1 of argv) with title "Media Queue"
    end run
  '';

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

    # NOTIFY VIA osascript, NOT terminal-notifier. terminal-notifier is an
    # unsigned /nix/store app bundle with its own id (fr.julienxx.oss.terminal-
    # notifier) that macOS never registered in Notification Centre — measured:
    # absent from com.apple.ncprefs. Every call still exits 0, because the tool
    # reports no permission denial and this function ends in `|| true`, so the
    # queue's entire status output was failing SILENTLY. `display notification`
    # is attributed to a system binary, needs no per-app grant, and is the same
    # mechanism the Finder Services next door already use successfully.
    #
    # The cost is the CLICK ACTION: AppleScript's `display notification` cannot
    # carry one, so the banners no longer open the log or failed/ when clicked.
    # A notification that reliably appears and says where to look beats one that
    # opens a folder and never appears.
    notify() {
      /usr/bin/osascript ${notifyScript} "$1" >/dev/null 2>&1 || true
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

        notify "Queued $n $class item(s)"
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
        STATUS="$STATE/status"
        LOCK="$STATE/worker.lock"
        MAX_TRIES=3

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
        cleanup() {
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
          rm -f "$STATUS"
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

          printf '%s\n%s\n' "$path" "$(find "$QUEUE" -maxdepth 1 -name '*.job' | wc -l | tr -d ' ')" > "$STATUS"
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
          rc=0
          wait "$child" || rc=$?
          child=""
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

        rm -f "$STATUS"

        if [ "$failures" -gt 0 ]; then
          notify "$changed change(s), $failures failed — see ~/Library/Logs/nix-media-queue.log"
        elif [ "$changed" -gt 0 ]; then
          notify "$changed change(s) applied, $skipped skipped"
        elif [ "$jobs" -eq 1 ] && [ -n "$reason" ]; then
          # ONE item that changed nothing: report the reason, not the count. This
          # is the case the operator is most likely to be standing there waiting
          # for, and "nothing to do" is exactly the wrong thing to tell them when
          # the tool refused on purpose.
          notify "$reason"
        elif [ "$jobs" -gt 0 ]; then
          notify "Nothing to change in $jobs item(s)"
        fi
        log "idle — $changed changed, $skipped skipped, $failures failed"
      '';
    })

  ];
  meta = {
    description = "Durable Finder-to-launchd work queue for the media toolkit: media-enqueue, and media-worker";
    mainProgram = "media-enqueue";
    platforms = lib.platforms.darwin;
  };
}
