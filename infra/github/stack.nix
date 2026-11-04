# ---- GitHub: rulesets, the merge queue and Actions variables across the fleet repos -----
#
# ADR-012 step 3, GitHub half (docs/declarative-gaps-adr.md § 3 row 2). Rendered by
# modules/parts/terranix.nix (`github-plan` / `github-apply`); state encrypted in the shared
# GCS bucket like the others. Scope is the operator's two GitHub owners only (repos.nix).
#
# ADOPTED, NOT CREATED: every object predates this stack and has an `import` block, which is
# also the empty-state guard (the grafana stack's shape): with state lost, each block
# re-adopts its live object instead of creating a duplicate. The wrapper refuses an
# empty-state run where the import count and the resource count differ.
#
# ONE SOURCE FOR THE RULESET SHAPE: `kattakath/.github`'s rulesets/{main,merge-queue}.json,
# read from the pinned `kattakath-dotgithub` input. Its scripts/apply-ruleset.sh writes the
# same files, so the two writers converge instead of fighting. On 2026-11-03 all 15 default-
# branch rulesets matched those files exactly (apply-ruleset.sh's own normalisation).
# Provider 6.13.0 does not model three pull_request fields the API returns
# (required_reviewers, dismissal_restriction, require_extra_approval_for_unattributed_changes;
# `-generate-config-out` omits them), so a drift in those three is invisible here.
#
# RENAMES: a changed repo name or slug is a REPLACE, which prevent_destroy turns into a plan
# error. Move the address with a `moved` block instead.
#
# ORDER, declared: on Tier A, QUEUE_ENABLED makes own-branch PRs skip the heavy suite, so it
# must never exist without the merge_queue rule. `depends_on` creates the ruleset first.
#
# NOT DECLARED, on purpose:
#   - Actions SECRETS: the provider keeps a secret's value in state (ADR-012 § 3).
#   - `github_repository`: an import adopts ~36 attributes (description, topics, visibility,
#     security_and_analysis, has_*), far past the merge settings, and a destroy of it DELETES
#     the repo. The ruleset's allowed_merge_methods = ["squash"] already enforces the merge
#     method on the default branch; apply-ruleset.sh keeps setting the three repo flags.
#   - Organization rulesets: the API answers 403 on the Free plan.
#
# VARIABLE VALUES: derivable ones are declared (QUEUE_ENABLED, GRAFANA_URL, ROLLUP_WRITER_SA).
# The rest are per-person data (the no-data rule): the wrapper reads each from GitHub at run
# time into a TF variable, so for those the stack owns EXISTENCE, not the value. A deleted
# one fails the read, so the plan errors loudly instead of reading clean. CI_BOT_CLIENT_ID is
# read once, from the org variable, so the nine personal-repo copies are checked against it.
{
  lib,
  rulesetTemplates,
  orgOwner,
  # The operator's user account, the one other owner in repos.nix.
  userOwner,
  # This repo (config.fleet.repoName), whose Actions carry the rollup variables.
  fleetRepo,
  # The userOwner repo whose Actions read RESUME_JSON_GIST (modules/parts/terranix.nix).
  resumeSiteRepo,
  grafanaUrl,
  rollupWriterSa,
  ...
}:
let
  repos = import ./repos.nix;
  readTemplate = f: builtins.fromJSON (builtins.readFile "${rulesetTemplates}/rulesets/${f}");

  # An address-safe name: `.github` -> dotgithub, `kattakath.github.io` -> kattakath_github_io.
  slug =
    repo:
    lib.replaceStrings [ "." "-" ] [ "_" "_" ] (
      if lib.hasPrefix "." repo then "dot" + lib.removePrefix "." repo else repo
    );
  providerFor = owner: lib.optionalAttrs (owner != orgOwner) { provider = "github.user"; };

  # The REST shape (a list of typed rules) -> the provider's one `rules` block.
  unmodelled = [
    "required_reviewers"
    "dismissal_restriction"
    "require_extra_approval_for_unattributed_changes"
  ];
  toRule =
    r:
    if r.type == "pull_request" then
      { pull_request = removeAttrs r.parameters unmodelled; }
    else if r.type == "required_status_checks" then
      {
        required_status_checks = {
          inherit (r.parameters) do_not_enforce_on_create strict_required_status_checks_policy;
          required_check = map (c: {
            inherit (c) context integration_id;
          }) r.parameters.required_status_checks;
        };
      }
    else if r.type == "merge_queue" then
      { merge_queue = r.parameters; }
    else if
      lib.elem r.type [
        "creation"
        "deletion"
        "update"
        "non_fast_forward"
        "required_linear_history"
        "required_signatures"
      ]
      && !(r ? parameters)
    then
      { ${r.type} = true; }
    else
      throw "infra/github: ruleset rule type '${r.type}' has no mapping to the provider schema";

  toRuleset =
    owner: repo: api:
    providerFor owner
    // {
      inherit (api) name target enforcement;
      repository = repo;
      conditions.ref_name = api.conditions.ref_name;
      inherit (api) bypass_actors;
      rules = lib.foldl' (acc: r: acc // toRule r) { } api.rules;
      # A destroy drops the branch protection, and with Tier A's QUEUE_ENABLED still set an
      # own-branch PR would merge with the suite skipped.
      lifecycle.prevent_destroy = true;
    };

  # Tier is derived from the owner (repos.nix header); the queue rule only on Tier A.
  mainTemplate =
    owner:
    let
      base = readTemplate "main.json";
    in
    if owner == orgOwner then
      base // { rules = base.rules ++ [ (readTemplate "merge-queue.json") ]; }
    else
      base;

  # The one bespoke ruleset (repos.nix): release tags may not be deleted, moved or forced.
  releaseTags = {
    name = "release tags";
    target = "tag";
    enforcement = "active";
    conditions.ref_name = {
      include = [ "refs/tags/v*" ];
      exclude = [ ];
    };
    bypass_actors = [ ];
    rules = map (type: { inherit type; }) [
      "deletion"
      "non_fast_forward"
      "update"
    ];
  };

  rulesetEntries = lib.concatLists (
    lib.mapAttrsToList (
      owner: byRepo:
      lib.concatLists (
        lib.mapAttrsToList (
          repo: ids:
          [
            {
              inherit owner repo;
              addr = slug repo;
              id = ids.main;
              value = toRuleset owner repo (mainTemplate owner);
            }
          ]
          ++ lib.optional (ids ? releaseTags) {
            inherit owner repo;
            addr = "${slug repo}_release_tags";
            id = ids.releaseTags;
            value = toRuleset owner repo releaseTags;
          }
        ) byRepo
      )
    ) repos
  );

  # Variables: one entry per (repo, name). `value` is a literal or a `var.*` reference.
  variableEntries = lib.concatLists (
    lib.mapAttrsToList (
      owner: byRepo:
      lib.concatLists (
        lib.mapAttrsToList (
          repo: _:
          let
            mk = name: value: extra: {
              inherit owner repo name;
              addr = "${slug repo}_${lib.toLower name}";
              value =
                providerFor owner
                // {
                  repository = repo;
                  variable_name = name;
                  inherit value;
                }
                // extra;
            };
          in
          (
            if owner == orgOwner then
              [ (mk "QUEUE_ENABLED" "true" { depends_on = [ "github_repository_ruleset.${slug repo}" ]; }) ]
            else
              [ (mk "CI_BOT_CLIENT_ID" "\${var.ci_bot_client_id}" { }) ]
          )
          ++ lib.optionals (owner == orgOwner && repo == fleetRepo) [
            (mk "GRAFANA_URL" grafanaUrl { })
            (mk "ROLLUP_SHEET_ID" "\${var.rollup_sheet_id}" { })
            (mk "ROLLUP_WIF_PROVIDER" "\${var.rollup_wif_provider}" { })
            (mk "ROLLUP_WRITER_SA" rollupWriterSa { })
          ]
          ++ lib.optional (owner == userOwner && repo == resumeSiteRepo) (
            mk "RESUME_JSON_GIST" "\${var.resume_json_gist}" { }
          )
        ) byRepo
      )
    ) repos
  );

  byAddr = entries: lib.listToAttrs (map (e: lib.nameValuePair e.addr e.value) entries);
  importOf =
    type: e:
    {
      to = "${type}.${e.addr}";
      id = "${e.repo}:${toString (e.id or e.name)}";
    }
    // providerFor e.owner;

  # sensitive: keeps the ids out of saved plan output (the drift check's logs).
  dataVar = description: {
    type = "string";
    sensitive = true;
    inherit description;
  };
  # Inside a value, not around the module: a top-level assert forces the module arguments
  # while the module system is still computing them (infinite recursion).
  checked =
    assert lib.assertMsg (repos ? ${orgOwner}) "infra/github/repos.nix has no '${orgOwner}' owner";
    assert lib.assertMsg (
      userOwner != orgOwner && repos ? ${userOwner}
    ) "infra/github/repos.nix has no '${userOwner}' owner";
    assert lib.assertMsg (
      lib.length (lib.attrNames repos) == 2
    ) "infra/github/repos.nix must hold exactly the org and the personal owner";
    # The variable entries match on these names with lib.optional(s), so a rename that
    # missed repos.nix would silently drop the variables instead of failing.
    assert lib.assertMsg (
      repos.${orgOwner} ? ${fleetRepo}
    ) "infra/github/repos.nix has no '${orgOwner}/${fleetRepo}' (fleetRepo)";
    assert lib.assertMsg (
      repos.${userOwner} ? ${resumeSiteRepo}
    ) "infra/github/repos.nix has no '${userOwner}/${resumeSiteRepo}' (resumeSiteRepo)";
    assert lib.assertMsg (lib.allUnique (
      map (e: e.addr) (rulesetEntries ++ variableEntries)
    )) "infra/github: two repos slug to one resource address";
    lib.id;
in
{
  terraform.required_providers.github.source = "integrations/github";

  # The default provider is the org; `github.user` is the operator's personal account.
  provider.github = checked [
    { owner = orgOwner; }
    {
      alias = "user";
      owner = userOwner;
    }
  ];

  variable = {
    ci_bot_client_id = dataVar "The CI App's client id (org variable CI_BOT_CLIENT_ID).";
    rollup_sheet_id = dataVar "Drive id of the fleet-history Sheet (repo variable ROLLUP_SHEET_ID).";
    rollup_wif_provider = dataVar "The rollup's WIF provider path (repo variable ROLLUP_WIF_PROVIDER).";
    resume_json_gist = dataVar "website's RESUME_JSON_GIST (repo variable).";
  };

  import =
    map (importOf "github_repository_ruleset") rulesetEntries
    ++ map (importOf "github_actions_variable") variableEntries
    ++ [
      {
        to = "github_actions_organization_variable.ci_bot_client_id";
        id = "CI_BOT_CLIENT_ID";
      }
    ];

  resource = {
    github_repository_ruleset = byAddr rulesetEntries;
    github_actions_variable = byAddr variableEntries;
    github_actions_organization_variable.ci_bot_client_id = {
      variable_name = "CI_BOT_CLIENT_ID";
      value = "\${var.ci_bot_client_id}";
      visibility = "all";
    };
  };
}
