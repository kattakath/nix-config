# macOS host config for "macos" (Apple Silicon, aarch64-darwin) — the fleet's
# sole client Mac. No public tunnel / inbound SSH from the internet; the machine
# may still run local agent services (MCP gateway) and a self-hosted GitLab CI
# runner for private pipelines (civitai-live-wallpaper, now under the gitlab.com/izzykatt
# group — see `local.tart.gitlabRunner` below; gitlab-runner moved OFF brew 2026-09-05).
# Home Manager and the nix-vscode-extensions overlay are wired centrally by
# mkDarwin in modules/parts/compose.nix — this file only provides host-specific settings.
#
# First activation (after Determinate Nix is installed, before darwin-rebuild is
# on PATH) — a single line straight from the flake (the darwin analog of nixpi's
# `nixos-rebuild switch --flake .#nixpi`; see modules/parts/packages.nix's apps.<system>.macos):
#   nix run github:kattakath/nix-config#macos
# Thereafter: sudo darwin-rebuild switch --flake .#macos
{
  config,
  pkgs,
  loginName,
  ...
}:
let
  # The ONE GitHub App both self-hosted runner lanes authenticate as —
  # "ismailkattakath-ci", operator-owned and public. It was spelled twice, 68
  # lines apart, in two `let` scopes that cannot see each other: once for the
  # bare-metal lane and once inside `local.tart`'s `fleetApp`. Three comments in
  # this file already say the two lanes share one App, and App rotation is
  # already a documented multi-file ritual (secrets/secrets.nix) — 4689619,
  # 4845230 and 4243998 were all retired on 2026-09-06 — so leaving the id
  # duplicated added a fourth place to forget. `installationId` legitimately
  # differs per lane and stays at each call site.
  fleetAppId = 4849830;
in
{
  imports = [
    ../modules/darwin/claude-managed-settings.nix
    ../modules/darwin/core.nix
    ../modules/darwin/github-runner.nix
    ../modules/darwin/launchd-reconcile.nix
    ../modules/darwin/logging.nix
    ../modules/darwin/ollama-daemon.nix
  ];

  # Root-owned Claude Code policy at /Library/Application Support/ClaudeCode/
  # managed-settings.json — the tier that outranks user, project and `--settings`
  # scope. It carries the secret-value denies and the no-AI-attribution keys, and
  # it ADDS to the user-scope floor in modules/home/claude-guardrails.nix
  # rather than replacing it (deny lists from several scopes combine); each scope
  # reaches sessions the other cannot. Setting this to `false` and re-running
  # `activate` REMOVES the file — it does not merely stop rewriting it — so the
  # kill switch is real. Every key's justification lives in that module's header.
  local.claudeManagedSettings.enable = true;

  # ONE ollama for the whole machine. The per-user agent could not be shared:
  # it lives in a single login session and keeps its models in that user's home,
  # so a second account meant either a duplicate 31 GB store or a server that
  # vanished whenever the operator logged out. `modules/home/default.nix` sets
  # `local.rag.ollama.manageServer = false` so the capsule stops standing up a
  # competing one — two servers on 11434 means one wins and the other flaps.
  local.ollamaDaemon.enable = true;

  # `local.ytDlpWebUi` and `local.meTube` used to be enabled here, at DARWIN
  # scope. Both are Home Manager modules since 2026-09-22 — their enables moved
  # into the `home-manager.users.${loginName}` block below.

  # Machine-wide CLIs — the mechanism for "shared between both accounts". A
  # systemPackages entry is ONE store path on PATH for every user, so neither
  # profile has to declare it and neither can drift to a different version.
  #
  # grok and Antigravity were per-user `curl … | bash` installs until
  # 2026-09-15 and 2026-09-16 respectively; their packages pin the vendor
  # artifacts instead. Per-user state remains in ~/.grok and ~/.antigravity.
  environment.systemPackages = [
    (pkgs.callPackage ../packages/grok.nix { })
    (pkgs.callPackage ../packages/antigravity-cli.nix { })
    # acpx — the headless ACP client that drives the three agents above as PEERS
    # rather than as separate terminals. Machine-wide for the same reason they
    # are: it is a client, all per-session state is in its arguments, and the
    # alternative (`npm i -g acpx`) is a per-user install outside the store.
    # Node floor matters here — see packages/acpx.nix; it pins nodejs_22 itself
    # because the fleet default is 20.x and acpx requires >=22.13.
    (pkgs.callPackage ../packages/acpx.nix { })
    # Claude Code — re-exposed from the HM module, not re-packaged: `finalPackage`
    # is the MCP-wrapped binary programs.claude-code already builds, so this is the
    # same store path HM installs, just ALSO linked into /run/current-system/sw/bin.
    # Why: GUI agent hosts (Open Design) probe a hardcoded dir list that includes
    # /run/current-system/sw/bin and ~/.nix-profile/bin but NOT
    # /etc/profiles/per-user/<user>/bin, where HM's useUserPackages puts it — so
    # grok/agy were detected and claude was not.
    config.home-manager.users.${loginName}.programs.claude-code.finalPackage
    # fal.ai — `fal` (the vendor's deploy CLI) and `fal-gen` (inference). Cloud
    # inference, unlike the rest of the media stack, which runs against the
    # local ollama daemon; it bills, and it needs FAL_KEY in the Keychain.
    (pkgs.callPackage ../packages/fal.nix { })
  ];

  nixpkgs.config.allowUnfree = true;

  # System-wide, into /Library/Fonts/Nix Fonts (nix-darwin's fonts.packages,
  # verified 2026-09-30 by building the derivation and checking: pkgs.noto-fonts
  # itself ships NotoSansMalayalam.ttf + NotoSerifMalayalam.ttf directly, no
  # split "noto-fonts-malayalam" package exists). Makes the font SELECTABLE
  # everywhere (Font Book, any app's font picker) — it does not make anything
  # use it automatically. There is no Chromium policy for per-script font
  # choice (checked: absent from the official policy docs, and grepped the
  # installed Chromium Framework binary itself for any PerScript*/font-policy
  # string — none), so Chromium is pointed at these faces by
  # `local.ungoogledChromium.malayalamFontSetter` instead — a repo-authored sideloaded
  # extension, the only mechanism that can (`chrome.fontSettings.setFont` is
  # extension-only). That option's description carries the full why, including
  # the two non-extension routes that were tried and failed.
  fonts.packages = [ pkgs.noto-fonts ];

  # ---- Self-hosted GitHub Actions runner(s) for dontsell-ai ------------------
  # See modules/darwin/github-runner.nix for the full why/how. Org-level
  # registration serves every dontsell-ai repo (app, idea, ...) from this one
  # config, not just whichever repo happened to need it first. count = 2:
  # dontsell-ai/app's ci.yml fans one push into 7 parallel jobs; two instances
  # let two run at once instead of the whole backlog draining one job at a time
  # through a single runner (12 cores / 36GB on this Mac — comfortable headroom).
  #
  # appId/installationId: the "ismailkattakath-ci" App (4849830) — the SAME App
  # the Tart lane below uses. Neither value is secret on its own.
  #
  # 2026-09-06: this lane used to have its own App, "dontsell-ai" (4689619),
  # org-owned and granted only Organization/Self-hosted-runners RW. That was
  # retired because it stopped buying anything: ismailkattakath-ci is already
  # installed on dontsell-ai with repos=all, so the broader access existed
  # regardless, and a second narrow credential for the same job was defence in
  # depth that depth no longer had. (It WOULD still be worth keeping if
  # dontsell-ai were a third party who might need to revoke this Mac's access
  # without touching a personal account — it is not.)
  #
  # WHY THERE ARE STILL TWO AGENIX SECRETS FOR ONE APP: an agenix secret has
  # exactly one owner, and these two lanes run as different users —
  # gh-app-dontsell-ai-key is owned by `_github-runner` (these launchd DAEMONS)
  # and gh-app-fleet-key by the login user (the Tart USER AGENTS, which need a
  # GUI session). Same key material, two files, because of OS ownership rather
  # than credential separation. Consolidating Apps does not consolidate these.
  #
  # Both .age files therefore have to be re-encrypted together when the App key
  # rotates. Use `age -R` directly, NOT `agenix -e` (which silently encrypts
  # empty stdin when non-interactive), and verify the recipient tags match the
  # file being replaced.
  # OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
  local.macosGithubRunner = {
    enable = true;
    org = "dontsell-ai";
    appId = fleetAppId;
    installationId = 159496676;
    count = 2;
  };

  # ---- Ephemeral Tart-VM CI runners (local.tart.githubRunners.*, the tart-vms capsule) --
  # Every job gets a disposable macOS VM; the VM is the isolation boundary.
  # All instances share ONE fleet GitHub App ("ismailkattakath-ci", public,
  # appId 4849830, owned by the OPERATOR's personal account, not an org) and
  # its single agenix-delivered key below; each scope has its own
  # installationId.
  #
  # Consolidated 2026-09-06 from two Apps into this one. It replaced BOTH
  # "kattakath-fleet-ci" (4845230, runners) and "kattakath-ci" (4243998, the
  # Actions CI bot behind auto-merge and update-flake-lock), which is why its
  # permission set is the UNION of the two roles:
  #   Repository:   Contents RW, Pull requests RW, Actions RW, Metadata R
  #   Organization: Self-hosted runners RW
  # Deliberately NOT granted: Repository/Administration. The fleet App carried
  # it, but it is only needed for REPO-scoped runner registration and every
  # lane here is org-scoped — so it stayed off. Adding `scope.type = "repo"`
  # later needs that grant first.
  #
  # THE COST, recorded so it is a decision and not a surprise: App permissions
  # are App-GLOBAL, not per-installation (verified — all installations report
  # an identical set). So any key for this App can push to every repo in every
  # account it is installed on. Consolidating two Apps into one traded that
  # away for a single rotation surface; the previous split kept the Actions key
  # off this machine and the runner key unable to push code.
  #
  # Partly bought back 2026-09-06: agenix and the kattakath org secret
  # CI_BOT_APP_PRIVATE_KEY now hold TWO DIFFERENT keys of this same App, so
  # either is revocable alone (see secrets/secrets.nix for the fingerprints).
  # That is independent REVOCATION only — the permission blast radius above is
  # unchanged, because it is a property of the App, not of the key.
  #
  # The bare-metal dontsell lane above now uses this SAME App (4849830); its
  # own "dontsell-ai" App (4689619) was retired the same day — see that block.
  #
  # The two bare-metal dontsell runners
  # above STAY for that org's nix/cachix/pgvector-heavy CI (the Cirrus guest
  # image carries none of that toolchain) — dontsell workflows opt into VM
  # isolation with `runs-on: [self-hosted, tart, dontsell-vm]`. Apple caps
  # concurrent macOS guests at TWO; the module's slot semaphore shares that
  # budget across all three instances (asserted at eval).
  # The base clone AND the SSH host-key pin are content-keyed by oci@digest, so
  # bumping the digest below renames both — one elected instance re-pulls and
  # re-pins itself on its next cycle; the other two share that image/base/pin.
  # `tart-runner-setup-kattakath [image|pin|all]` pre-warms a bump by hand.
  # Slots, pins and both lanes' logs live in local.tart.runnerStateDir
  # (~/.local/state/tart-runner) — durable by assertion, never /tmp.
  age.secrets."gh-app-fleet-key" = {
    file = ../secrets/gh-app-fleet-key.age;
    owner = loginName;
    mode = "0400";
  };
  # The GitLab lane's glrt- runner token (runner "macos-ismail-dev",
  # gitlab.com). local.tart.gitlabRunner's agent renders config.toml from it at
  # start — the token never enters the store; secrets/secrets.nix has the
  # registration/rotation story.
  age.secrets."gitlab-runner-token" = {
    file = ../secrets/gitlab-runner-token.age;
    owner = loginName;
    mode = "0400";
  };
  # OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
  local.tart =
    let
      fleetApp = {
        appId = fleetAppId;
        privateKeyPath = config.age.secrets."gh-app-fleet-key".path;
        image = {
          oci = "ghcr.io/cirruslabs/macos-runner:tahoe";
          # Resolved 2026-09-05; bump deliberately (a moving tag is refused).
          digest = "sha256:98acf50794306bc293f2e30e40115f1452772e4e17eb257968b7c98f39ebf231";
        };
      };
    in
    {
      githubRunners = {
        # DISABLED 2026-09-06, and the reason is the whole design constraint:
        # a lane holds its guest slot for the ENTIRE long-poll wait, not just
        # while a job runs. Measured — these two sat up for an hour with 0.0%
        # CPU, 8192 MB each of 36 GB, holding BOTH of Apple's two concurrent
        # macOS guests, having run zero jobs. Neither org has a single workflow
        # targeting a self-hosted runner (verified across all 63 repos), so the
        # cost bought nothing and starved dontsell-vm, which never acquired a
        # slot after coming up at 08:04:56.
        #
        # Re-enable when a workflow in that org actually needs macOS — and
        # preferably only after the controller provisions on demand rather than
        # pre-booting a guest to wait. Keeping the scope/installationId here so
        # re-enabling is a one-word change, not a re-derivation.
        kattakath = fleetApp // {
          enable = false;
          scope = {
            type = "org";
            value = "kattakath";
          };
          installationId = 159496730;
        };
        silvercreek = fleetApp // {
          enable = false;
          scope = {
            type = "org";
            value = "silvercreek-ai";
          };
          installationId = 159496756;
        };
        # Re-enabled 2026-09-06 after the label flip closed a real misroute.
        # GitHub matching is case-insensitive and a runner matches on a SUPERSET,
        # so this lane's {self-hosted, macOS, arm64, tart, dontsell-vm} answered
        # dontsell-ai/app's jobs when they asked for only
        # {self-hosted, macOS, ARM64} — and those jobs need nix/cachix/postgres
        # from the HOST, which a stock Cirrus guest does not have.
        #
        # Closed in the only place it CAN be closed, consumer-side: app's 10
        # `runs-on:` entries now require `nix` (dontsell-ai/app 1332beb), a label
        # only the bare-metal lane carries. Adding `nix` to that lane made the
        # flip possible; the consumer edit is what actually closed it.
        #
        # KEEP BOTH SIDES POSITIVE. Do not "simplify" by dropping `tart` here or
        # `nix` there — GitHub has no negative selector, so a lane identified
        # only by the ABSENCE of a label is exactly how this collision happened.
        dontsell-vm = fleetApp // {
          scope = {
            type = "org";
            value = "dontsell-ai";
          };
          installationId = 159496676;
        };
      };

      # GitLab lane on the SAME slot budget (civitai pipeline): declarative
      # gitlab-runner → Tart custom executor. Replaced the brew service +
      # hand-edited ~/.gitlab-runner/config.toml on 2026-09-05; registration
      # (minting the glrt- token) stays the one-time manual act.
      gitlabRunner = {
        enable = true;
        runnerName = "macos-ismail-dev";
        runnerId = 54669377;
        tokenFile = config.age.secrets."gitlab-runner-token".path;
        concurrent = 2;
        # civitai-live-wallpaper's .gitlab-ci.yml was written for the SHELL runner
        # this replaced, so its jobs name no `image:`; every one failed in prepare
        # until this existed (main red since 2026-08-04's last green). The same
        # digest-pinned image the GitHub lane uses, so it is already on disk.
        # Written as <repo>@<digest>, tag dropped: that is the name Tart stores it under.
        defaultImage = "${builtins.head (builtins.split ":" fleetApp.image.oci)}@${fleetApp.image.digest}";
      };
    };

  # Stable identity for host-gated modules (login openers, RAG launchd, …) AND the
  # machine's declared name, so it's config-owned rather than manual scutil drift.
  # computerName is the Settings ▸ About ▸ Name; localHostName (the `.local` name)
  # defaults from hostName, so these two cover all three scutil names.
  networking.hostName = "macos";
  networking.computerName = "macos";

  users.users.${loginName} = {
    name = loginName;
    home = "/Users/${loginName}";
  };

  # ---- Per-session MCP launchers (modules/home/{gmail-mcp,plugin-mcp}.nix,
  # home-manager options — set via home-manager.users)
  # The operator's COMPLETE Gmail roster. All four are the operator's own
  # accounts under identities already public elsewhere in this very tree:
  # userEmail = ismail@kattakath.com (identityArgs) and its namesake domain;
  # silvercreek.ai, whose production WordPress the `wordpress` launcher below
  # drives; and the operator's `aloshy` handle (the aloshy.ai
  # zone). The private nix-personal flake used to ADD further accounts via
  # extraHomeModules; it was fully retired 2026-09-15, and the operator chose to
  # keep only the two below from its list of seven (#524), so this list is now
  # the whole set. Anyone else's address still never belongs here — see the
  # option's description in modules/home/gmail-mcp.nix.
  #
  # A FUNCTION, not a bare attrset, matching modules/home/default.nix's own
  # signature: home-manager passes module args here, and the `_` keeps the door
  # open for a block below that needs one. (It was `publicMcpServers` until the
  # gateway was deleted 2026-10-02; nothing reads an arg here today.)
  home-manager.users.${loginName} = _: {
    # OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
    # The SAME four accounts, now on the plugin lane instead of the gateway. Launchers
    # land on PATH as `nix-mcp-gmail-<sanitised-address>`; the gmail plugin in
    # github:kattakath/skills names them in its own `.mcp.json`, so Claude Code spawns
    # one stdio server per account per session — nothing shared, nothing listening.
    # This is now the ONLY list: the parallel `local.mcpGateway.gmail.accounts` went
    # with the gateway in #734.
    local.gmailMcp.accounts = [
      "ismail@kattakath.com"
      "ismailkattakath@gmail.com"
      "izzy@silvercreek.ai"
      "aloshyakasoto@gmail.com"
    ];

    # The three CREDENTIALED servers the gateway owned that no EXISTING plugin could
    # carry — the "wordpress, apify, … local postgres" part of the cost the purge
    # accepted. Launchers land on PATH as `nix-mcp-<name>`; in
    # github:kattakath/skills the new `wordpress` and `apify` plugins name theirs, and
    # `postgres` goes to the EXISTING `rag` plugin, whose own SKILL.md already said it
    # "runs entirely local via the postgres MCP server" — it owned this in documentation
    # before it owned it in code.
    #
    # Each was checked LIVE before being declared, because a plugin for a dead endpoint
    # is worse than no plugin (see modules/home/plugin-mcp.nix for the probes):
    # silvercreek.ai's REST API answers and only authentication gates it, and the
    # pgvector store is listening on loopback. All three then completed a real MCP
    # `initialize` through their launcher.
    #
    # `wordpress-adapter` is NOT here and must not be added: that is a DIFFERENT endpoint
    # on the same site and its route is gone (404 `rest_no_route`) — the failure that
    # darked all 25 gateway servers.
    local.pluginMcp.servers = [
      "wordpress"
      "apify"
      "postgres"
    ];
    # ---- AWS CLI: tool + shape, content stays local (ADR-004 phase 3) -------
    # Until 2026-09-20 this block carried `programs.awscli.settings` with two real
    # account ids and an SSO start-URL id — reconnaissance in a public repo
    # (ADR-004 §7, inventory #1). The cloud-cli capsule now installs the CLI and
    # writes ~/.aws/config.example; the real ~/.aws/config is the operator's,
    # written by `aws configure sso` / by hand, outside Nix and git. The first
    # activation after this change keeps the existing profiles: `adoptAwsConfig`
    # (modules/home/claude-bedrock-gate.nix) turns the leftover store symlink
    # into a real 0600 file instead of letting orphan cleanup delete it.
    # Claude Code's Bedrock profile is still selected at runtime with
    # `secret set AWS_PROFILE <profile>`.
    local.cloudCli.aws.enable = true;

    # ---- Infin8 LiteLLM proxy — REMOVED 2026-09-29 -------------------------
    # `OPENAI_BASE_URL` + `OPENAI_API_BASE` pointed at https://ai.infin8it.ca/v1.
    # That host is GONE: `dig ai.infin8it.ca` returns zero A-records and a request
    # to /v1/models fails to connect (verified 2026-09-29). The LiteLLM gateway it
    # fronted was itself wound down upstream — see takeoff-api-infra's
    # docs/ai/litellm-not-deployed.md, where the platform (#827), the CDK construct
    # (#1452) and the app package were all deleted.
    #
    # Pointing these at a dead host is worse than leaving them unset: the OpenAI
    # SDKs treat an explicit base URL as an override, so instead of falling back to
    # api.openai.com every client silently failed to connect. Measured cost while
    # they were still set: two takeoff-api-infra test suites
    # (test_usage_metering, test_llm_determinism) failed locally and passed the
    # moment the vars were unset — they had been read as pre-existing breakage on
    # develop.
    #
    # Both vars are dropped, not just one. They held the identical dead URL, and
    # keeping `OPENAI_BASE_URL` alone would preserve exactly the failure above.
    # Nothing else in this repo reads either name (`rg OPENAI_` — only the
    # keychain-secrets tests/docs, which are about the API *key*).
    #
    # The Keychain entry `openai.com:api` → `OPENAI_API_KEY` was ALSO removed, after
    # confirming it was the LiteLLM virtual key and not a real OpenAI credential:
    # api.openai.com rejected it with HTTP 401 "Incorrect API key provided", and
    # `secret fp` reported len=25 where a genuine OpenAI key is 50+. The Keychain
    # copy and the ambient env value hashed identically, so the tested value was the
    # stored one. Removed with `secret rm openai.com:api` (2026-09-29).
    #
    # Nothing declarative recreates it — it was never registered in this repo, only
    # adopted into the Keychain index by hand, so a rebuild will not bring it back.
    # If a REAL OpenAI key is needed later: `secret set OPENAI_API_KEY`.

    # Chrome DevTools Protocol, in ATTACH mode against Chromium. The attach flag is
    # picked at spawn time by probing /json/version — neither --browser-url nor
    # --autoConnect works in both browser modes; that probe went to the page-lab
    # plugin with the server, so this flag now gates only the `nix-chromium-debug`
    # launcher. Nothing can reach a browser without the operator having
    # enabled debugging deliberately (in-browser, or via that launcher).
    #
    # Safe to leave on permanently, MEASURED 2026-09-06 rather than assumed: with
    # nothing listening on the port, the server still answers `initialize` and
    # stays alive (45s, no exit) — it only touches a browser lazily, when a tool
    # needs one. That mattered while one server exiting at startup could dark the
    # whole gateway; since 2026-10-02 every server is spawned per-session by its
    # own plugin, so it can only cost itself. Individual tool calls simply fail until a browser
    # is listening; `devtools-doctor.sh` in the chrome-devtools plugin says which
    # of the three causes it is.
    #
    # What is NOT persistent, deliberately: debugging itself. The in-browser toggle
    # re-prompts per session and `nix-chromium-debug` is hand-run and dies with the
    # browser window — because an open remote-debugging port is an unauthenticated
    # control channel over a profile holding live logins. Measured 2026-09-07 on the
    # then-default Opera Air: a Chromium-family browser stores no persistent consent
    # key, so there is nothing to make it stop asking. Opera was removed from this Mac
    # on 2026-09-21; the attach target is now Chromium (modules/home/default-browser.nix).
    # The MCP server moved to the page-lab plugin (#657 batch 2); opening the port
    # did not, and never was an MCP concern. See local.ungoogledChromium.debugLauncher.
    local.ungoogledChromium.debugLauncher = true;

    # Replaces the Colima container of the same name. Loopback only. Downloads
    # land in ~/.local/share/yt-dlp-webui/downloads.
    local.ytDlpWebUi.enable = true;

    # Loopback MeTube for the sideloaded Chrome extension. The extension's
    # options still need the address typed once: http://127.0.0.1:8081
    local.meTube.enable = true;

    # Per-user container runtime (Colima via home-manager's services.colima),
    # replacing the docker-desktop cask whose privileged helper was bound to
    # one username. Why/cost/migration: modules/home/containers.nix.
    local.containers.enable = true;
  };

  # ---- OpenDesign: kill the in-app self-updater --------------------------------
  # Pairs with the greedy `open-design` cask below — versioning belongs to brew,
  # not the app's own updater (see the cask's comment for the measured drift).
  # launchd.user.envVariables is nix-darwin's own lever for env that reaches
  # Finder/Dock-launched GUI apps (`launchctl setenv` at activation — same
  # mechanism as the GUI PATH in modules/darwin/core.nix); the app's updater
  # honors OD_UPDATE_ENABLED as a truthy/falsy kill-switch for both the 6h check
  # and the auto-download. Takes effect for apps launched after activation.
  launchd.user.envVariables.OD_UPDATE_ENABLED = "0";

  # ---- Homebrew apps for THIS host --------------------------------------------
  # The framework (enable/onActivation/taps) lives in modules/darwin/homebrew.nix;
  # this is macos's app set. onActivation.cleanup = "uninstall" removes anything
  # installed but not listed here.
  homebrew = {
    # ---- Formulae (brews) ----------------------------------------------------
    # Entries with special options use the attrset form.
    brews = [
      "age"
      "aws-vault"
      "btop"
      "bruno-cli"
      "cloudflared"
      "cmake"
      "devcontainer"
      "docker"
      "docker-buildx"
      "docker-compose"
      "duf"
      "ffmpeg"
      "gettext"
      # `git` is NOT brewed. Home Manager's programs.git already installs it AND
      # owns its config (~/.config/git/config, the includeIf identities, signing).
      # Both were git 2.55.0 on 2026-09-16, and `/opt/homebrew/bin` precedes the
      # nix profile in the login shell — so the brewed copy shadowed the one this
      # repo actually configures. Identical today; a silent divergence tomorrow.
      "git-cliff" # release stage — changelog / release notes (GitLab CI)
      "git-filter-repo"
      # gitlab-runner moved OFF brew 2026-09-05: local.tart.gitlabRunner below runs
      # pkgs.gitlab-runner as a launchd agent with a runtime-rendered config
      # (the tart-vms capsule's gitlab-runner.nix). After activating, retire
      # the brew copy once: `brew services stop gitlab-runner`.
      "glab"
      # GnuPG — BREWED, NOT nixpkgs, and that inverts this repo's usual instinct
      # on purpose. See the `gpgfrontend` cask below for the full reasoning; the
      # short version is that the cask hard-depends on this formula
      # (`depends_on formula: "gnupg"`), so brew's gnupg is the fleet's GnuPG on
      # this host and the ONLY one.
      #
      # DO NOT ADD A SECOND ONE. No `pkgs.gnupg`, no `pkgs.pinentry_mac`, no
      # home-manager `programs.gpg` or `services.gpg-agent`. Two GnuPG stacks
      # share one `~/.gnupg` and then which `gpg-agent` and which pinentry you
      # get is a startup-order lottery — whichever daemon bound the sockets
      # first wins, and it is not deterministic across logins.
      #
      # REVISIT ONLY IF a Nix-BUILT job needs a pinned gnupg. The fix then is
      # `GNUPGHOME` isolation for that job, NOT a second stack sharing the
      # operator's home.
      #
      # Version gate, 2026-10-06: `brew info gnupg` → stable **2.5.24**, not
      # deprecated, not disabled; aliases gnupg@2.5/gpg/gpg2. That is the
      # CURRENT branch — gnupg.org's own EOL table lists 2.2 as EOL 2024-12-31,
      # 2.4 as EOL 2026-06-30, and 2.5/2.6 as "tba", and gnupg.org's current
      # stable is 2.5.24 exactly. It also brings its own `pinentry`.
      "gnupg"
      "go"
      "graphviz"
      # link = false → don't symlink into the brew prefix.
      {
        name = "hf";
        link = false;
      }
      "imagemagick"
      "img2pdf"
      "kubernetes-cli"
      "nats-server"
      "ncdu"
      "neonctl" # Neon DB CLI (https://neon.tech/docs/reference/neon-cli)
      "ocrmypdf"
      "pyenv"
      # `scrcpy` is NOT brewed any more (2026-09-29): nixpkgs carries it (4.1,
      # builds and substitutes on aarch64-darwin), so it moved to
      # modules/home/default.nix for flake.lock pinning. `adb` deliberately did
      # NOT move — the android-platform-tools cask below still owns it, because
      # mobile-mcp and android-phone both resolve that one.
      "shellcheck"
      # `starship` is NOT brewed either, for the same reason as `git` above:
      # programs.starship installs it and writes ~/.config/starship.toml, both
      # were 1.26.0, and the brewed one won the PATH.
      "swiftlint" # lint stage — SwiftLint --strict gate (GitLab CI)
      "switchaudio-osx"
      "tree"
      "vercel-cli" # Vercel CLI (`vercel`) — deploy/manage Vercel projects
      "wget"
      # NB: no `wireguard-tools` here — macos manages WireGuard through the GUI
      # (masApps.WireGuard) ONLY. Deliberately no `wg`/`wg-quick` CLI and no `vpn`
      # operator on this host, so nothing can bring a tunnel up from a shell (a
      # botched tunnel = no-internet on the sole client Mac). Confs are synced for
      # IMPORT into the app, never run (local.wireguardConfigs, modules/home/default.nix).

      "xcodes"
      "yq"
      "yt-dlp"
      "zstd"
    ];

    # ---- Casks ---------------------------------------------------------------
    casks = [
      # Affinity — the fleet's image/vector/layout editor, one app since v3
      # (Designer + Photo + Publisher merged). Free for individuals and
      # self-updating (auto_updates), so the cask only bootstraps it. Closed
      # source is the accepted cost of a Photoshop-shaped tool; the FOSS
      # alternatives (GIMP, Krita) are deliberately not carried.
      "affinity"
      # Android SDK cmdline tools (sdkmanager/avdmanager) — backs `android-emu`
      # (modules/home/default.nix), which boots VIRTUAL Android emulators.
      "android-commandlinetools"
      # adb/fastboot — the bridge mobile-mcp drives to automate a physical phone.
      "android-platform-tools"
      "blackhole-2ch"
      "bruno"
      # Claude Desktop — the chat GUI (distinct from the claude-code CLI, nixpkgs).
      "claude"
      # `docker-desktop` is GONE (2026-09-16): its privileged helper bound the
      # machine-wide socket to one username. The runtime is now per-user Colima —
      # modules/home/containers.nix (`local.containers`); the `docker*` brews
      # above stay as the client.
      "dropbox"
      # escrcpy — graphical frontend for scrcpy (nixpkgs now, see the note in the
      # brews list above; escrcpy ships its own copy under Resources/extra), for
      # driving a PHYSICAL Android phone by mouse instead of remembering flags.
      # Complements, never replaces, `android-phone` (packages/android-phone.nix):
      # that CLI still owns the adb pairing/connect footguns it exists to encode,
      # and its header's refusal to VENDOR a third-party pairing tool is unaffected
      # by installing one alongside. From the sole third-party tap — see the tap's
      # comment in modules/darwin/homebrew.nix for the other accepted cost.
      #
      # postinstall is LOAD-BEARING — without it the app installs but cannot be
      # opened at all. Upstream ships Escrcpy.app with no _CodeSignature, only the
      # linker's adhoc signature (measured 2026-08-31: `Sealed Resources=none`,
      # `Identifier=Electron`, `Info.plist=not bound`). Unsigned + quarantined is
      # what macOS reports as "damaged and can't be opened", and that variant is
      # NOT clearable by right-click ▸ Open — the flag must actually be gone. The
      # cask's own postflight tries to strip it, but only interactively, which
      # `brew bundle` can never satisfy (no stdin; a method-level rescue swallows
      # the failure), so the flag survived every activation.
      #
      # Why postinstall and not `args.no_quarantine = true`: nix-darwin still
      # offers that arg, but Homebrew 6.0.18 has REMOVED the flag — brew bundle
      # turns it into `brew install --cask --no-quarantine`, which aborts with
      # "Error: invalid option: --no-quarantine" and fails activation. Verified
      # 2026-08-31 against this exact brew. Do not switch back to it.
      #
      # `xattr -dr` exits 0 when the attribute is already absent, so this is
      # idempotent, and brew only fires postinstall on a real install/upgrade —
      # not on every activation (bundle/cask.rb `preinstall!` returns false for an
      # already-installed cask, and `install!` early-returns on that). No sudo:
      # the .app is owned by the operator.
      #
      # NOTHING STATICALLY VALIDATES THIS KEY. Measured 2026-08-31: `brew bundle
      # list` parses a Brewfile carrying a completely made-up cask key without any
      # error, so a typo here is a SILENT no-op — the app installs, quarantine
      # stays, and the only symptom is the "damaged" dialog again. Verify against
      # brew's own source (bundle/cask.rb), never against a green bundle command.
      #
      # The tradeoff is deliberate: Gatekeeper never gets to evaluate this app, so
      # the viarotel-org build is trusted directly. Scoped to this ONE cask — never
      # generalise it to the whole casks list.
      #
      # FULLY-QUALIFIED on purpose (`<tap>/<cask>`, brew's own prescribed form). A
      # bare `escrcpy` token aborted activation the moment the tap moved to our fork
      # (measured 2026-09-29): the old viarotel-org clone is untapped by `cleanup`
      # only AFTER the bundle runs, so mid-bundle brew sees the cask in two taps and
      # refuses — "Cask escrcpy exists in multiple taps … Please use the
      # fully-qualified name". Qualifying it is also what keeps this unambiguous on a
      # machine where someone re-taps upstream by hand. Re-point this tap prefix
      # together with modules/darwin/homebrew.nix when homebrew-escrcpy#61 merges.
      #
      # MOVING THIS CASK BETWEEN TAPS NEEDS A ONE-TIME MANUAL STEP, and qualifying the
      # name is NOT it: brew keys an installed cask to the tap it came from, refuses to
      # untap while it is installed, and under brew 7 could not even parse the old cask
      # to uninstall it — so `brew uninstall --cask escrcpy` (bare token, resolves the
      # INSTALLED record) then `brew untap viarotel-org/escrcpy`, and let the next
      # activation reinstall from the new tap. Nothing declarative can do this; brew's
      # `cleanup` untaps only AFTER the install that was already aborting.
      {
        name = "ismailkattakath/escrcpy/escrcpy";
        postinstall = "/usr/bin/xattr -dr com.apple.quarantine /Applications/Escrcpy.app";
      }
      # Google Chrome — the DAILY browser and the holder of http/https
      # (`local.defaultBrowser = "chrome"`, modules/home/default.nix). It is here for
      # exactly one reason, and it is not a preference: PASSKEYS.
      #
      # Reaching a macOS Passwords.app passkey requires the RESTRICTED entitlement
      # `com.apple.developer.web-browser.public-key-credential`, which Apple grants
      # per-Team-ID to registered browser vendors on request. Verified 2026-09-15 with
      # `codesign -d --entitlements` on the installed apps:
      #
      #   Chrome (EQHXZ8M8AV)    grant + com.google.common.folsom (iCloud Keychain)
      #                                + com.google.Chrome.webauthn{,-uvk} (Touch ID)
      #   Opera / Opera Air      same shape, Opera's own Team ID
      #   Safari                 the WebKit equivalent
      #   ungoogled-chromium     NEITHER — seven entitlements, all hardware/sandbox,
      #                          and no `keychain-access-groups` key at all
      #
      # So no Chromium swap fixes it, and the obvious one is worse: the plain (googled)
      # `chromium` cask has been DISABLED in Homebrew since 2026-09-01 for failing the
      # Gatekeeper check — so not Developer-ID notarized, and a restricted entitlement
      # needs an Apple-authorized Team ID. A community rebuild
      # can never obtain the grant. Do not re-attempt this with another Chromium.
      #
      # It does NOT take any job back from ungoogled-chromium below.
      # PUPPETEER_EXECUTABLE_PATH stays pointed at /Applications/Chromium.app on
      # purpose, so JSON Resume PDF rendering keeps its pinned, ad-free engine rather
      # than following an auto_updates cask.
      "google-chrome"
      # Google Drive for desktop — the File Provider client (a mounted volume under
      # ~/Library/CloudStorage/, NOT a plain folder).
      "google-drive"
      # GCP CLI (gcloud/gsutil/bq) — Google-official SDK cask so `gcloud components
      # install` works and it self-updates (vs. the pinned nixpkgs derivation).
      # Homebrew renamed `google-cloud-sdk` → `gcloud-cli`; use the new name.
      "gcloud-cli"
      # Ghostty — GPU-accelerated terminal. A CASK because nixpkgs' `ghostty` is
      # LINUX-ONLY and refuses to evaluate on aarch64-darwin, which is exactly the
      # case home-manager documents for `programs.ghostty.package = null`:
      # Homebrew ships the app, Nix owns the config. Same split as the
      # ungoogled-chromium cask. Settings live in modules/home/default.nix.
      "ghostty"
      # GpgFrontend 2.2.2 — the OpenPGP GUI, after every other option was
      # measured and failed. BARE STRING: the cask declares NO `auto_updates`
      # (API: `auto_updates: null`), so `greedy` is not even applicable — that
      # flag only opts an auto-updating cask back into upgrades past
      # `onActivation.upgrade = false` (modules/darwin/homebrew.nix:42), and
      # `open-design` remains the only documented updater pathology here.
      #
      # IT PULLS BREW'S GnuPG, AND THAT IS THE POINT, not a cost:
      # `depends_on {formula: ["gnupg"], macos: {">=": ["13"]}}`. The objection
      # "this forces a second gnupg" only holds if a NIX-managed gnupg also
      # exists — and we deliberately add none, so brew's becomes the single
      # source of truth. See the `gnupg` brew above for the do-not list.
      #
      # ARM64 VERIFIED BY MEASUREMENT, NOT BY READING THE VARIATIONS TABLE —
      # and the table would have misled. `brew --cache --cask gpgfrontend` on
      # this machine (macOS 27.0.1-arm64) resolves to
      #   GpgFrontend-2.2.2-macos-26.dmg
      # with NO `-intel` suffix, i.e. the Apple Silicon build: there is no
      # `arm64_golden_gate` variation, so arm64 falls through to the default
      # URL, while the unprefixed `golden_gate` key is the x86_64 one. Reading
      # that key alone suggests an Intel download; the resolver disagrees.
      # This mattered: `arch -x86_64 /usr/bin/true` fails with "Bad CPU type"
      # and `oahd` is not running, so there is NO Rosetta on this Mac — an Intel
      # artifact would have been unusable, not merely slow.
      #
      # WHY EVERY ALTERNATIVE LOST, 2026-10-06, so none is re-attempted:
      #   * `gpg-suite` / `gpg-suite-no-mail` — ABANDONED. Latest release is
      #     2023.3 dated 2023-07-23 per GPGTools' OWN release notes, and the
      #     cask string matches upstream exactly, so it is NOT Homebrew lag. It
      #     bundles GnuPG 2.2.41 — a branch EOL since 2024-12-31. A stale
      #     wrapper around a stale GnuPG is the one shape a crypto tool may not
      #     have.
      #   * `pkgs.gpa` — CRASHES ON LAUNCH on aarch64-darwin, operator-confirmed
      #     on screen ("gpa quit unexpectedly"). Instruments agreed: absent from
      #     System Events' windowed-process list, runningboard logged
      #     `running-NotVisible`, process dead at 26 s with an EMPTY log. It is
      #     also unwrapped (no `GDK_PIXBUF_MODULE_FILE`), the classic darwin
      #     GTK3 failure, though it emitted no error to prove that.
      #   * `seahorse`, `kleopatra` / `kdePackages.kleopatra`, `keybase-gui` — no
      #     `aarch64-darwin` in `meta.platforms`. Not a runtime question.
      #
      # upstream-first: nixpkgs' darwin GUI options are EXHAUSTED — gpa is the
      # only one that builds for aarch64-darwin and it crashes; the rest are
      # Linux-only — and GpgFrontend has no nixpkgs packaging on this platform
      # at all. The cask + formula pair is the only route, so there is no
      # upstream option to prefer.
      #
      # GIT SIGNING IS UNAFFECTED: this fleet signs commits in SSH format
      # (`gpg.format = "ssh"`, modules/home/default.nix), so no gpg-agent or
      # pinentry here can touch commit signing. Do not "fix" that non-problem.
      "gpgfrontend"
      "iina"
      # Inkscape is gone on purpose (2026-09-15) — do not re-add.
      # KDE Connect — the phone-as-TRACKPAD/keyboard for this Mac (its "Virtual
      # touchpad" panel). A CASK because nixpkgs' `kdePackages.kdeconnect-kde` is
      # Linux+FreeBSD in `meta.platforms` and does not evaluate on aarch64-darwin;
      # the cask ships 26.08.1, the SAME version, arm64-only, macOS >= 13. Same
      # Homebrew-app/Nix-config split as the ghostty and ungoogled-chromium casks.
      #
      # THE macOS BACKEND IS REAL, verified in upstream source (2026-10-06), not
      # inferred from the download page: plugins/mousepad/CMakeLists.txt gates
      # `macosremoteinput.mm` behind `if (APPLE)` and links CoreGraphics +
      # ApplicationServices + Cocoa, and that file posts genuine system-wide events
      # via `CGEventPost(kCGHIDEventTap, …)` — click, double-click, right/middle
      # click, drag and pixel scroll. Upstream still calls non-Linux unsupported, so
      # treat a regression here as expected-unsupported, not as our misconfiguration.
      #
      # CURSOR MOVEMENT NEEDED NO Accessibility GRANT — measured end-to-end
      # 2026-10-06, and this comment first claimed the opposite. Paired, then swiped
      # on the phone's Remote input panel: the Mac pointer moved 587 px / 312 px for
      # a 550 / 300 swipe, with NOTHING granted on the Mac (the only consent given
      # was Android's own notification permission, which the app's foreground
      # service needs). So an unmoving cursor is NOT evidence of a missing grant —
      # check pairing (`kdeconnect-cli -a` must say "paired and reachable") first.
      #
      # The grant may still gate the OTHER directions: the plugin does call
      # `AXIsProcessTrustedWithOptions`, and clicks/keystrokes were deliberately
      # NOT tested (a synthetic click lands on whatever is under the pointer). If
      # those misbehave, System Settings > Privacy & Security > Accessibility is the
      # place to look — TCC consent is not expressible in Nix either way.
      #
      # It takes NOTHING from escrcpy/scrcpy above: those drive the PHONE from this
      # Mac, this drives this MAC from the phone. Opposite directions, and it rides
      # its own port (1716), never adb — so `android-phone` pairing state is
      # irrelevant to whether this works.
      "kde-connect"
      # LibreOffice — provides the `soffice` CLI the docx/pptx/xlsx/pdf Claude Code
      # skills (modules/home/default.nix programs.claude-code.skills) already hardcode
      # as their document-conversion engine. Cask (not nixpkgs libreoffice-bin)
      # because its command_wrapper execs the real Mach-O soffice binary directly —
      # nixpkgs' wrapper shells out via `open -na`, which won't block/report exit
      # status for scripted --convert-to pipelines. First headless run may need a
      # one-time profile warm-up (soffice -env:UserInstallation=file:///tmp/... );
      # see the NOTE at the skills block below.
      "libreoffice"
      "maccy"
      "microsoft-auto-update"
      "microsoft-teams"
      # OBS Studio. Its macOS Virtual Camera ships as a system extension
      # (com.obsproject.obs-studio.mac-camera-extension), installed on first launch
      # and persisting independently of OBS.app.
      "obs"
      "obsidian"
      # OpenDesign — the local-first design-agent desktop app (Electron; this repo
      # declares no MCP server for it any more — that left the fleet with the
      # gateway 2026-10-02, see modules/home/claude-desktop.nix).
      # Adopts the previously hand-dragged /Applications copy: `brew bundle`
      # passes --adopt to every fresh cask install, and for an auto_updates cask
      # adoption is unconditional (no re-copy, no touch of the app's ~1GB state).
      #
      # greedy is LOAD-BEARING, paired with launchd.user.envVariables.
      # OD_UPDATE_ENABLED below — the in-app updater's launcher-tree relaunch
      # path caused a measured version split (docs/open-design.md has the
      # numbers). greedy opts this one cask back into upgrades past
      # onActivation.upgrade = false, so versions land at activation instead
      # and /Applications stays the only copy that ever runs.
      {
        name = "open-design";
        greedy = true;
      }
      "proton-drive"
      "raspberry-pi-imager"
      "slack"
      # Slack's official CLI for building/deploying Slack apps (docs.slack.dev/tools/slack-cli).
      # Cask, not nixpkgs' same-named "slack-cli" — that's an unrelated, unmaintained
      # rockymadden/slack-cli webhook-poster, not this tool.
      "slack-cli"
      "telegram"
      # Tor Browser 15.0.24 — BARE STRING, no greedy, and that is the default
      # shape here rather than an omission. `auto_updates true` + `depends_on
      # :macos`, installed from ONE universal tor-browser-macos-15.0.24.dmg:
      # native Apple Silicon, no Rosetta, no arch-split url. `google-chrome`
      # above is the precedent for exactly this (a normal auto_updates cask,
      # bare string). `greedy` in this repo is reserved for a DOCUMENTED
      # PATHOLOGY — `open-design`'s in-app updater relaunching through a path
      # that produced a measured version split (see its comment and
      # docs/open-design.md) — and no such issue is known for Tor Browser.
      #
      # THAT ABSENCE IS ASSUMED, NOT VERIFIED. The check that would settle it:
      # if the installed `Tor Browser.app`'s CFBundleShortVersionString ever
      # drifts BELOW what `brew info --cask tor-browser` calls current, the
      # in-app updater is winning and this needs `greedy = true`.
      #
      # `conflicts_with cask: "tor-browser@alpha"` — stable and alpha cannot
      # coexist on this Mac, so do not add the alpha cask alongside.
      #
      # WHY A CASK AND NOT NIXPKGS, and the contrast worth knowing: upstream
      # ships ONE unsuffixed universal .dmg for macOS but only -x86_64/-i686
      # tarballs for Linux, so stable Tor Browser has Apple Silicon support on
      # macOS and NONE on Linux. That asymmetry is why `nixvm` needs an
      # overlay onto the 16.0a13 ALPHA (modules/nixos/desktop-vm.nix, which
      # carries the full derivation) while this host needs only a cask.
      #
      # grepped the pinned nixpkgs for a Darwin route — none exists:
      # pkgs/by-name/to/tor-browser/package.nix:107 declares `sources` with
      # only x86_64-linux (:108) and i686-linux (:118), and
      # `meta.platforms = lib.attrNames sources` (:345), so there is no Darwin
      # packaging at ANY arch at this pin. The cask is the off-the-shelf
      # community mechanism; re-deriving dmg extraction and codesign handling in
      # Nix is the hand-rolled path the motto weighs against.
      "tor-browser"
      # Übersicht — desktop widgets rendered as web views behind every window.
      # Cask because it is a signed .app with no nixpkgs/home-manager packaging;
      # the ONE widget the fleet declares (a full-screen HTML file) is placed by
      # modules/home/ubersicht.nix (local.ubersicht.htmlWidget).
      # OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
      "ubersicht"
      # ungoogled-chromium — Chromium without the Google integration. Cask because
      # nixpkgs' chromium/ungoogled-chromium are *-linux only (no darwin build), and
      # the plain `chromium` cask is deprecated (fails the macOS Gatekeeper check,
      # disabled 2026-09-01). Its declarative config — the sideloaded iCloud
      # Passwords extension + Apple's native-messaging host, which macOS otherwise
      # ships to Chrome and Firefox ONLY — lives in modules/home/chromium.nix.
      "ungoogled-chromium"
      "visual-studio-code"
      # NO DICTATION CASK HERE, ON PURPOSE — read this before adding one.
      # `voiceink` was declared and reverted the same day (#550, #552). The trap
      # is not that it is bad software; it is that the licence you can verify
      # from a terminal is NOT the licence that governs the thing a cask
      # installs:
      #
      #   VoiceInk    GPL-3.0 SOURCE, paywalled BINARY. First launch asks for
      #               Microphone + Accessibility + Screen Recording, then shows
      #               "Buy VoiceInk License" and transcribes nothing until you
      #               pay or start a 7-day trial. `brew info` does not say so.
      #   MacWhisper  paid Pro tier, same shape.
      #   superwhisper  subscription.
      #   aqua-voice  subscription AND cloud — audio leaves the Mac.
      #   handy       genuinely free and open source; the only one of the five
      #               that a cask actually delivers working.
      #
      # So "it is GPL" is not a reason to declare a cask. This repo declares
      # BINARIES, and the question for a binary is whether it runs, not what
      # its source is licensed as. Check the paywall before the licence.
      #
      # Separately, and independent of cost: any of these that offers Screen
      # Recording for "transcript accuracy" is asking to read whatever is on
      # screen — hostnames, paths, secret values. Decline it; a custom
      # vocabulary buys the same jargon accuracy without the capability.
      "whatsapp"
      # Wireshark — SHARED (plain /Applications). Its packet capture needs the
      # ChmodBPF privileged helper, which the cask installs as a system
      # LaunchDaemon; that is machine-wide by design and cannot be per-user, so
      # scoping the .app to one home would only hide the GUI, not the capability.
      # `wireshark-app` is the CURRENT name — plain `wireshark` still resolves but
      # warns "was renamed to wireshark-app" on every activation.
      "wireshark-app"
    ];

    # ---- Mac App Store apps (masApps) ----------------------------------------
    # macos only — a sandbox host cannot sign into an App Store login, so any
    # masApps entry fails brew bundle there.
    # `mas` itself comes from nixpkgs (modules/darwin/core.nix); anything listed here is also
    # protected from onActivation.cleanup = "uninstall" (undeclared MAS apps
    # get removed — that is how Xcode was wiped before this entry).
    #
    # That reaping is MACHINE-WIDE and `mas list` sees every App Store app on the
    # machine, whichever Apple ID bought it. Policy: anything to keep is declared
    # HERE (or installed outside MAS). The value itself,
    # `homebrew.onActivation.cleanup = "uninstall"` (modules/darwin/homebrew.nix),
    # stays — the fix is to declare, not to stop cleaning.
    masApps = {
      # Official client is App Store–only (no Homebrew cask). This GUI is the
      # ONLY way macos touches WireGuard — no CLI tools, no vpn operator. The
      # user imports a synced conf and connects manually in-app; nothing here
      # (or on activation) ever starts a tunnel.
      WireGuard = 1451685025;
      # Display My IP — public IP + country in the menu bar, with a notification
      # when it changes. The companion to masApps.WireGuard above: because that
      # GUI is the only way a tunnel comes up here (no `wg`, no `vpn` operator),
      # no shell can answer "is the tunnel actually up?" — this makes the answer
      # permanently visible. Free, and App Store–only like WireGuard itself.
      # https://apps.apple.com/ca/app/display-my-ip/id1493408723
      "Display My IP" = 1493408723;
      # Full Xcode IDE from the Mac App Store (not the CLI tools alone).
      # License is accepted *before* brew bundle by modules/darwin/xcode-license.nix
      # (Brewfile installs brews before masApps — without that, formulae fail with
      # "You have not agreed to the Xcode license" on first activation).
      Xcode = 497799835;
      # OPERATOR-ONLY — not part of the reusable engine; the template mkForce-disables or omits this.
      # Plash — put a website on your desktop as the wallpaper. App Store–only
      # (no Homebrew cask). https://apps.apple.com/ca/app/plash/id1494023538
      Plash = 1494023538;
    };
  };
}
