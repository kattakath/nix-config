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
  lib,
  pkgs,
  loginName,
  ...
}:
let
  # DERIVED, never a `/Users/izzy` literal — a hardcoded home path in a .nix
  # value is the anti-pattern `nix-home-path-lint` rejects. Casks carrying this
  # as `args.appdir` land in Izzy's home instead of the shared /Applications,
  # which is what keeps them out of the operator's Finder/Spotlight/Launchpad.
  izzyApps = "${config.users.users.izzy.home}/Applications";

  # DERIVED for the same reason as izzyApps. This one is a Directory Services
  # NODE path rather than a filesystem path, but it is still a per-user literal,
  # and the ast-grep gate cannot tell the two apart — nor should it have to.
  izzyDsNode = "/Users/${config.users.users.izzy.name}";

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
    ../modules/darwin/core.nix
    ../modules/darwin/github-runner.nix
    ../modules/darwin/ollama-daemon.nix
  ];

  # ONE ollama for the whole machine. The per-user agent could not be shared:
  # it lives in a single login session and keeps its models in that user's home,
  # so a second account meant either a duplicate 31 GB store or a server that
  # vanished whenever the operator logged out. `modules/shared/home.nix` sets
  # `local.rag.ollama.manageServer = false` so the capsule stops standing up a
  # competing one — two servers on 11434 means one wins and the other flaps.
  local.ollamaDaemon.enable = true;

  # Machine-wide CLIs — the mechanism for "shared between both accounts". A
  # systemPackages entry is ONE store path on PATH for every user, so neither
  # profile has to declare it and neither can drift to a different version.
  #
  # grok was a per-user `curl … | bash` install in ~/.grok/bin until
  # 2026-09-15; packages/grok.nix pins the vendor's signed artifact instead, and
  # the PATH entry that used to point at the mutable copy is deliberately gone
  # from modules/shared/home.nix. Per-user grok STATE stays in ~/.grok.
  environment.systemPackages = [
    (pkgs.callPackage ../packages/grok.nix { })
    # fal.ai — `fal` (the vendor's deploy CLI) and `fal-gen` (inference). Cloud
    # inference, unlike the rest of the media stack, which runs against the
    # local ollama daemon; it bills, and it needs FAL_KEY in the Keychain.
    (pkgs.callPackage ../packages/fal.nix { })
  ];

  nixpkgs.config.allowUnfree = true;

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

  # ---- Izzy: the second ADMINISTRATOR account -----------------------------
  # An administrator (admin group, granted below) but never
  # `system.primaryUser` — that stays `loginName` (modules/darwin/core.nix), so
  # a fresh Mac is still FOUNDED as the operator via bootstrap.sh →
  # bootstrap.sh and this account is created on top of that.
  #
  # `gid` is deliberately left at the `staff` default rather than set to 80:
  # macOS models an administrator as staff-primary PLUS supplementary admin
  # membership (that is exactly how the operator's own account looks), and
  # making admin the PRIMARY group would drop Izzy out of `staff` — which the
  # group-writable appdir repair below depends on.
  #
  # `knownUsers` is the CREATE/DELETE switch, not a label — nix-darwin creates
  # only users listed here, and REMOVING a name from this list DELETES the
  # account on the next activation. The home directory survives that, but the
  # account does not; treat an edit here as destructive.
  #
  # uid 502 is the next free slot (501 = operator, 533 = _github-runner).
  users.users.izzy = {
    name = "izzy";
    uid = 502;
    description = "Izzy";
    home = "/Users/izzy";
    createHome = true;
    shell = "/bin/zsh";
    # LOAD-BEARING, and the default is wrong for a human. nix-darwin's
    # `isHidden` defaults to TRUE (modules/users/user.nix) because the option
    # exists for SERVICE accounts — `_github-runner` above is exactly that case.
    # Left at the default, izzy is created correctly in every other respect —
    # uid, admin group, password, home — and is simply INVISIBLE: absent from
    # the login window, from Fast User Switching, and from System Settings ▸
    # Users & Groups. The account cannot be logged into at all, which also means
    # its `gui/502` launchd domain never exists, which is what made its media
    # agents unbootstrappable. Verified via `dscl . -read /Users/izzy IsHidden`.
    isHidden = false;
  };
  users.knownUsers = [ "izzy" ];

  # `args.appdir` into another user's home has ONE sharp edge, measured
  # 2026-09-15 on the first activation: `brew bundle` runs as `homebrew.user`
  # (the operator) under sudo, so it MKDIRs the target as root:staff 0755 —
  # and Izzy's own Home Manager then dies with
  #   ln: failed to create symbolic link '/Users/izzy/Applications/Home Manager Apps'
  # because neither account can write it.
  #
  # Both accounts are in `staff`, so
  # owning the directory by the account and making it group-writable lets the
  # operator's brew AND Izzy's Home Manager both write. Ordering is the whole
  # point of `mkBefore`: this lands in `postActivation`, which runs AFTER
  # `homebrew` (nix-darwin activation-scripts.nix:138) and, via mkBefore,
  # BEFORE home-manager's own postActivation block (home-manager
  # nix-darwin/default.nix:19) — the only window where the repair is useful.
  #
  # upstream-first: grepped the pinned nix-darwin for appdir/user/ownership —
  # `homebrew.user` and `caskArgs.appdir` exist, but nothing reconciles the two
  # across accounts. No option owns this; hence the shim.
  system.activationScripts.postActivation.text = lib.mkBefore ''
    # CONVERGE IsHidden, because nix-darwin will not. `users.users.izzy.isHidden`
    # is applied ONLY inside the user-CREATION branch (pinned
    # modules/users/default.nix:306); the "Update properties on known users"
    # block a few lines below re-applies PrimaryGroupID and RealName but never
    # IsHidden. So flipping the option on an account that already exists changes
    # nothing, for ever — the declaration reads correct and the machine ignores
    # it, which is exactly the drift this repo exists to prevent.
    #
    # The default is TRUE, aimed at service accounts like `_github-runner`. Left
    # there, a human account is created perfectly — uid, admin, home (NOT a
    # password: the pinned nix-darwin has no `password`/`hashedPassword` option
    # and account creation runs `sysadminctl -addUser` without one, so a
    # wipe-and-rebuild yields a PASSWORDLESS admin. That step is genuinely not
    # expressible in Nix on darwin and belongs in
    # docs/new-mac-runbook.md § Manual steps Nix can't do) —
    # and is simply INVISIBLE: no login window entry, no Fast User Switching, no
    # System Settings ▸ Users & Groups. It cannot be logged into, so its
    # `gui/502` launchd domain never exists, so its user agents can never
    # bootstrap. That is the whole chain behind "izzy user not found anywhere".
    #
    # Idempotent: dscl -create is a write-if-different, and this reads back 0.
    if [ "$(/usr/bin/dscl . -read ${izzyDsNode} IsHidden 2>/dev/null | /usr/bin/awk '{print $2}')" != "0" ]; then
      printf '%s\n' "izzy: unhiding the account (nix-darwin only sets IsHidden at creation)"
      /usr/bin/dscl . -create ${izzyDsNode} IsHidden 0
    fi

    printf '%s\n' "izzy: reconciling ${izzyApps} ownership (brew writes as ${loginName}, HM writes as izzy)"
    mkdir -p ${lib.escapeShellArg izzyApps}
    chown izzy:staff ${lib.escapeShellArg izzyApps}
    chmod 775 ${lib.escapeShellArg izzyApps}

    # Administrator rights. nix-darwin does NOT model supplementary groups —
    # `extraGroups` is commented out in modules/users/user.nix:49 of the pinned
    # input — and `users.groups` only creates groups, it cannot add a member to
    # the pre-existing system `admin`. So this is the off-the-shelf macOS tool
    # doing the work, not a hand-rolled one; `checkmember` keeps it idempotent,
    # so a settled Mac is a true no-op rather than a write every activation.
    if ! /usr/sbin/dseditgroup -o checkmember -m izzy admin >/dev/null 2>&1; then
      printf '%s\n' "izzy: granting admin group membership"
      /usr/sbin/dseditgroup -o edit -a izzy -t user admin
    fi
  '';

  # FAST USER SWITCHING — the thing that makes a second account reachable at all
  # without logging out. It is OFF by default on a single-account Mac, and that
  # is the second half of "izzy user not found anywhere": unhiding the account
  # puts it in the login window, but with no switcher there is nowhere to switch
  # FROM while the operator is signed in.
  #
  # upstream-first: grepped the pinned nix-darwin for MultipleSessionEnabled and
  # UserSwitcher — `system.defaults.controlcenter` models only BatteryShowPercentage,
  # Sound, Bluetooth, AirDrop, Display, FocusModes and NowPlaying, and
  # MultipleSessionEnabled appears nowhere under modules/. No option exists →
  # the CustomSystemPreferences / CustomUserPreferences escape hatch, which this
  # tree already uses for the same reason (modules/darwin/core.nix:425).
  # The domain MUST be the absolute path. nix-darwin renders this attribute name
  # straight into `defaults write <domain> …` running as root, and a bare
  # `.GlobalPreferences` there resolves to ROOT'S OWN preferences
  # (/var/root/Library/Preferences/.GlobalPreferences), not the machine-wide
  # file. Measured: the first spelling wrote `1` into root's plist while
  # /Library/Preferences/.GlobalPreferences stayed unset and FUS stayed off —
  # an activation that reports success and changes nothing observable.
  system.defaults.CustomSystemPreferences."/Library/Preferences/.GlobalPreferences".MultipleSessionEnabled =
    true;
  # Menu-bar visibility is a PER-USER Control Center setting, hence the user
  # hatch: 18 is "Show in Menu Bar" for a Control Center module (2 is hide).
  system.defaults.CustomUserPreferences."com.apple.controlcenter".UserSwitcher = 18;

  # A deliberately MINIMAL profile — it imports the one module it needs, NOT
  # modules/shared/home.nix. That profile is the operator's: MCP gateway,
  # Keychain loader, git signing, agent surface. Handing it to a second account
  # would duplicate every agent and secret loader on the machine.
  # Izzy runs the SAME Home Manager profile as the operator — the whole of
  # modules/shared/home.nix, not a hand-picked subset. Everything that is
  # genuinely per-user comes along unchanged: every CLI, the full Claude surface
  # and guardrails, media-cli and its Finder Services, chromium, wireguard, the
  # terminal theme, next-right-thing, and his own `secret` Keychain store.
  #
  # Only two classes of thing are overridden below, and neither is a preference:
  # MACHINE-WIDE SINGLETONS, which physically cannot run twice, and the handful
  # of settings that are per-PERSON rather than per-machine.
  home-manager.users.izzy =
    { config, lib, ... }:
    {
      imports = [ ../modules/shared/home.nix ];
      home.stateVersion = "24.05";

      # NO launchd agents for the second account. PERMANENT per-account policy —
      # do NOT delete this block.
      #
      # It used to say "delete this the moment he has logged in once". He HAS
      # logged in; obeying that instruction now would be actively harmful, which
      # is why it is gone rather than merely stale. Four agents are ALREADY
      # registered and running in `gui/502` as orphans — next-right-thing,
      # media-queue, media-queue-power and an ssh-keychain-load in an EX_CONFIG 78
      # respawn loop — left behind from before these disables landed. Re-enabling
      # the declared agents would put a SECOND copy of each alongside them.
      #
      # Those orphans cannot be reached from here: home-manager skips its launchd
      # cleanup when there is no previous generation, and izzy's profile
      # directory is empty, so the skip is permanent and self-perpetuating. They
      # need a one-time manual `launchctl bootout gui/502/<label>` plus plist
      # removal from ~izzy/Library/LaunchAgents. Rebuilding provably cannot do it.
      # (Audited 2026-09-16, report finding H2.)
      #
      # A user agent can only bootstrap into that user's OWN GUI session, and
      # `gui/502` does not exist before a first login:
      #
      #   Failed to start agent 'gui/502/org.nix-community.home.ssh-keychain-load'
      #     Bootstrap failed: 125: Domain does not support specified action
      #
      # home-manager's activation then exits non-zero, `activate` runs under
      # `set -e`, and the abort lands ~80 lines short of its final
      # `ln -sfn … /run/current-system` — so the system profile advances while
      # /run/current-system, which is what PATH and the `current-system` GC root
      # resolve through, stays on the PREVIOUS generation. dd23d3b fixed exactly
      # this for local.mediaCli's two agents; these two come from the SHARED
      # profile, where neither is optional, so they kept aborting afterwards.
      #
      # upstream-first: grepped the pinned home-manager modules/launchd. It has
      # TWO spellings and only one of them works — `launchd.enable` (default.nix:211)
      # reads like the class-wide switch ("Whether to enable Home Manager to define
      # per-user daemons"), but its implementation uses `cfg.enable` in exactly one
      # place, an assertion (:232): `agentPlists` filters on the PER-AGENT flag
      # (:166) and `home.activation.setupLaunchAgents` is gated on `isDarwin`
      # alone (:242). Measured here — `launchd.enable = false` evaluated, both
      # agents still bootstrapped, activation still aborted. So it is the
      # per-agent `enable` (:20) or nothing.
      #
      # Removal is safe on a domain-less user even though installation is not:
      # the module's `bootoutAgent` whitelists "Domain does not support specified
      # action" (:326) where `bootstrapAgent` treats it as an error.
      #
      # COST of the working spelling: it is per-agent, so a new agent added to
      # modules/shared/home.nix will start aborting Izzy's activation again until
      # it is listed here too. That is upstream's wart, not a choice.
      # mkForce: both are set to `true` unconditionally at their source
      # (next-right-thing.nix, and home.nix's ssh-keychain-load), so a plain
      # `false` here is a definition CONFLICT, not an override.
      launchd.agents.ssh-keychain-load.enable = lib.mkForce false;
      launchd.agents.next-right-thing.enable = lib.mkForce false;

      # MECHANIZE THAT COST. The list above is per-agent because upstream gives
      # no class-wide switch, so it silently goes stale the moment anything adds
      # an agent to the shared profile — and the way it reports that is a
      # `set -e` abort ~80 lines short of the final `ln -sfn … /run/current-system`,
      # i.e. a SILENT four-generation drift that looked like a successful switch.
      # This turns the next occurrence into a `nix flake check` failure that
      # names the agent, BEFORE anything is activated.
      #
      # Reaches the surface: home-manager's OS integration flattens every
      # `home-manager.users.<u>.assertions` into the system's own, prefixed
      # "<u> profile: " (pinned home-manager nixos/common.nix:191-199), and
      # nix-darwin evaluates `assertions` while building the toplevel.
      assertions =
        let
          enabled = lib.attrNames (lib.filterAttrs (_: a: a.enable) config.launchd.agents);
        in
        [
          {
            assertion = enabled == [ ];
            message = ''
              izzy has ${toString (builtins.length enabled)} ENABLED launchd agent(s): ${lib.concatStringsSep ", " enabled}.
              The second account runs NO user launchd agents. That is a permanent policy,
              not a wait-for-first-login workaround — he has since logged in, and four
              agents are already running in `gui/502` as unmanaged orphans that activation
              cannot remove, so enabling a declared one adds a SECOND copy beside it.
              Add `launchd.agents.<name>.enable = lib.mkForce false;` next to the two above.
              Do NOT "fix" this by deleting the block or the assertion.
            '';
          }
        ];

      # ---- Singletons: exactly one instance, and it is the operator's --------
      # Each of these binds a fixed loopback port or owns a single credential, so
      # a second copy does not "also run" — one wins and the other flaps under
      # KeepAlive, which is worse than not having it. `mkForce` because
      # modules/shared/home.nix sets each of these unconditionally.
      #
      #   mcpGateway  127.0.0.1:8096, plus :8097 and the ONE Cloudflare
      #               connector token behind local.mcpGateway.public. Its master
      #               switch is `config = lib.mkIf cfg.enable` (mcp.nix:1002), so
      #               this one line removes the gateway, the public proxy and the
      #               tunnel connector together.
      #   pgvector    127.0.0.1:5433 and a single Postgres datadir.
      #   claudeOtel  127.0.0.1:4317/:4318 (the OTel collector's gRPC + HTTP).
      #
      # Izzy still USES all three — they listen on loopback, which is shared.
      # What he does not do is start a second one.
      #
      # SAY THE SECOND HALF OUT LOUD, because "singleton" makes this sound like a
      # port decision and it is also a CREDENTIAL one. mcp-proxy runs as the
      # OPERATOR on 127.0.0.1:8096 with no authentication, so the second account
      # needs no privilege at all — just a TCP connect — to drive GitHub, Apify,
      # Telegram, WordPress and four Gmail accounts AS THE OPERATOR. Probe-
      # confirmed 2026-09-16: as izzy, :8096 and :8097 both answered at the
      # application layer (HTTP 404, connect 0.4ms — the server replying).
      #
      # That is INTENDED (operator ruling, 2026-09-16): one human, two accounts,
      # and the loopback boundary is not being asked to carry a trust boundary it
      # was never given. Recorded here so it stays a decision rather than an
      # assumption — if a THIRD party ever gets an account on this Mac, this line
      # is the one that has to change first, and it needs authentication or
      # per-user gateways rather than a comment.
      local.mcpGateway.enable = lib.mkForce false;
      local.rag.pgvector.enable = lib.mkForce false;
      local.claudeOtel.enable = lib.mkForce false;
      # The ollama SERVER is already machine-wide (local.ollamaDaemon), so all
      # that is left in the capsule for a second account is the one-shot model
      # pull — and two agents racing to pull the same model into one shared store
      # is pure duplication.
      local.rag.ollama.enable = lib.mkForce false;

      # ---- Per-person, not per-machine --------------------------------------
      # A LaunchServices http/https claim is per-user by construction, so this
      # genuinely differs rather than conflicting. mkForce because home.nix sets
      # it with mkIf, not mkDefault.
      local.defaultBrowser = lib.mkForce "opera";

      # home.nix sets these from identityArgs with mkDefault, so a plain
      # assignment wins. This is only the FALLBACK identity: the includeIf rules
      # in home.nix still decide per repo, so github.com/izzykatt and
      # gitlab.com/izzykatt behave identically for both accounts. Without this,
      # commits from this account would author as the operator and the two would
      # be indistinguishable in history.
      programs.git.settings.user = {
        name = "Izzy Katt";
        email = "hi@izzykatt.ca";
      };

      # `types.lines` MERGES across definitions (appends, does not replace), so this
      # ADDS a second valid signer for hi@izzykatt.ca rather than replacing the
      # one modules/shared/home.nix's own allowedSigners already lists (both
      # accounts trusting the operator's key, per 825efe8 — deliberate: same
      # person, one key, multiple personas). This account's actual keypair
      # (~/.ssh/id_ed25519, generated locally 2026-09-16) is a DIFFERENT key —
      # so without this line, izzy's own commits sign correctly (that only
      # needed a keypair to exist) but `git verify-commit`/`log
      # --show-signature` on THIS account report "No principal matched"
      # forever, because the key this account actually signs with was never in
      # the list this account checks against. Either key now verifies him.
      programs.git.signing.allowedSigners = ''
        hi@izzykatt.ca namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBi26eg956+XCl9XsH68Z0Mi6dYYPtUBdcvHE/aK2O1e
      '';

      # ---- No media agents for the second account ----------------------------
      # A user launchd agent can only bootstrap into that user's GUI session, and
      # while `gui/502` did not exist every agent failed with
      # `Bootstrap failed: 125`, making darwin-rebuild exit non-zero — with the
      # abort landing BEFORE /run/current-system is re-pointed, leaving
      # machine-wide packages installed and unreachable at the same time.
      #
      # This used to read "flip to `true` after his first login". He has logged
      # in, and flipping it now is the WRONG move: two of this capsule's agents
      # (media-queue, media-queue-power — 602 runs) are already in `gui/502` as
      # orphans activation cannot remove, so enabling the declared ones doubles
      # them. See the launchd block above for why, and for the manual bootout
      # that is the only way to clear them.
      local.mediaCli.enable = lib.mkForce false;
    };

  # ---- Gmail multi-account MCP (modules/shared/mcp.nix, a home-manager option
  # — set via home-manager.users)
  # The operator's COMPLETE Gmail roster. All four are the operator's own
  # accounts under identities already public elsewhere in this very tree:
  # userEmail = ismail@kattakath.com (identityArgs) and its namesake domain;
  # silvercreek.ai, whose production WordPress this gateway already drives
  # (`wordpress-adapter`); and the operator's `aloshy` handle (the aloshy.ai
  # zone). The private nix-personal flake used to ADD further accounts via
  # extraHomeModules; it was fully retired 2026-09-15, and the operator chose to
  # keep only the two below from its list of seven (#524), so this list is now
  # the whole set. Anyone else's address still never belongs here — see the
  # option's description in modules/shared/mcp.nix.
  #
  # `publicMcpServers` is a home-manager module arg (extraSpecialArgs,
  # modules/parts/compose.nix) — NOT this file's own specialArgs — so this
  # definition must be a function to receive it, matching
  # modules/shared/home.nix's own signature.
  home-manager.users.${loginName} =
    { publicMcpServers, ... }:
    {
      local.mcpGateway.gmail.accounts = [
        "ismail@kattakath.com"
        "ismailkattakath@gmail.com"
        "izzy@silvercreek.ai"
        "aloshyakasoto@gmail.com"
      ];

      # ---- Published MCP gateway server list -------------------------------
      # THE fleet value (config.fleet.publicMcpServers, modules/parts/identity.nix),
      # not a copy of it. terranix renders the same binding into the portal
      # registrations; it cannot read this option back, because it renders
      # outside any host's module system — so one source feeds both halves
      # rather than two lists that must be hand-kept equal.
      local.mcpGateway.public = publicMcpServers;

      # ---- Infin8 AWS SSO profiles (upstream home-manager option) -----------
      # Folded in from nix-personal's aws-sso.nix (2026-09-15). Not secrets —
      # start URL, account IDs, role names; SSO tokens stay in ~/.aws/sso/cache.
      # Claude Code's Bedrock identity selects the SDLC profile at runtime via
      # `secret set AWS_PROFILE infin8-takeoff-sdlc` (modules/shared/claude-bedrock-gate.nix);
      # `region` lives on the profile itself, which is why it's set below.
      programs.awscli = {
        enable = true;
        settings = {
          "sso-session infin8" = {
            sso_start_url = "https://d-9a676f27ed.awsapps.com/start";
            sso_region = "us-east-2";
            sso_registration_scopes = "sso:account:access";
          };
          "profile infin8-takeoff-sdlc" = {
            sso_session = "infin8";
            sso_account_id = "319826235970";
            sso_role_name = "AdministratorAccess";
            region = "ca-central-1";
            output = "json";
          };
          "profile infin8it-takeoff-prod" = {
            sso_session = "infin8";
            sso_account_id = "996122083124";
            sso_role_name = "AdministratorAccess";
            region = "ca-central-1";
            output = "json";
          };
        };
      };

      # ---- Infin8 LiteLLM proxy (OpenAI-compatible clients) ------------------
      # Folded in from nix-personal's openai-gateway.nix (2026-09-15). Both vars
      # are load-bearing: openai-python/-node >= 1.0 read OPENAI_BASE_URL, older
      # openai-python and the LiteLLM SDK read OPENAI_API_BASE. The `/v1` suffix
      # is load-bearing too — see the retired module's header (git history) for
      # the measured 401/404-vs-routing failure mode without it. The key itself
      # is a LiteLLM virtual key in the Keychain (`openai.com:api`), unrelated
      # to this URL.
      home.sessionVariables = {
        OPENAI_BASE_URL = "https://ai.infin8it.ca/v1";
        OPENAI_API_BASE = "https://ai.infin8it.ca/v1";
      };

      # Chrome DevTools Protocol, in ATTACH mode against Opera Air. The attach flag is
      # picked at spawn time by probing /json/version — neither --browser-url nor
      # --autoConnect works in both browser modes; see modules/shared/mcp.nix. One flag turns on BOTH the gateway server and the
      # `nix-chromium-debug` launcher — they are gated together on purpose, so there
      # is no state where something can reach a browser without the operator having
      # enabled debugging deliberately (in-browser, or via that launcher).
      #
      # Safe to leave on permanently, MEASURED 2026-09-06 rather than assumed: with
      # nothing listening on the port, the server still answers `initialize` and
      # stays alive (45s, no exit) — it only touches a browser lazily, when a tool
      # needs one. So it does NOT dark the gateway the way a server that exits at
      # startup would (the failure mode postgres and localAdapter warn about in
      # modules/shared/mcp.nix). Individual tool calls simply fail until a browser
      # is listening; `devtools-doctor.sh` in the chrome-devtools plugin says which
      # of the three causes it is.
      #
      # What is NOT persistent, deliberately: debugging itself. Opera Air re-prompts
      # per session and `nix-chromium-debug` is hand-run and dies with the browser
      # window — because an open remote-debugging port is an unauthenticated control
      # channel over a profile holding live logins. Measured 2026-09-07: Opera stores
      # no persistent consent key, so there is nothing to make it stop asking.
      local.mcpGateway.chromeDevtools.enable = true;

      # Per-user container runtime (Colima via home-manager's services.colima),
      # replacing the docker-desktop cask whose privileged helper was bound to
      # one username. Operator only for now — the izzy block above asserts he has
      # no launchd agents until his first login. Why/cost/migration:
      # modules/shared/containers.nix.
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
      # scrcpy — mirror/control a PHYSICAL Android phone on the Mac (pulls its own
      # adb; the android-platform-tools cask provides the adb mobile-mcp uses).
      "scrcpy"
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
      # IMPORT into the app, never run (local.wireguardConfigs, home.nix).

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
      # Audacity — multi-track audio editor. Pairs with the blackhole-2ch cask
      # below: BlackHole is a virtual output device, so routing an app's audio
      # into it gives Audacity a capture source for system audio, which macOS
      # otherwise refuses to expose.
      # IZZY-ONLY (see `izzyApps`). The blackhole-2ch driver above stays SHARED —
      # it is a system audio device (/Library), not an app, and cannot be
      # per-user even in principle.
      {
        name = "audacity";
        args = {
          appdir = izzyApps;
        };
      }
      # Android SDK cmdline tools (sdkmanager/avdmanager) — backs `android-emu`
      # (modules/shared/home.nix), which boots VIRTUAL Android emulators.
      "android-commandlinetools"
      # adb/fastboot — the bridge mobile-mcp drives to automate a physical phone.
      "android-platform-tools"
      "blackhole-2ch"
      "bruno"
      # CapCut — the video editor. IZZY-ONLY (see `izzyApps`): installed into his
      # home, so it never appears in the operator's Finder/Spotlight/Launchpad.
      {
        name = "capcut";
        args = {
          appdir = izzyApps;
        };
      }
      # Claude Desktop — the chat GUI (distinct from the claude-code CLI, nixpkgs).
      "claude"
      # `docker-desktop` is GONE (2026-09-16): its privileged helper bound the
      # machine-wide socket to one username. The runtime is now per-user Colima —
      # modules/shared/containers.nix (`local.containers`); the `docker*` brews
      # above stay as the client.
      "dropbox"
      # escrcpy — graphical frontend for scrcpy (the `scrcpy` brew above), for
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
      {
        name = "escrcpy";
        postinstall = "/usr/bin/xattr -dr com.apple.quarantine /Applications/Escrcpy.app";
      }
      # Google Chrome — the DAILY browser and the holder of http/https
      # (`local.defaultBrowser = "chrome"`, modules/shared/home.nix). It is here for
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
      # ungoogled-chromium cask. Settings live in modules/shared/home.nix.
      "ghostty"
      "iina"
      # Inkscape is gone on purpose (2026-09-15) — do not re-add.
      # LibreOffice — provides the `soffice` CLI the docx/pptx/xlsx/pdf Claude Code
      # skills (modules/shared/home.nix programs.claude-code.skills) already hardcode
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
      # OpenDesign — the local-first design-agent desktop app (Electron; its
      # stdio MCP server is declared per-client in modules/shared/mcp.nix).
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
      # Opera — IZZY-ONLY (see `izzyApps`), and his default browser
      # (home-manager.users.izzy above). Declared here for the first time: it was
      # a hand-installed .app until 2026-09-15, which `cleanup = "uninstall"`
      # never touched because Homebrew did not know about it.
      #
      # A cask move does NOT move a profile — profiles are per-user, so Izzy gets
      # a FRESH Opera. The operator's old profile (60 saved logins and the
      # Claude↔Opera MCP connector grant) does not come with it.
      {
        name = "opera";
        args = {
          appdir = izzyApps;
        };
      }
      "proton-drive"
      "raspberry-pi-imager"
      "slack"
      # Slack's official CLI for building/deploying Slack apps (docs.slack.dev/tools/slack-cli).
      # Cask, not nixpkgs' same-named "slack-cli" — that's an unrelated, unmaintained
      # rockymadden/slack-cli webhook-poster, not this tool.
      "slack-cli"
      "telegram"
      # Übersicht — desktop widgets rendered as web views behind every window.
      # Cask because it is a signed .app with no nixpkgs/home-manager packaging;
      # the ONE widget the fleet declares (a full-screen HTML file) is placed by
      # modules/shared/ubersicht.nix (local.ubersicht.htmlWidget).
      "ubersicht"
      # ungoogled-chromium — Chromium without the Google integration. Cask because
      # nixpkgs' chromium/ungoogled-chromium are *-linux only (no darwin build), and
      # the plain `chromium` cask is deprecated (fails the macOS Gatekeeper check,
      # disabled 2026-09-01). Its declarative config — the sideloaded iCloud
      # Passwords extension + Apple's native-messaging host, which macOS otherwise
      # ships to Chrome and Firefox ONLY — lives in modules/shared/chromium.nix.
      "ungoogled-chromium"
      "visual-studio-code"
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
    # That reaping is MACHINE-WIDE, not per-account. `brew bundle --force-cleanup`
    # runs once, as the primary user (`ismail`), and Homebrew's mas extension
    # uninstalls every installed-but-undeclared App Store app it sees — and
    # `mas list` sees the whole machine, so an app izzy bought on HIS Apple ID is
    # reaped by ismail's activation just the same. Policy: anything izzy wants to
    # keep is declared HERE (or installed outside MAS). The value itself,
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
      # Plash — put a website on your desktop as the wallpaper. App Store–only
      # (no Homebrew cask). https://apps.apple.com/ca/app/plash/id1494023538
      Plash = 1494023538;
    };
  };
}
