# The li run-metadata log pipeline (ADR-011 § 4 exception): otelcol-contrib components that
# tail an operator tool's `*.log.jsonl` run logs and let ONLY allowlisted fields leave.
#
# Shared DATA, not a module: modules/home/claude-otel.nix splices it into the collector's
# Grafana config, and checks.<system>.li-runs-allowlist feeds fixture lines through the SAME
# attrsets with the real otelcol-contrib, so the test and the shipper cannot drift apart.
#
# FAIL-CLOSED BY CONSTRUCTION. The last statement is `keep_keys(attributes, allowlist)`, and
# the body becomes the event name, so a field the tool adds later is DROPPED by default.
# Nothing free-text survives: `msg` is read only through anchored captures with closed
# character classes, then deleted with everything else. No value from the logs is in this
# file — only field NAMES (this repo is public; the no-data rule).
#
# upstream-first: every stage is a stock otelcol-contrib component — `file_log` (json_parser,
# regex_parser, filter operators), `transform` (OTTL), `resource`, `file_storage`.
{ runsDir, storageDir }:
let
  # The flat stop counters, renamed c_<name>.
  counters = [
    "ad_pages"
    "list_pages"
    "robots"
    "other"
    "egress_trace"
    "failed_before_request"
    "redirects"
    "site_subresources"
    "site_subresources_answered"
    "site_subresources_blocked"
    "third_party"
    "third_party_answered"
    "third_party_blocked"
    "trackers_blocked"
  ];
  ev = e: ''attributes["event"] == "${e}"'';
in
rec {
  # Every field that may leave the Mac. Index label: none of these — service.name only.
  allowlist = [
    # every line (the last four come from the file name, not the line)
    "event"
    "level"
    "source"
    "run_id"
    "command"
    "variant"
    # request
    "req_kind"
    "status"
    "ms"
    "hops"
    "page"
    "ad_id"
    "redirected"
    # gone, challenge, preflight, probe
    "reason"
    "result"
    # stop
    "code"
    "stop_reason"
    "stop_scope"
    # run_card
    "card_command"
    "stage"
    "eta_s"
    "per_minute"
    "planned_ad"
    "planned_list"
    "planned_robots"
    # subresources
    "sub_blocked"
    "sub_answered"
    "sub_sent"
    "sub_pages"
  ]
  ++ map (c: "c_${c}") counters;

  extensions."file_storage/li_runs" = {
    directory = storageDir;
    create_directory = true;
  };

  receivers."file_log/li_runs" = {
    include = [ "${runsDir}/*.log.jsonl" ];
    # Tail from the end: no backfill on first start (older lines would fall outside
    # Loki's reject window anyway), and offsets persist in storageDir across restarts.
    start_at = "end";
    storage = "file_storage/li_runs";
    include_file_name = true;
    include_file_path = false;
    operators = [
      {
        type = "json_parser";
        # A line that is not JSON is dropped, never shipped raw.
        on_error = "drop_quiet";
        timestamp = {
          parse_from = "attributes.at";
          layout_type = "gotime";
          layout = "2006-01-02T15:04:05.999Z07:00";
        };
      }
      # Free-text framework lines (no `event` key) never leave.
      {
        type = "filter";
        expr = "attributes.event == nil";
      }
      # run_id, command and variant come from the file name: <ts>-<command>-<variant>-<hex6>.
      {
        type = "regex_parser";
        parse_from = ''attributes["log.file.name"]'';
        regex = "^(?P<rid_ts>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}_[0-9]{2}_[0-9]{2}Z)-(?P<command>[a-z]+(?:-[a-z]+)?)-(?P<variant>[a-z]+(?:-[a-z]+)*)-(?P<rid_hex>[0-9a-f]{6})\\.log\\.jsonl$";
        on_error = "send_quiet";
      }
    ];
  };

  processors = {
    "transform/li_runs" = {
      error_mode = "ignore";
      log_statements = [
        {
          context = "log";
          statements = [
            # ---- every line ----
            ''replace_pattern(attributes["rid_ts"], "_", ":")''
            ''set(attributes["run_id"], Concat([attributes["rid_ts"], attributes["command"], attributes["variant"], attributes["rid_hex"]], "-")) where attributes["rid_hex"] != nil''
            ''merge_maps(attributes, ExtractPatterns(attributes["logger"], "^(?P<source>[a-z_]+)\\.run$"), "upsert") where attributes["logger"] != nil''

            # ---- request ----
            ''set(attributes["req_kind"], attributes["kind"]) where ${ev "request"}''
            ''set(attributes["status"], "none") where ${ev "request"} and attributes["status"] == nil''
            ''set(attributes["ms"], Int(attributes["ms"])) where ${ev "request"} and attributes["ms"] != nil''
            # The ad id is the path's trailing digits; the path (it carries the ad's text
            # slug) is deleted by keep_keys below.
            ''merge_maps(attributes, ExtractPatterns(attributes["path"], "-(?P<ad_id>[0-9]+)$"), "upsert") where (${ev "request"} and attributes["kind"] == "ad") or ${ev "challenge"}''
            ''set(attributes["redirected"], true) where ${ev "request"} and attributes["final_path"] != nil and attributes["final_path"] != attributes["path"]''
            ''set(attributes["redirected"], false) where ${ev "request"} and attributes["final_path"] != nil and attributes["final_path"] == attributes["path"]''

            # ---- challenge: status and hops only, from the evidence block ----
            ''set(attributes["status"], attributes["evidence"]["status"]) where ${ev "challenge"}''
            ''set(attributes["hops"], attributes["evidence"]["hops"]) where ${ev "challenge"}''

            # ---- preflight ----
            ''set(attributes["result"], "refused") where ${ev "preflight"} and attributes["reason"] != nil''
            ''set(attributes["result"], "passed") where ${ev "preflight"} and attributes["reason"] == nil''

            # ---- stop: a closed-class capture of the reason, then the flat counters ----
            ''merge_maps(attributes, ExtractPatterns(attributes["msg"], "(?:STOPPED: |last: )(?P<stop_reason>[a-z_0-9]+) at "), "upsert") where ${ev "stop"}''
            ''set(attributes["stop_scope"], "budget") where ${ev "stop"} and attributes["stop_reason"] != nil and IsMatch(attributes["msg"], " challenges for ")''
            ''set(attributes["stop_scope"], "single") where ${ev "stop"} and attributes["stop_reason"] != nil and attributes["stop_scope"] == nil''
            ''set(attributes["stop_reason"], "egress_refused") where ${ev "stop"} and attributes["stop_reason"] == nil and IsMatch(attributes["msg"], "egress preflight failed")''
            ''set(attributes["stop_reason"], "completed") where ${ev "stop"} and attributes["stop_reason"] == nil and attributes["code"] == 0''
            ''set(attributes["stop_reason"], "other") where ${ev "stop"} and attributes["stop_reason"] == nil''
          ]
          ++ map (c: ''set(attributes["c_${c}"], attributes["counts"]["${c}"]) where ${ev "stop"}'') counters
          ++ [
            # ---- run_card: numbers and enums only ----
            ''set(attributes["card_command"], attributes["card"]["command"]) where ${ev "run_card"}''
            ''set(attributes["stage"], attributes["card"]["stage"]) where ${ev "run_card"}''
            ''set(attributes["eta_s"], attributes["card"]["scale"]["eta_s"]) where ${ev "run_card"}''
            ''set(attributes["per_minute"], attributes["card"]["scale"]["per_minute"]) where ${ev "run_card"}''
            ''set(attributes["planned_ad"], attributes["card"]["scale"]["planned"]["ad"]) where ${ev "run_card"}''
            ''set(attributes["planned_list"], attributes["card"]["scale"]["planned"]["list"]) where ${ev "run_card"}''
            ''set(attributes["planned_robots"], attributes["card"]["scale"]["planned"]["robots"]) where ${ev "run_card"}''

            # ---- subresources / probe: numeric or one-word captures of msg ----
            ''merge_maps(attributes, ExtractPatterns(attributes["msg"], "blocked (?P<sub_blocked>[0-9.]+)(?: / answered (?P<sub_answered>[0-9.]+))? / sent (?P<sub_sent>[0-9.]+) \\((?P<sub_pages>[0-9]+) pages\\)"), "upsert") where ${ev "subresources"}''
            ''merge_maps(attributes, ExtractPatterns(attributes["msg"], "^probe (?P<result>[a-z_]+)$"), "upsert") where ${ev "probe"}''
            # An unmatched optional group comes back as "", not absent.
            ''delete_key(attributes, "sub_answered") where attributes["sub_answered"] == ""''

            # ---- the allowlist: everything else is deleted, msg and path included ----
            "keep_keys(attributes, [${builtins.concatStringsSep ", " (map (k: ''"${k}"'') allowlist)}])"
            ''set(body, attributes["event"])''
          ];
        }
      ];
    };
    # One stream, like nixpi's journal (modules/nixos/alloy-shipper.nix): every field above
    # is per-line structured metadata, queried as {service_name="li-runs"} | event="stop".
    "resource/li_runs".attributes = [
      {
        key = "service.name";
        value = "li-runs";
        action = "upsert";
      }
    ];
  };

  pipeline = {
    receivers = [ "file_log/li_runs" ];
    processors = [
      "transform/li_runs"
      "resource/li_runs"
    ];
  };
}
