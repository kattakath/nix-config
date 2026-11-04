# doctor-report — the mechanical half of ADR-013 § 7–9: check a doctor run, never make one.
#
# The doctors (/hygiene, /fleet-doctor) are agent sessions; their judgment goes into TRIAGE.
# What the run EMITS is checked here, so a model's output is held to a contract rather than
# trusted:
#   rules                 the catalogue (.claude/skills/doctors/rules.json) is well formed
#   validate FILE [SARIF] SARIF 2.1.0 (hygiene) or health+json (fleet-doctor) conforms; with a
#                         hygiene SARIF too, FD-D-hygiene must be what `hygiene-for` derives
#   hygiene-for SHA [SARIF]  the FD-D-hygiene check object for fleet-doctor subject SHA, from the
#                         hygiene run (default: hygiene's `latest`); exit 3 when that run is
#                         for another SHA — it prints the `skipped:` object instead, never findings
#   verdict FILE          exit 0 clean, 2 findings or vacuous (ADR-013 § 7)
#   diff OLD NEW          new / resolved / persisting finding IDs, as JSON
#   fingerprint RULE FILE CONSTRUCT   the stable findingId/v1 (never a line number)
#   skeleton DOCTOR SHA   an empty, catalogue-derived envelope to fill
#   publish DOCTOR FILE   validate, copy to the state dir, point `latest` at it
#   weekly [--no-ping]    the scheduled audit's ONE entry point (below)
#
# `weekly` is what the weekly Claude Desktop task runs after `/fleet-doctor` and `/hygiene`
# (prompt: docs/doctors-coverage-adr.md § 6). It reads both `latest` runs, refuses a missing,
# invalid or STALE one (a doctor that died before `publish` leaves last week's `latest`, which
# still validates), diffs each against that doctor's previous run, and prints counts plus the
# NEW finding IDs. Then it pings the `nix-config-doctors-weekly` heartbeat through runitor.
# The exit policy is the inverse of terranix-drift's, on purpose: FINDINGS ARE NOT FAILURES.
# Verdict 0 (clean) and 2 (findings or vacuous) both exit 0, so runitor pings success; only a
# broken run exits 1, which runitor sends as /fail. A run that never happens alerts on the
# monitor's grace. `--no-ping` runs the same report and touches neither `secret` nor runitor.
#
# Upstream-first: SARIF conformance is the OASIS schema run through nixpkgs' check-jsonschema,
# not a hand-written shape. The health-check draft (-06) publishes no JSON Schema, so its
# envelope is a jq check, which is the only custom validation here. Both formats then get the
# catalogue checks no schema can express: every ruleId exists, every rule reports, and
# `inputsExamined: 0` is vacuous — never pass.
#
# The catalogue is passed in by the engine (a path literal there); DOCTOR_RULES overrides it
# so the check can run the fixtures against a small test catalogue.
{
  writeShellApplication,
  fetchurl,
  jq,
  check-jsonschema,
  coreutils,
  runitor,
  catalogue,
  # The heartbeat `weekly` pings (modules/parts/heartbeats.nix). Named here, in quotes, so
  # checks.<system>.heartbeat-workflow-parity's agentPingers leg can see this file names it.
  slug ? "nix-config-doctors-weekly",
  # The Keychain item NAME runitor reads PING_KEY from (modules/_lib/keychain-items.nix).
  pingKeyItem,
}:
let
  # SARIF 2.1.0 Plus Errata 01, the schema ADR-013 § 8 cites.
  sarifSchema = fetchurl {
    url = "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json";
    hash = "sha256-w7S7LWCTiXSDNIklqqc68Ds+P0vUyjjO8m3LQhKiaC4=";
  };
in
writeShellApplication {
  name = "doctor-report";
  runtimeInputs = [
    jq
    check-jsonschema
    coreutils
    runitor
  ];
  text = ''
    rules="''${DOCTOR_RULES:-${catalogue}}"
    sarif_schema=${sarifSchema}

    die() { echo "doctor-report: $*" >&2; exit 1; }

    usage() {
      cat >&2 <<'EOF'
    usage: doctor-report rules
           doctor-report validate FILE [HYGIENE_SARIF]   (with both: FD-D-hygiene must match the SARIF)
           doctor-report hygiene-for SUBJECT_SHA [HYGIENE_SARIF]   (0 current, 3 stale = skipped object, 1 invalid)
           doctor-report verdict FILE          (0 clean, 2 findings/vacuous, 1 invalid)
           doctor-report diff OLD NEW          ({new, resolved, persisting} finding IDs)
           doctor-report fingerprint RULE_ID FILE_OR_SUBJECT CONSTRUCT
           doctor-report skeleton hygiene|fleet-doctor SUBJECT_SHA [REPO_URI] [BRANCH]
           doctor-report publish hygiene|fleet-doctor FILE
           doctor-report weekly [--no-ping]   (validate + diff both latest runs, ping the heartbeat)
    EOF
      exit 1
    }

    # Print each problem on its own line; any line fails the caller.
    report() {
      local what=$1 problems=$2
      if [ -n "$problems" ]; then
        while IFS= read -r line; do printf '%s: %s\n' "$what" "$line"; done <<<"$problems" >&2
        return 1
      fi
    }

    check_rules() {
      jq -e . "$rules" >/dev/null 2>&1 || die "catalogue $rules is not JSON"
      local problems
      problems=$(jq -r '
        def blank: . == null or . == "" or (type == "array" and length == 0);
        ["id","doctor","section","shortDescription","detect","evidence","vacuousWhen"] as $req
        | if (.version | type) != "number" then "catalogue .version must be a number" else empty end,
          if (.rules | type) != "array" or (.rules | length) == 0 then "catalogue .rules must be a non-empty array"
          else
            (.rules | group_by(.id)[] | select(length > 1) | "duplicate id \(.[0].id)"),
            (.rules | map(select(.doctor == "fleet-doctor")) | group_by(.checkKey)[]
              | select(length > 1) | "duplicate checkKey \(.[0].checkKey)"),
            (.rules[] | . as $r | ($r.id // "?") as $id
              | ($req[] | select($r[.] | blank) | "\($id): missing \(.)"),
                (if ($r.evidence | type) == "array" and ($r.evidence | all(type == "string")) then empty
                 else "\($id): evidence must be an array of strings" end),
                (if $r.doctor == "hygiene" then
                   (if ($id | test("^NH-[A-Z]-[a-z0-9-]+$")) then empty else "\($id): hygiene ids read NH-<section>-<slug>" end),
                   (if ($r.level | IN("note","warning","error")) then empty else "\($id): level must be note|warning|error" end),
                   (if ($r | has("checkKey") or has("statusOnFinding")) then "\($id): checkKey/statusOnFinding are fleet-doctor fields" else empty end)
                 elif $r.doctor == "fleet-doctor" then
                   (if ($id | test("^FD-[A-Z][0-9]?-[a-z0-9-]+$")) then empty else "\($id): fleet-doctor ids read FD-<step>-<slug>" end),
                   (if ($r.statusOnFinding | IN("warn","fail")) then empty else "\($id): statusOnFinding must be warn|fail" end),
                   (if (($r.checkKey // "") | test("^[a-z0-9-]+:[a-z0-9-]+$")) then empty else "\($id): checkKey must be component:measurement" end),
                   (if $r | has("level") then "\($id): level is a hygiene field" else empty end)
                 else "\($id): doctor must be hygiene or fleet-doctor" end))
          end
      ' "$rules") || die "jq failed on the catalogue"
      report "$rules" "$problems"
    }

    kind_of() {
      if jq -e '.version == "2.1.0" and (.runs | type == "array")' "$1" >/dev/null 2>&1; then echo sarif
      elif jq -e '(.checks | type == "object") and has("status")' "$1" >/dev/null 2>&1; then echo health
      else echo unknown; fi
    }

    check_sarif() {
      local f=$1 problems
      # Formats stay ON: `date-time` is enforced (broken-sarif-date proves it). `uri` is NOT —
      # measured, a "::not a uri::" passes — so a URI's shape is unchecked, on every host alike.
      check-jsonschema --no-cache --schemafile "$sarif_schema" "$f" >&2 \
        || { echo "$f: does not conform to the SARIF 2.1.0 schema" >&2; return 1; }
      problems=$(jq -r --slurpfile cat "$rules" '
        ($cat[0].rules | map(select(.doctor == "hygiene"))) as $nh
        | ($nh | map({key: .id, value: .}) | from_entries) as $by
        | if (.runs | length) != 1 then "exactly one run expected" else
          .runs[0] as $run
          | (if $run.tool.driver.name == "nix-hygiene" then empty else "tool.driver.name must be nix-hygiene" end),
            (if ([$run.tool.driver.rules[]?.id] | sort) == ($nh | map(.id) | sort) then empty
             else "tool.driver.rules must be exactly the catalogue hygiene rules (doctor-report skeleton builds them)" end),
            ($run.tool.driver.rules[]? | select($by[.id] != null and .defaultConfiguration.level != $by[.id].level)
              | "\(.id): defaultConfiguration.level must be \($by[.id].level)"),
            (if (($run.versionControlProvenance[0].revisionId // "") | test("^[0-9a-f]{40}$")) then empty
             else "versionControlProvenance[0].revisionId must be the subject 40-hex SHA" end),
            ($run.results[]? | . as $x | $by[$x.ruleId // ""] as $r
              | if $r == null then "unknown ruleId \($x.ruleId)" else
                  (if ($x.kind | IN("pass","fail","notApplicable")) then empty
                   else "\($x.ruleId): kind must be pass, fail or notApplicable" end),
                  ($x.properties.inputsExamined as $n
                    | if ($n | type) != "number" or $n < 0 then "\($x.ruleId): properties.inputsExamined must be a count"
                      elif $n == 0 and $x.kind != "notApplicable" then "\($x.ruleId): inputsExamined 0 is vacuous, so kind must be notApplicable, not \($x.kind)"
                      elif $n > 0 and $x.kind == "notApplicable" then "\($x.ruleId): notApplicable means inputsExamined 0"
                      else empty end),
                  (if $x.kind == "fail" then
                     (if $x.level == $r.level then empty else "\($x.ruleId): level must be the catalogue level \($r.level)" end),
                     (if (($x.partialFingerprints["findingId/v1"] // "") | startswith($x.ruleId + "/")) then empty
                      else "\($x.ruleId): a fail needs partialFingerprints.findingId/v1 = <ruleId>/<hash>" end)
                   elif ($x.level // "none") != "none" then "\($x.ruleId): a \($x.kind) result has level none"
                   else empty end)
                end),
            ([$run.results[]? | select(.kind == "fail") | .partialFingerprints["findingId/v1"]]
              | group_by(.)[] | select(length > 1) | "duplicate findingId/v1 \(.[0])"),
            ($nh[] | .id as $id | [$run.results[]? | select(.ruleId == $id) | .kind] as $k
              | if ($k | length) == 0 then "\($id): no result; every rule reports pass, fail or notApplicable (absent = unaudited)"
                elif ($k | unique | length) > 1 then "\($id): mixes kinds \($k | unique | join(","))"
                else empty end)
          end
      ' "$f") || { echo "$f: jq failed" >&2; return 1; }
      report "$f" "$problems"
    }

    # FD-D-hygiene's IDs WRAP the hygiene SARIF's own findingId/v1 (see `hygiene_for`), so the
    # NH id stays readable and stripping "FD-D-hygiene/" gives back the SARIF's ID.
    check_health() {
      local f=$1 problems
      problems=$(jq -r --slurpfile cat "$rules" '
        . as $root
        | ($cat[0].rules | map(select(.doctor == "fleet-doctor"))) as $fd
        | ($fd | map({key: .id, value: .}) | from_entries) as $by
        | [$cat[0].rules[] | select(.doctor == "hygiene") | .id] as $nhIds
        | def rank: {"pass": 0, "warn": 1, "fail": 2}[.];
          (if (.status | IN("pass","warn","fail")) then empty else "status must be pass, warn or fail (base words only)" end),
          (if ((.releaseId // "") | test("^[0-9a-f]{40}$")) then empty else "releaseId must be the subject 40-hex SHA" end),
          (.checks | to_entries[] | .key as $k | .value as $v
            | if ($k | test("^[a-z0-9-]+:[a-z0-9-]+$")) | not then "\($k): key must be component:measurement"
              elif ($v | type) != "array" or ($v | length) == 0 then "\($k): value must be a non-empty array (draft-06)"
              else $v[] | . as $c | $by[$c.ruleId // ""] as $r
                | if $r == null then "\($k): unknown ruleId \($c.ruleId)"
                  elif $r.checkKey != $k then "\($k): \($c.ruleId) reports under \($r.checkKey)"
                  elif ($c.status | IN("pass","warn","fail")) | not then "\($k): status must be pass, warn or fail"
                  elif ($c.inputsExamined | type) != "number" or $c.inputsExamined < 0 then "\($k): inputsExamined must be a count"
                  elif ($c.observedValue | type) != "number" or $c.observedValue < 0 then "\($k): observedValue must be a count"
                  elif $c.inputsExamined == 0 then
                    (if $c.status == "warn" and $c.observedValue == 0
                        and (($c.output // "") == "vacuous" or (($c.output // "") | startswith("skipped:")))
                     then empty
                     else "\($k): inputsExamined 0 reads status warn, observedValue 0, output \"vacuous\" or \"skipped: <why>\"" end)
                  elif $c.observedValue > 0 then
                    ((($c.output // "") | split(" ") | map(select(length > 0))) as $ids
                      | (if $c.status == $r.statusOnFinding then empty else "\($k): a finding reads status \($r.statusOnFinding), not \($c.status)" end),
                        (if ($ids | length) == $c.observedValue then empty else "\($k): observedValue \($c.observedValue) but output lists \($ids | length) finding IDs" end),
                        ($ids[] | select(startswith($r.id + "/") | not) | "\($k): finding ID \(.) must start with \($r.id)/"),
                        (if $r.id == "FD-D-hygiene" then
                           $ids[] | select(startswith($r.id + "/")) | . as $id | ($id | ltrimstr($r.id + "/")) as $inner
                           | select([$nhIds[] | . as $h | $inner | startswith($h + "/")] | any | not)
                           | "\($k): \($id) must be FD-D-hygiene/<hygiene findingId/v1> or FD-D-hygiene/<NH rule>/vacuous (doctor-report hygiene-for)"
                         else empty end))
                  elif $c.status != "pass" then "\($k): no finding over \($c.inputsExamined) inputs is pass, not \($c.status)"
                  else empty end
              end),
          ($fd[] | select(.checkKey as $ck | $root.checks | has($ck) | not)
            | "\(.checkKey): missing; every catalogue check reports (pass, a finding, vacuous or skipped)"),
          ([.checks[] | arrays | .[] | objects | .status | rank] | max // 0) as $worst
          | (if (.status | rank) == $worst then empty else "status \(.status) is not the worst check status" end),
          ([.checks[] | arrays | .[] | objects | select((.observedValue | type) == "number" and .observedValue > 0)
            | (.output // "") | strings | split(" ")[] | select(length > 0)] | group_by(.)[]
            | select(length > 1) | "duplicate finding ID \(.[0])")
      ' "$f") || { echo "$f: jq failed" >&2; return 1; }
      report "$f" "$problems"
    }

    # The FD-D-hygiene check object for fleet-doctor subject SHA, derived from a hygiene SARIF.
    # Stale (the SARIF's revisionId is another SHA): the `skipped:` object, and return 3, so a
    # caller can never pass along findings from a different subject.
    hygiene_for() {
      local sha=$1 sarif=$2
      [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "SUBJECT_SHA must be 40 hex characters"
      validate "$sarif" || return 1
      [ "$(kind_of "$sarif")" = sarif ] || { echo "$sarif: not a hygiene SARIF run" >&2; return 1; }
      jq -e '.rules[] | select(.id == "FD-D-hygiene")' "$rules" >/dev/null || die "catalogue has no FD-D-hygiene rule"
      jq -c --arg sha "$sha" --slurpfile cat "$rules" '
        ($cat[0].rules[] | select(.id == "FD-D-hygiene")) as $r
        | .runs[0] as $run | $run.versionControlProvenance[0].revisionId as $rev
        | {ruleId: $r.id, componentId: "nix-config"}
          + if $rev != $sha then
              {status: "warn", observedValue: 0, inputsExamined: 0,
               output: "skipped: hygiene run is for \($rev[0:12]), subject is \($sha[0:12])"}
            else
              ([$run.results[] | select(.kind == "fail") | $r.id + "/" + .partialFingerprints["findingId/v1"]]
               + [$run.results[] | select(.kind == "notApplicable") | $r.id + "/" + .ruleId + "/vacuous"]
               | unique) as $ids
              | {status: (if ($ids | length) > 0 then $r.statusOnFinding else "pass" end),
                 observedValue: ($ids | length), inputsExamined: ($run.results | length)}
                + (if ($ids | length) > 0 then {output: ($ids | join(" "))} else {} end)
            end
      ' "$sarif" || return 1
      jq -e --arg sha "$sha" '.runs[0].versionControlProvenance[0].revisionId == $sha' "$sarif" >/dev/null && return 0
      echo "hygiene-for: $sarif is for $(jq -r '.runs[0].versionControlProvenance[0].revisionId' "$sarif" | cut -c1-12), subject is ''${sha:0:12}: run /hygiene at the subject, or report the skipped object" >&2
      return 3
    }

    # validate HEALTH SARIF: FD-D-hygiene is either vacuous/skipped or exactly hygiene_for's object.
    check_fd_hygiene() {
      local health=$1 sarif=$2 key got want rc
      [ "$(kind_of "$health")" = health ] && [ "$(kind_of "$sarif")" = sarif ] \
        || die "validate FILE SARIF: FILE must be health+json and SARIF a hygiene run"
      key=$(jq -r '.rules[] | select(.id == "FD-D-hygiene") | .checkKey' "$rules")
      [ -n "$key" ] || die "catalogue has no FD-D-hygiene rule"
      got=$(jq -c --arg k "$key" '[.checks[$k][]? | select(.ruleId == "FD-D-hygiene")
        | {ruleId, status, observedValue, inputsExamined, output: (.output // "")}]' "$health")
      if jq -e 'length == 1 and .[0].inputsExamined == 0' <<<"$got" >/dev/null; then return 0; fi
      set +e; want=$(hygiene_for "$(jq -r .releaseId "$health")" "$sarif" 2>/dev/null); rc=$?; set -e
      case $rc in
        0) ;;
        3) echo "$health: FD-D-hygiene reports findings from a hygiene run for another subject: $(jq -r .output <<<"$want")" >&2; return 1 ;;
        *) echo "$sarif: not a valid hygiene run" >&2; return 1 ;;
      esac
      jq -e --argjson want "$want" 'length == 1 and .[0] == ($want | {ruleId, status, observedValue, inputsExamined, output: (.output // "")})' \
        <<<"$got" >/dev/null \
        || { echo "$health: FD-D-hygiene is not what \`doctor-report hygiene-for\` derives from $sarif: want $want" >&2; return 1; }
    }

    validate() {
      local f=$1
      [ -r "$f" ] || die "$f: not readable"
      jq -e . "$f" >/dev/null 2>&1 || { echo "$f: not JSON" >&2; return 1; }
      case $(kind_of "$f") in
        sarif) check_sarif "$f" ;;
        health) check_health "$f" ;;
        *) echo "$f: neither SARIF 2.1.0 nor health+json" >&2; return 1 ;;
      esac
    }

    finding_ids() {
      case $(kind_of "$1") in
        sarif) jq -r '.runs[0].results[] | select(.kind == "fail") | .partialFingerprints["findingId/v1"]' "$1" ;;
        health) jq -r '.checks[][] | select(.observedValue > 0) | .output | split(" ")[] | select(length > 0)' "$1" ;;
      esac | sort -u
    }

    state_dir() {
      printf '%s/%s\n' "''${DOCTOR_REPORT_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/nix-config-doctors}" "$1"
    }

    # 0 when FILE has nothing open, else 1 (any finding, vacuous or skipped section).
    is_open() {
      case $(kind_of "$1") in
        sarif) jq -e '[.runs[0].results[] | select(.kind != "pass")] | length > 0' "$1" >/dev/null ;;
        health) jq -e '.status != "pass"' "$1" >/dev/null ;;
      esac
    }

    # Sections that examined nothing (ADR-013 § 7): they make a run verdict 2 with 0 findings.
    vacuous_count() {
      case $(kind_of "$1") in
        sarif) jq '[.runs[0].results[] | select(.kind == "notApplicable")] | length' "$1" ;;
        health) jq '[.checks[][] | select(.status == "warn" and ((.output // "") | test("^(vacuous|skipped)")))] | length' "$1" ;;
      esac
    }

    # The scheduled audit (header). Prints the report; exits 1 only for a broken run.
    weekly_report() {
      local max_age=''${DOCTOR_MAX_AGE:-86400} now worst=0 d dir latest cur base prev f t age want n v ids old_ids
      now=$(date -u +%s)
      check_rules
      for d in fleet-doctor hygiene; do
        dir=$(state_dir "$d")
        latest="$dir/latest"
        case $d in hygiene) want=sarif ;; fleet-doctor) want=health ;; esac
        if [ ! -e "$latest" ]; then
          echo "$d: BROKEN: no published run ($latest is missing or dangling)"; worst=1; continue
        fi
        cur=$(readlink -f "$latest")
        base=$(basename "$cur")
        # `publish` names every run <UTC>.<ext>; that name IS the run time (a symlink's mtime
        # moves on every `ln -sfn`, the file's on every copy, so neither is trusted).
        if ! [[ $base =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z\.(sarif|json)$ ]]; then
          echo "$d: BROKEN: latest -> $base, not a name \`publish\` writes"; worst=1; continue
        fi
        t=$(date -u -d "''${BASH_REMATCH[1]}-''${BASH_REMATCH[2]}-''${BASH_REMATCH[3]}T''${BASH_REMATCH[4]}:''${BASH_REMATCH[5]}:''${BASH_REMATCH[6]}Z" +%s)
        age=$((now - t))
        if [ "$age" -gt "$max_age" ]; then
          echo "$d: BROKEN: latest run $base is $((age / 3600)) h old (limit $((max_age / 3600)) h): this week's run did not publish"
          worst=1; continue
        fi
        if ! validate "$cur" 2>"$dir/.weekly-validate.err"; then
          echo "$d: BROKEN: $base does not validate:"; sed 's/^/  /' "$dir/.weekly-validate.err"; worst=1; continue
        fi
        if [ "$(kind_of "$cur")" != "$want" ]; then
          echo "$d: BROKEN: $base is $(kind_of "$cur"), expected $want"; worst=1; continue
        fi
        rm -f "$dir/.weekly-validate.err"
        ids=$(finding_ids "$cur")
        n=$(grep -c . <<<"$ids" || true)
        if is_open "$cur"; then v="2 (findings or vacuous)"; else v="0 (clean)"; fi
        # The previous run: the newest published name that sorts before this one.
        prev=""
        for f in "$dir"/*; do
          f=$(basename "$f")
          [[ $f =~ ^[0-9]{8}T[0-9]{6}Z\.(sarif|json)$ ]] || continue
          [[ $f < $base ]] && prev=$f
        done
        echo "$d: verdict $v · $n findings · $(vacuous_count "$cur") vacuous/skipped · run $base"
        if [ -z "$prev" ]; then
          echo "  no previous run: nothing to diff (this run is the baseline)"
          if [ -n "$ids" ]; then while IFS= read -r f; do echo "  finding: $f"; done <<<"$ids"; fi
        elif ! validate "$dir/$prev" 2>/dev/null; then
          echo "  previous run $prev does not validate: no diff (this run is the baseline)"
          if [ -n "$ids" ]; then while IFS= read -r f; do echo "  finding: $f"; done <<<"$ids"; fi
        else
          old_ids=$(finding_ids "$dir/$prev")
          echo "  vs $prev: $(comm -13 <(echo "$old_ids") <(echo "$ids") | grep -c . || true) new · $(comm -12 <(echo "$old_ids") <(echo "$ids") | grep -c . || true) persisting · $(comm -23 <(echo "$old_ids") <(echo "$ids") | grep -c . || true) resolved"
          comm -13 <(echo "$old_ids") <(echo "$ids") | sed '/^$/d; s/^/  new: /'
        fi
      done
      if [ "$worst" -ne 0 ]; then
        echo "doctors-weekly: BROKEN RUN: heartbeat ${slug} gets /fail"
        return 1
      fi
      echo "doctors-weekly: ok (findings are not failures): heartbeat ${slug} gets success"
    }

    cmd=''${1:-}
    [ $# -gt 0 ] && shift
    case $cmd in
      rules)
        check_rules
        echo "catalogue ok: $(jq '[.rules[] | select(.doctor == "hygiene")] | length' "$rules") hygiene, $(jq '[.rules[] | select(.doctor == "fleet-doctor")] | length' "$rules") fleet-doctor rules" >&2
        ;;
      validate)
        [ $# -eq 1 ] || [ $# -eq 2 ] || usage
        check_rules
        validate "$1"
        if [ $# -eq 2 ]; then
          validate "$2"
          check_fd_hygiene "$1" "$2"
          echo "$1: FD-D-hygiene matches $2" >&2
        fi
        echo "$1: valid $(kind_of "$1")" >&2
        ;;
      hygiene-for)
        [ $# -eq 1 ] || [ $# -eq 2 ] || usage
        check_rules
        hygiene_for "$1" "''${2:-$(state_dir hygiene)/latest}"
        ;;
      verdict)
        [ $# -eq 1 ] || usage
        check_rules
        validate "$1" || exit 1
        case $(kind_of "$1") in
          sarif) open=$(jq '[.runs[0].results[] | select(.kind != "pass")] | length' "$1") ;;
          health) open=$(jq 'if .status == "pass" then 0 else 1 end' "$1") ;;
        esac
        if [ "$open" -eq 0 ]; then echo clean; exit 0; fi
        echo findings; exit 2
        ;;
      diff)
        [ $# -eq 2 ] || usage
        check_rules
        validate "$1" || exit 1
        validate "$2" || exit 1
        [ "$(kind_of "$1")" = "$(kind_of "$2")" ] || die "cannot diff a $(kind_of "$1") run against a $(kind_of "$2") run"
        jq -n --argjson old "$(finding_ids "$1" | jq -R . | jq -s .)" --argjson new "$(finding_ids "$2" | jq -R . | jq -s .)" \
          '{new: ($new - $old), resolved: ($old - $new), persisting: ($new - ($new - $old))}'
        ;;
      fingerprint)
        [ $# -eq 3 ] || usage
        printf '%s/%s\n' "$1" "$(printf '%s\n%s\n%s' "$1" "$2" "$3" | sha256sum | cut -c1-16)"
        ;;
      skeleton)
        [ $# -ge 2 ] || usage
        sha=$2
        [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "SUBJECT_SHA must be 40 hex characters"
        case $1 in
          hygiene)
            jq --arg sha "$sha" --arg uri "''${3:-https://github.com/kattakath/nix-config}" --arg branch "''${4:-main}" '{
              "$schema": "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json",
              version: "2.1.0",
              runs: [{
                tool: {driver: {name: "nix-hygiene", informationUri: "https://github.com/kattakath/nix-config/blob/main/.claude/skills/nix-hygiene/SKILL.md",
                  rules: [.rules[] | select(.doctor == "hygiene") | {id, shortDescription: {text: .shortDescription},
                    fullDescription: {text: ("detect: " + .detect + " | vacuous when: " + .vacuousWhen)},
                    defaultConfiguration: {level}, properties: {section, evidence}}]}},
                versionControlProvenance: [{repositoryUri: $uri, revisionId: $sha, branch: $branch}],
                results: []
              }]
            }' "$rules"
            ;;
          fleet-doctor)
            jq -n --arg sha "$sha" '{status: "pass", releaseId: $sha, serviceId: "fleet-doctor", checks: {}}'
            ;;
          *) usage ;;
        esac
        ;;
      publish)
        [ $# -eq 2 ] || usage
        case $1 in hygiene) ext=sarif ;; fleet-doctor) ext=json ;; *) usage ;; esac
        check_rules
        validate "$2" || exit 1
        dir=$(state_dir "$1")
        mkdir -p "$dir"
        out="$dir/$(date -u +%Y%m%dT%H%M%SZ).$ext"
        cp "$2" "$out"
        ln -sfn "$(basename "$out")" "$dir/latest"
        echo "$out"
        ;;
      weekly)
        case ''${1:-} in
          --no-ping) [ $# -eq 1 ] || usage; weekly_report ;;
          "")
            # Values only through `secret exec`'s environment, never argv; runitor reads
            # PING_KEY and sends the report (counts and finding IDs only) as the ping body.
            command -v secret >/dev/null || die "weekly: \`secret\` (the Home Manager profile) is not on PATH; nothing pinged"
            exec secret exec PING_KEY=${pingKeyItem} -- \
              runitor -slug "${slug}" -on-nonzero-exit fail -- "$0" weekly --no-ping
            ;;
          *) usage ;;
        esac
        ;;
      *) usage ;;
    esac
  '';
  meta.description = "Validate, diff and file a doctor run: SARIF 2.1.0 for /hygiene, health+json for /fleet-doctor (ADR-013)";
}
