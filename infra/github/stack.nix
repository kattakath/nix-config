# ---- GitHub: repo settings, rulesets, the merge queue, Actions variables, one environment --
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
# error. Rename on GitHub first, then list it in `renamedRepos`, which renders the `moved`
# blocks (the drop guard reads them, so a move is not a drop).
#
# ORDER, declared: on Tier A, QUEUE_ENABLED makes own-branch PRs skip the heavy suite, so it
# must never exist without the merge_queue rule. `depends_on` creates the ruleset first.
#
# NOT DECLARED, on purpose:
#   - Actions SECRETS, the deploy environment's two included: the provider keeps a secret's
#     value in state (ADR-012 § 3).
#   - Pages and the vulnerability-alert settings (ADR-016 § 5): deleting either turns the
#     feature off. `pages`, `security_and_analysis` and `vulnerability_alerts` stay unset, so
#     the provider keeps reading them and never writes them.
#   - Private, archived and forked repos (no private name enters this public repo).
#
# REPOSITORIES (ADR-016 § 5, superseding the old "never declare github_repository"): every
# public repo in repo-settings.nix, with `lifecycle.destroy = false` (OpenTofu 1.12+; read at
# the pinned 1.13.9's resources/behavior.mdx): a destroy, a replace or a dropped entry becomes
# a FORGET, so tofu can never delete a repo. Every attribute is pinned at its live value
# (an unset one is sent as false or the provider default), so the first apply is import-only.
# Topics live on the same resource. `default_branch` is deprecated on it, so
# github_branch_default carries it. Rejected: archive_on_destroy (never read back, so every
# imported repo plans an update) and a wide ignore_changes (it declares nothing).
#   - Organization rulesets: the API answers 403 on the Free plan.
#   - Org package-creation policy and package visibility: neither has a REST endpoint (the
#     OpenAPI description has only GET/DELETE/restore on a package). Set by hand on
#     2026-11-25: org Settings > Packages allows Public + Private, and the
#     `devcontainer` container package is PUBLIC (irreversible; it bakes nothing
#     non-redistributable since then, which ci-closures-redistributable keeps true).
#
# VARIABLE VALUES: derivable ones are declared (QUEUE_ENABLED, GRAFANA_URL, ROLLUP_WRITER_SA).
# The rest are per-person data (the no-data rule): the wrapper reads each from GitHub at run
# time into a TF variable, so for those the stack owns EXISTENCE, not the value. A deleted
# one fails the read, so the plan errors loudly instead of reading clean. CI_BOT_CLIENT_ID is
# read once, from the org variable, so every personal-repo copy is checked against it.
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
  # Archived repos the stack has stopped managing (the `removed` blocks below).
  retiredRepos = [
    {
      owner = userOwner;
      repo = "dotfiles";
      # Its Actions variables (state addresses <slug>_<name>), forgotten with it.
      variables = [ "ci_bot_client_id" ];
    }
  ];
  # Renamed repos (the `moved` blocks below). Rename on GitHub FIRST: the variable and
  # default-branch resources look the NEW name up at plan time and force a replace on a 404
  # (provider 6.13.0 util_diff.go diffRepository); a live rename keeps the repo id, which
  # makes it an in-place update.
  renamedRepos = [
    {
      owner = userOwner;
      from = "workspace-studio";
      to = "free-rag";
      variables = [ "ci_bot_client_id" ];
    }
  ];
  repoSettings = import ./repo-settings.nix;
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
            # Read by the gws-chrome wrapper at run time; without either, that stack cannot plan.
            (mk "GWS_CUSTOMER_ID" "\${var.gws_customer_id}" { })
            (mk "GWS_CHROME_ORG_UNIT_ID" "\${var.gws_chrome_org_unit_id}" { })
          ]
          ++ lib.optional (owner == userOwner && repo == resumeSiteRepo) (
            mk "RESUME_JSON_GIST" "\${var.resume_json_gist}" { }
          )
        ) byRepo
      )
    ) repos
  );

  # One entry per public repo. Both owners have a `.github`, so the address carries the owner.
  repositoryEntries = lib.concatLists (
    lib.mapAttrsToList (
      owner: byRepo:
      lib.mapAttrsToList (repo: settings: {
        inherit owner repo;
        addr = "${if owner == orgOwner then "org" else "user"}_${slug repo}";
        id = repo;
        value =
          providerFor owner
          // removeAttrs settings [ "default_branch" ]
          // {
            name = repo;
            lifecycle = {
              destroy = false;
              # `archived` defaults to false and the provider PATCHes it on any update, so
              # a repo archived by hand would be UNARCHIVED by the next apply (provider
              # 6.13.0 resourceGithubRepositoryUpdate skips only when the new value is
              # true). Ignoring it keeps the live value, which makes that update a no-op.
              ignore_changes = [ "archived" ];
            };
          };
        branch = providerFor owner // {
          repository = "\${github_repository.${
            if owner == orgOwner then "org" else "user"
          }_${slug repo}.name}";
          branch = settings.default_branch;
          lifecycle.destroy = false;
        };
      }) byRepo
    ) repoSettings
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
    assert lib.assertMsg (lib.allUnique (
      map (e: e.addr) repositoryEntries
    )) "infra/github: two repos slug to one repository address";
    assert lib.assertMsg (
      lib.attrNames repoSettings == lib.attrNames repos
    ) "infra/github/repo-settings.nix must hold exactly the owners repos.nix holds";
    lib.id;
in
{
  terraform.required_providers.github.source = "integrations/github";

  # The default provider is the org; `github.user` is the operator's personal account.
  # One fine-grained token per owner (a fine-grained PAT covers exactly one): the default
  # reads GITHUB_TOKEN from the environment, the alias takes its own via a TF variable.
  provider.github = checked [
    { owner = orgOwner; }
    {
      alias = "user";
      owner = userOwner;
      token = "\${var.github_user_token}";
    }
  ];

  variable = {
    ci_bot_client_id = dataVar "The CI App's client id (org variable CI_BOT_CLIENT_ID).";
    rollup_sheet_id = dataVar "Drive id of the fleet-history Sheet (repo variable ROLLUP_SHEET_ID).";
    rollup_wif_provider = dataVar "The rollup's WIF provider path (repo variable ROLLUP_WIF_PROVIDER).";
    resume_json_gist = dataVar "website's RESUME_JSON_GIST (repo variable).";
    gws_customer_id = dataVar "The Workspace customer id (repo variable GWS_CUSTOMER_ID).";
    gws_chrome_org_unit_id = dataVar "The enrolled-browsers unit id (repo variable GWS_CHROME_ORG_UNIT_ID).";
    # A credential, not data, in the same sensitive-string shape (TF_VAR_github_user_token).
    github_user_token = dataVar "The ${userOwner} owner's fine-grained PAT (Keychain).";
  };

  import =
    # A repository and its default branch import by the bare repo name.
    lib.concatMap (
      e:
      map
        (
          type:
          {
            to = "${type}.${e.addr}";
            inherit (e) id;
          }
          // providerFor e.owner
        )
        [
          "github_repository"
          "github_branch_default"
        ]
    ) repositoryEntries
    ++ map (importOf "github_repository_ruleset") rulesetEntries
    ++ map (importOf "github_actions_variable") variableEntries
    ++ [
      {
        to = "github_actions_organization_variable.ci_bot_client_id";
        id = "CI_BOT_CLIENT_ID";
      }
      {
        to = "github_repository_environment.jsonresume_connect_production";
        id = "jsonresume-connect:production";
      }
    ];

  # RETIRED repos (ADR-016 § 8): archived on GitHub, so the stack stops managing them.
  # A `removed` block with destroy = false is a FORGET, never a delete (OpenTofu 1.7+);
  # their entries leave repo-settings.nix and repos.nix in the same change. The drop guard
  # still lists these addresses, and its override (GITHUB_ALLOW_DROPS=1) approves EVERY
  # dropped address, not just these: before typing yes, check its list names only them.
  removed = lib.concatMap (
    r:
    map
      (from: {
        inherit from;
        lifecycle.destroy = false;
      })
      (
        [
          "github_repository.${if r.owner == orgOwner then "org" else "user"}_${slug r.repo}"
          "github_branch_default.${if r.owner == orgOwner then "org" else "user"}_${slug r.repo}"
          "github_repository_ruleset.${slug r.repo}"
        ]
        ++ map (v: "github_actions_variable.${slug r.repo}_${v}") r.variables
      )
  ) retiredRepos;

  # RENAMED repos: each address that carries the slug moves to the new slug, so a rename is
  # an in-place update, never a replace (which prevent_destroy refuses).
  moved = lib.concatMap (
    r:
    let
      side = if r.owner == orgOwner then "org" else "user";
      pair = f: {
        from = f (slug r.from);
        to = f (slug r.to);
      };
    in
    [
      (pair (s: "github_repository.${side}_${s}"))
      (pair (s: "github_branch_default.${side}_${s}"))
      (pair (s: "github_repository_ruleset.${s}"))
    ]
    ++ map (v: pair (s: "github_actions_variable.${s}_${v}")) r.variables
  ) renamedRepos;

  # The deploy gate's reviewer, read by login so no account id is written here.
  data.github_user.operator = {
    provider = "github.user";
    username = userOwner;
  };

  resource = {
    # The one deploy gate in the fleet: a release there pushes to a live Apps Script
    # deployment, and this environment is what makes that wait for the operator
    # (read 2026-11-18: one required reviewer, protected branches only). Its two secrets
    # stay out, for the reason given for Actions secrets above. prevent_destroy because
    # deleting an environment deletes those secrets with it.
    github_repository_environment.jsonresume_connect_production = {
      provider = "github.user";
      repository = "jsonresume-connect";
      environment = "production";
      can_admins_bypass = true;
      prevent_self_review = false;
      reviewers = [ { users = [ "\${data.github_user.operator.id}" ]; } ];
      deployment_branch_policy = [
        {
          protected_branches = true;
          custom_branch_policies = false;
        }
      ];
      lifecycle.prevent_destroy = true;
    };
    github_repository = byAddr repositoryEntries;
    github_branch_default = lib.listToAttrs (
      map (e: lib.nameValuePair e.addr e.branch) repositoryEntries
    );
    github_repository_ruleset = byAddr rulesetEntries;
    github_actions_variable = byAddr variableEntries;
    github_actions_organization_variable.ci_bot_client_id = {
      variable_name = "CI_BOT_CLIENT_ID";
      value = "\${var.ci_bot_client_id}";
      visibility = "all";
    };
  };
}
