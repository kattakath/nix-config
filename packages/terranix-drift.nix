# `terranix-drift` — the daily drift check over every terranix stack (ADR-012 § 5 step 1).
#
# It runs each stack's `*-plan` wrapper with `-detailed-exitcode -lock=false` and classes
# the exit: 0 clean, 2 drift, anything else error. An auth failure is an ERROR, never
# drift and never clean; a lapsed Google login is labelled `reauth` (same severity) and
# the run ends with the re-login command. It prints one line per stack (counts only), keeps each plan's
# full output 0600 under its own state dir, and writes `summary.json` there. The hourly
# fleet-gauges push reads that file and sends it to Grafana (packages/fleet-gauges.py).
#
# THE STACK LIST IS DERIVED, not typed: modules/parts/terranix.nix passes every flake
# package named `*-plan`, so a new stack's plan app is covered without an edit here. Its
# Keychain credential comes from that wrapper's `passthru.terranixDriftEnv`. A plan with
# no entry still runs. Its unset-token guard then exits 1, which is class `error`, so the
# run pings /fail. An uncovered credential is loud, never silently clean.
#
# ALERTING is the heartbeat `nix-config-terranix-drift` (modules/parts/heartbeats.nix),
# through runitor: success when every stack is clean, /fail otherwise. A run that never
# happens alerts on its own (the monitor's grace).
#
# upstream-first: plan exit codes are tofu's own `-detailed-exitcode`. The pinger is
# runitor, the healthchecks.io-recommended runner nixpi's service-heartbeat already uses.
# No community tool owns "plan N encrypted-state stacks from a laptop on a timer"
# (searched nixpkgs: terraform drift, driftctl, tfdrift). driftctl is archived (2023).
# The CI shapes (Atlantis drift, Spacelift) would need the state passphrase in CI,
# which ADR-012 § 6 rejects.
{
  lib,
  writeShellApplication,
  coreutils,
  gnugrep,
  jq,
  runitor,
  # name -> the `*-plan` wrapper derivation (modules/parts/terranix.nix).
  plans,
  # The Home Manager profile whose `bin/secret` to call. null = `secret` from PATH, the
  # interactive `nix run .#terranix-drift` case.
  homeProfileDir ? null,
  slug ? "nix-config-terranix-drift",
}:
let
  # Every plan must STATE its credential, even as `{ }` (ADR-012 coverage): a new stack
  # whose wrapper forgets fails here at eval, not as a daily /fail nobody can explain.
  uncovered = lib.attrNames (lib.filterAttrs (_: p: !(p ? terranixDriftEnv)) plans);
  names =
    assert lib.assertMsg (uncovered == [ ])
      "terranix-drift: set passthru.terranixDriftEnv (Keychain item NAMES, or { }) on: ${toString uncovered}";
    lib.attrNames plans;
  secretEnv = lib.foldl' (acc: n: acc // (plans.${n}.terranixDriftEnv or { })) { } names;
  secretArgs = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${v}") secretEnv);
  secretBin = if homeProfileDir == null then "secret" else "${homeProfileDir}/bin/secret";
  stackLines = lib.concatMapStrings (
    n: "${lib.removeSuffix "-plan" n} ${lib.getExe plans.${n}}\n"
  ) names;

  run = writeShellApplication {
    name = "terranix-drift-run";
    runtimeInputs = [
      coreutils
      gnugrep
      jq
    ];
    text = ''
      # One fixed working directory. Each wrapper then cd's into its own pinned state
      # dir, so tofu never runs in a stray CWD (state was lost twice that way).
      dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-terranix-drift"
      mkdir -p "$dir"
      chmod 700 "$dir"
      cd "$dir"
      umask 077
      export TF_INPUT=0 TF_IN_AUTOMATION=1

      started=$(date +%s)
      results="[]"
      worst=0
      reauth=0
      while read -r stack plan; do
        [ -n "$stack" ] || continue
        log="$dir/$stack.log"
        if "$plan" -detailed-exitcode -lock=false -input=false -no-color > "$log" 2>&1; then
          rc=0
        else
          rc=$?
        fi
        case "$rc" in
          0) status=clean; code=0 ;;
          2) status=drift; code=1 ;;
          *) status=error; code=2 ;;
        esac
        # A lapsed Google login (Workspace session control's periodic reauth) fails every
        # GCS-backed stack the same way. Name it, so the alert reads as "log in again"
        # rather than as five broken stacks. Same severity (code 2): it still pings /fail.
        if [ "$status" = error ] && grep -qE 'invalid_rapt|reauth related error|Reauthentication failed' "$log"; then
          status=reauth
          reauth=1
        fi
        [ "$code" -gt "$worst" ] && worst=$code
        # "Plan: 1 to add, 0 to change, 0 to destroy." — counts only, never the diff.
        counts=$(grep -Eo 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy' "$log" | tail -1 | grep -Eo '[0-9]+' | tr '\n' ' ' || true)
        read -r add change destroy <<< "''${counts:-0 0 0}"
        if [ "$status" = reauth ]; then
          echo "$stack: reauth (Google login expired)"
        elif [ "$status" = error ]; then
          echo "$stack: error (exit $rc; see $log)"
        else
          echo "$stack: $status (add $add, change $change, destroy $destroy)"
        fi
        results=$(jq -c --arg s "$stack" --arg st "$status" --argjson c "$code" --argjson rc "$rc" \
          --argjson a "$add" --argjson ch "$change" --argjson d "$destroy" \
          '. + [{stack: $s, status: $st, code: $c, exit: $rc, add: $a, change: $ch, destroy: $d}]' <<< "$results")
      done <<'STACKS'
      ${stackLines}STACKS

      jq -n --argjson t "$started" --argjson f "$(date +%s)" --argjson r "$results" \
        '{started: $t, finished: $f, stacks: $r}' > summary.json.tmp
      mv summary.json.tmp summary.json
      echo "terranix-drift: $(jq '[.stacks[] | select(.code == 0)] | length' summary.json)/$(jq '.stacks | length' summary.json) clean"
      if [ "$reauth" = 1 ]; then
        echo "ACTION: the Google login expired. Run: CLOUDSDK_CONFIG=~/.config/gcloud-nix-config gcloud auth application-default login"
      fi
      # Non-zero for any drift or error: runitor turns it into /fail.
      exit "$worst"
    '';
  };
in
writeShellApplication {
  name = "terranix-drift";
  runtimeInputs = [ runitor ];
  text = ''
    # GCP ADC, scoped exactly as the devShell scopes it (modules/parts/devshell.nix).
    # launchd sets neither variable, and every GCS-backed stack's `tofu init` reads ADC,
    # so without these a plan would act as whoever last ran the global gcloud login.
    export CLOUDSDK_CONFIG="''${XDG_CONFIG_HOME:-$HOME/.config}/gcloud-nix-config"
    export GOOGLE_APPLICATION_CREDENTIALS="$CLOUDSDK_CONFIG/application_default_credentials.json"

    # --no-ping: plan and summarise, ping nothing (a manual look).
    if [ "''${1:-}" = "--no-ping" ]; then
      exec ${secretBin} exec ${secretArgs} -- ${lib.getExe run}
    fi
    # Values arrive only through `secret exec`'s environment, never argv. runitor reads
    # PING_KEY itself and sends the run's output (counts only) as the ping body.
    exec ${secretBin} exec ${secretArgs} PING_KEY=hc:healthchecks.io:ping-key -- \
      runitor -slug ${lib.escapeShellArg slug} -on-nonzero-exit fail -- ${lib.getExe run}
  '';
  passthru = { inherit names secretEnv; };
}
