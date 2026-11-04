# ---- The doctors' output contract (ADR-013 § 7–9) ----------------------------
#
# One file for the three pieces, because each is meaningless without the others:
# the rule catalogue (.claude/skills/doctors/rules.json, read by both doctor skills),
# `doctor-report` (packages/doctor-report.nix, which checks a run against it), and
# `checks.<system>.doctor-report-contract`, which proves the validator can FAIL.
#
# The contract check runs on every system: jq and check-jsonschema build on both, and the
# SARIF schema is a fixed-output fetch, so nothing here needs the network at check time.
_: {
  perSystem =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      fixtures = ../../packages/doctor-report-fixtures;
      # Each must be REJECTED. Listed, not globbed: a renamed or emptied fixture directory
      # must fail the check, not shrink it to a loop over nothing.
      brokenRuns = [
        "broken-sarif-vacuous-pass.sarif"
        "broken-sarif-unknown-rule.sarif"
        "broken-sarif-schema.sarif"
        "broken-sarif-missing-rule.sarif"
        "broken-sarif-no-fingerprint.sarif"
        "broken-sarif-level-chosen.sarif"
        "broken-sarif-date.sarif"
        "broken-health-vacuous-pass.health.json"
        "broken-health-not-worst.health.json"
        "broken-health-missing-check.health.json"
        "broken-health-count.health.json"
        "broken-health-not-array.health.json"
        "broken-health-wrong-key.health.json"
      ];
      brokenCatalogues = [
        "broken-rules-duplicate.json"
        "broken-rules-missing-field.json"
      ];
    in
    {
      packages.doctor-report = pkgs.callPackage ../../packages/doctor-report.nix {
        catalogue = ../../.claude/skills/doctors/rules.json;
      };

      apps.doctor-report = {
        type = "app";
        program = "${config.packages.doctor-report}/bin/doctor-report";
        meta.description = "Validate, diff and file a doctor run: SARIF 2.1.0 for /hygiene, health+json for /fleet-doctor (ADR-013)";
      };

      checks.doctor-report-contract =
        pkgs.runCommand "doctor-report-contract"
          {
            nativeBuildInputs = [
              config.packages.doctor-report
              pkgs.jq
            ];
          }
          ''
            set -u
            fail() { echo "doctor-report-contract: $*" >&2; exit 1; }
            expect() { # expect RC CMD... — the exact exit code, so "crashed" never passes as "rejected"
              want=$1; shift
              set +e; "$@" >log 2>&1; rc=$?; set -e
              [ "$rc" -eq "$want" ] || { cat log >&2; fail "'$*' exited $rc, expected $want"; }
            }
            set -e

            # 1. The REAL catalogue is well formed, and a full run built from it is valid SARIF
            #    and valid health+json. That proves the catalogue and the validator agree.
            doctor-report rules
            sha=0000000000000000000000000000000000000000
            doctor-report skeleton hygiene "$sha" >sk.sarif
            jq '.runs[0].results = [.runs[0].tool.driver.rules[]
                  | {ruleId: .id, kind: "pass", level: "none", message: {text: "contract"}, properties: {inputsExamined: 1}}]' \
              sk.sarif >full.sarif
            expect 0 doctor-report verdict full.sarif
            doctor-report skeleton fleet-doctor "$sha" >sk.json
            jq --slurpfile cat ${../../.claude/skills/doctors/rules.json} \
              '.checks = ($cat[0].rules | map(select(.doctor == "fleet-doctor")
                 | {key: .checkKey, value: [{ruleId: .id, status: "pass", observedValue: 0, inputsExamined: 1}]}) | from_entries)' \
              sk.json >full.json
            expect 0 doctor-report verdict full.json
            # An empty skeleton reports no rule, which is UNAUDITED, never clean.
            expect 1 doctor-report validate sk.sarif
            expect 1 doctor-report validate sk.json

            # 2. The fixtures, against their own four-rule catalogue.
            export DOCTOR_RULES=${fixtures}/rules.json
            expect 0 doctor-report verdict ${fixtures}/clean.sarif
            expect 2 doctor-report verdict ${fixtures}/good.sarif
            expect 0 doctor-report verdict ${fixtures}/clean.health.json
            expect 2 doctor-report verdict ${fixtures}/good.health.json
            doctor-report diff ${fixtures}/clean.sarif ${fixtures}/good.sarif >d.json
            jq -e '.new == ["NH-A-one/00112233aabbccdd"] and .resolved == [] and .persisting == []' d.json >/dev/null \
              || fail "diff clean→good did not report exactly one new finding: $(cat d.json)"
            doctor-report diff ${fixtures}/good.health.json ${fixtures}/clean.health.json >d.json
            jq -e '.resolved == ["FD-A-one/0011223344556677"] and .new == []' d.json >/dev/null \
              || fail "diff good→clean did not report exactly one resolved finding: $(cat d.json)"
            [ "$(doctor-report fingerprint NH-D-stale-count docs/x.md 'the count')" = \
              "$(doctor-report fingerprint NH-D-stale-count docs/x.md 'the count')" ] || fail "fingerprint is not stable"

            # 3. Every broken fixture is REJECTED (exit 1), each for its one broken clause.
            ${lib.concatMapStrings (f: ''
              expect 1 doctor-report validate ${fixtures}/${f}
            '') brokenRuns}
            ${lib.concatMapStrings (f: ''
              DOCTOR_RULES=${fixtures}/${f} expect 1 doctor-report rules
            '') brokenCatalogues}

            echo "doctor-report-contract: real catalogue ok; 4 good fixtures ok; ${
              toString (lib.length brokenRuns + lib.length brokenCatalogues)
            } broken fixtures rejected" >&2
            touch $out
          '';
    };
}
