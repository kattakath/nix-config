# media-queue — the durable work queue behind the Finder Services.
#
#   media-enqueue <--video|--image> <file-or-dir>...   write jobs, return at once
#   media-worker                                       drain the queue (launchd)
#   media-queue-status                                 SwiftBar plugin (menu bar)
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
  terminal-notifier,
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

    notify() {
      ${terminal-notifier}/bin/terminal-notifier \
        -title "Media Queue" -message "$1" -group nix-media-queue \
        "''${@:2}" >/dev/null 2>&1 || true
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
        LOG="$HOME/Library/Logs/nix-media-queue.log"
        LOCK="$STATE/worker.lock"
        MAX_TRIES=3

        log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

        # `mkdir` is the lock: it is atomic on every filesystem and needs no
        # helper binary. launchd should not start a second worker, but KeepAlive
        # and QueueDirectories are two independent start conditions and this
        # costs one line.
        # `mkdir` is the lock: atomic on every filesystem, no helper binary. The
        # pid inside is what makes it RECOVERABLE — a worker SIGKILLed mid-encode
        # never runs its trap, and a lock with no liveness check would then wedge
        # the queue permanently, with every future worker politely exiting.
        take_lock() {
          if mkdir "$LOCK" 2>/dev/null; then
            echo $$ > "$LOCK/pid"
            return 0
          fi
          local holder
          holder=$(cat "$LOCK/pid" 2>/dev/null || true)
          if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
            return 1
          fi
          log "breaking stale lock from pid ''${holder:-unknown}"
          rm -rf "$LOCK"
          mkdir "$LOCK" 2>/dev/null || return 1
          echo $$ > "$LOCK/pid"
        }

        if ! take_lock; then
          log "another worker holds the lock — exiting"
          exit 0
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
          rm -rf "$LOCK"
        }
        trap cleanup EXIT
        trap 'cleanup; exit 143' INT TERM

        changed=0
        skipped=0
        failures=0
        jobs=0
        reason=

        while :; do
          job=$(find "$QUEUE" -maxdepth 1 -name '*.job' -type f 2>/dev/null | sort | head -1)
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
          changed=$((changed + d))
          skipped=$((skipped + s))
          jobs=$((jobs + 1))

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

          if [ "$rc" -eq 0 ]; then
            rm -f "$running"
          elif [ "$tries" -ge "$MAX_TRIES" ]; then
            log "giving up on '$path' after $tries attempts"
            mv "$running" "$FAILED/$base" 2>/dev/null || rm -f "$running"
            failures=$((failures + 1))
          else
            # A FRESH timestamp, so the retry goes to the BACK of the queue.
            # Reusing the original would hand the same failing file straight
            # back and spin.
            next=$((tries + 1))
            mv "$running" "$QUEUE/$(date +%s)-$$-retry.t$next.job" 2>/dev/null || rm -f "$running"
            log "requeueing '$path' for attempt $next"
          fi
          running=""
        done

        rm -f "$STATUS"

        if [ "$failures" -gt 0 ]; then
          notify "$changed change(s), $failures failed" -execute "open '$FAILED'"
        elif [ "$changed" -gt 0 ]; then
          notify "$changed change(s) applied, $skipped skipped" -execute "open '$LOG'"
        elif [ "$jobs" -eq 1 ] && [ -n "$reason" ]; then
          # ONE item that changed nothing: report the reason, not the count. This
          # is the case the operator is most likely to be standing there waiting
          # for, and "nothing to do" is exactly the wrong thing to tell them when
          # the tool refused on purpose.
          notify "$reason" -execute "open '$LOG'"
        elif [ "$jobs" -gt 0 ]; then
          notify "Nothing to change in $jobs item(s)" -execute "open '$LOG'"
        fi
        log "idle — $changed changed, $skipped skipped, $failures failed"
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

        STATUS="$STATE/status"
        LOG="$HOME/Library/Logs/nix-media-queue.log"

        depth=0
        [ -d "$QUEUE" ] && depth=$(find "$QUEUE" -maxdepth 1 -name '*.job' 2>/dev/null | wc -l | tr -d ' ')
        dead=0
        [ -d "$FAILED" ] && dead=$(find "$FAILED" -maxdepth 1 -name '*.job' 2>/dev/null | wc -l | tr -d ' ')
        current=""
        [ -f "$STATUS" ] && current=$(head -1 "$STATUS" 2>/dev/null || true)

        # SILENCE IS THE POINT: an empty plugin prints nothing and SwiftBar shows
        # no menu-bar item at all, so an idle queue costs the operator no
        # attention and no pixels.
        if [ "$depth" -eq 0 ] && [ -z "$current" ] && [ "$dead" -eq 0 ]; then
          exit 0
        fi

        if [ "$dead" -gt 0 ] && [ "$depth" -eq 0 ] && [ -z "$current" ]; then
          echo "⚠ $dead"
        else
          echo "⚙ $depth"
        fi
        echo "---"
        [ -n "$current" ] && echo "Working on: ''${current##*/} | length=45"
        echo "$depth queued · $dead failed | size=11"
        echo "---"
        echo "Open Log | bash=/usr/bin/open param1=$LOG terminal=false"
        [ "$dead" -gt 0 ] && echo "Open Failed Jobs | bash=/usr/bin/open param1=$FAILED terminal=false"
        [ "$dead" -gt 0 ] && echo "Retry Failed | bash=/bin/mv param1=$FAILED param2=$QUEUE terminal=false refresh=true"
        echo "Cancel Queued | bash=/usr/bin/find param1=$QUEUE param2=-name param3=*.job param4=-delete terminal=false refresh=true"
      '';
    })
  ];
  meta = {
    description = "Durable Finder-to-launchd work queue for the media toolkit: media-enqueue, media-worker and the SwiftBar status plugin";
    mainProgram = "media-enqueue";
    platforms = lib.platforms.darwin;
  };
}
