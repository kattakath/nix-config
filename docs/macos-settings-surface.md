# macOS settings surface — what `macos` can configure declaratively

A map of **what macOS settings this repo can drive declaratively**, what it
*actually* sets today, and the hard walls macOS puts in the way. Scoped to the
`macos` host (aarch64-darwin, the fleet's sole Mac — see `hosts/macos.nix`).

The machine is assembled by `mkDarwin` in `flake.nix`, which stacks four
configuration layers. "What can be configured" is bounded by which layers are
wired in — so the layers are the spine of this doc.

| Layer | Owns | Where |
| --- | --- | --- |
| **nix-darwin** (system) | macOS System Settings (`defaults`), launchd, users, security, networking | `modules/darwin/core.nix` + the `mkDarwin` module list |
| **Homebrew** (declarative) | GUI apps (casks) + CLI formulae nixpkgs doesn't carry | `modules/darwin/homebrew.nix` |
| **Home Manager** (per-user) | dotfiles + `programs.*` + per-user launchd agents | `modules/shared/home.nix`, `modules/shared/mcp.nix` |
| **Determinate Nix** | the Nix daemon + `/etc/nix/nix.conf` | `flake.nix` (`determinateNix.*`) |

> **Structural constraint:** Determinate Nix sets `nix.enable = false`, so the
> **entire `nix.*` option tree is unavailable on this host**. The only Nix knob is
> `determinateNix.customSettings` (used solely to add the Cachix substituter). Any
> guide that says "set `nix.settings.…`" does not apply to `macos` — it applies to
> the NixOS hosts (`nixpi`, `nixvm`).

---

## 1. What's configured today

Set in `modules/darwin/core.nix` (unless noted). This is a **deliberately curated
slice**, not the ceiling — §2 shows how much more is reachable.

### `system.defaults.*`

| Domain | Keys set today |
| --- | --- |
| `dock` | `autohide`, `orientation="left"`, `show-recents=false`, `tilesize=48`, `mru-spaces=false`, `minimize-to-application`, `show-process-indicators` |
| `finder` | `AppleShowAllExtensions`, `FXPreferredViewStyle="Nlsv"` (list), `ShowPathbar`, `ShowStatusBar`, `_FXShowPosixPathInTitle`, `_FXSortFoldersFirst`, `FXDefaultSearchScope="SCcf"`, `FXEnableExtensionChangeWarning=false` |
| `NSGlobalDomain` | `AppleInterfaceStyle="Dark"`, `KeyRepeat=2`, `InitialKeyRepeat=15`, `ApplePressAndHoldEnabled=false`, `AppleKeyboardUIMode=3`, the five `NSAutomatic*Substitution/Capitalization/Spelling` toggles off, `NSNavPanelExpandedStateForSaveMode{,2}` |
| `trackpad` | `Clicking` (tap-to-click) |
| `screensaver` | `askForPassword`, `askForPasswordDelay=0` |
| `loginwindow` | `GuestEnabled=false` |
| `screencapture` | `location` (→ rotated Screengrab dir), `type="png"`, `disable-shadow` |

### Beyond `system.defaults`

| Setting | Value | Note |
| --- | --- | --- |
| `security.pam.services.sudo_local.touchIdAuth` | `true` | Touch ID for `sudo` (this is the *current* option name; older configs used the now-deprecated `security.pam.enableSudoTouchIdAuth`) |
| `networking.applicationFirewall.enable` + `.enableStealthMode` | `true` | App firewall + stealth mode — reinforces the "no incoming traffic" posture |
| `environment.systemPackages` | `coreutils`, `curl` | system-wide packages |
| `system.stateVersion` / `system.primaryUser` | `5` / `userName` | migration tracking + who user-defaults apply to |

### Custom services this repo built (launchd)

- `services.fileRotation` (`modules/darwin/file-rotation.nix`) — turns directories
  into launchd user agents that rotate old files to Trash. Used for
  `~/Pictures/Screengrab`.
- `launchd.agents.mcp-gateway` (`modules/shared/mcp.nix`, Home-Manager side) — the
  localhost MCP gateway.

---

## 2. The available nix-darwin surface (mostly unused)

nix-darwin models ~23 typed `system.defaults` sub-domains (~180 options) plus two
freeform escape hatches. Full, per-option browsers:

- <https://mynixos.com/nix-darwin/options/system.defaults>
- <https://nix-darwin.github.io/nix-darwin/manual/> (the manual/option search)

Option names below are verified against the pinned nix-darwin source
(`LnL7/nix-darwin`, rev `d5bd9cd`). **A `✓` marks a key already set today.**

### `system.defaults.dock`
`appswitcher-all-displays` · `autohide ✓` · `autohide-delay` · `autohide-time-modifier` ·
`dashboard-in-overlay` · `enable-spring-load-actions-on-all-items` · `expose-animation-duration` ·
`expose-group-apps` · `launchanim` · `mineffect` · `minimize-to-application ✓` ·
`mouse-over-hilite-stack` · `mru-spaces ✓` · `orientation ✓` · `persistent-apps` ·
`persistent-others` · `scroll-to-open` · `showAppExposeGestureEnabled` · `showDesktopGestureEnabled` ·
`showLaunchpadGestureEnabled` · `showMissionControlGestureEnabled` · `show-process-indicators ✓` ·
`showhidden` · `show-recents ✓` · `slow-motion-allowed` · `static-only` · `tilesize ✓` ·
`magnification` · `largesize` · **hot corners:** `wvous-tl-corner` · `wvous-tr-corner` ·
`wvous-bl-corner` · `wvous-br-corner`

> `persistent-apps` / `persistent-others` let you pin the *exact* Dock contents
> declaratively. Hot-corner values are integer codes (1 = disabled, 2 = Mission
> Control, 4 = Desktop, 5 = screensaver, …).

### `system.defaults.finder`
`AppleShowAllFiles` · `ShowStatusBar ✓` · `ShowPathbar ✓` · `FXDefaultSearchScope ✓` ·
`FXRemoveOldTrashItems` · `FXPreferredViewStyle ✓` · `AppleShowAllExtensions ✓` · `CreateDesktop`
(hide desktop icons) · `QuitMenuItem` · `ShowExternalHardDrivesOnDesktop` · `ShowHardDrivesOnDesktop` ·
`ShowMountedServersOnDesktop` · `ShowRemovableMediaOnDesktop` · `_FXEnableColumnAutoSizing` ·
`_FXShowPosixPathInTitle ✓` · `_FXSortFoldersFirst ✓` · `_FXSortFoldersFirstOnDesktop` ·
`FXEnableExtensionChangeWarning ✓` · `NewWindowTarget` · `NewWindowTargetPath`

### `system.defaults.NSGlobalDomain` (system-wide UI + keyboard — the biggest domain)
`AppleShowAllFiles` · `AppleEnableMouseSwipeNavigateWithScrolls` · `AppleEnableSwipeNavigateWithScrolls` ·
`AppleFontSmoothing` · `AppleInterfaceStyle ✓` · `AppleIconAppearanceTheme` ·
`AppleInterfaceStyleSwitchesAutomatically` · `AppleKeyboardUIMode ✓` · `ApplePressAndHoldEnabled ✓` ·
`AppleShowAllExtensions` · `AppleShowScrollBars` · `AppleScrollerPagingBehavior` ·
`AppleSpacesSwitchOnActivate` · `NSAutomaticCapitalizationEnabled ✓` · `NSAutomaticInlinePredictionEnabled` ·
`NSAutomaticDashSubstitutionEnabled ✓` · `NSAutomaticPeriodSubstitutionEnabled ✓` ·
`NSAutomaticQuoteSubstitutionEnabled ✓` · `NSAutomaticSpellingCorrectionEnabled ✓` ·
`NSAutomaticWindowAnimationsEnabled` · `NSDisableAutomaticTermination` · `NSDocumentSaveNewDocumentsToCloud` ·
`AppleWindowTabbingMode` · `NSNavPanelExpandedStateForSaveMode ✓` · `NSNavPanelExpandedStateForSaveMode2 ✓` ·
`NSTableViewDefaultSizeMode` · `NSTextShowsControlCharacters` · `NSUseAnimatedFocusRing` ·
`NSScrollAnimationEnabled` · `NSWindowResizeTime` · `NSWindowShouldDragOnGesture` · `NSStatusItemSpacing` ·
`NSStatusItemSelectionPadding` · `InitialKeyRepeat ✓` · `KeyRepeat ✓` · `PMPrintingExpandedStateForPrint` ·
`PMPrintingExpandedStateForPrint2` · `AppleMeasurementUnits` · `AppleMetricUnits` · `AppleTemperatureUnit` ·
`AppleICUForce24HourTime` · `_HIHideMenuBar`

### `system.defaults.trackpad`
`Clicking ✓` · `Dragging` · `TrackpadRightClick` · `TrackpadThreeFingerDrag` · `ActuationStrength` ·
`FirstClickThreshold` · `SecondClickThreshold` · `TrackpadThreeFingerTapGesture` · (+ ~12 more gesture keys)

### Smaller typed domains
- **`screensaver`** — `askForPassword ✓`, `askForPasswordDelay ✓`
- **`loginwindow`** — `SHOWFULLNAME`, `autoLoginUser`, `GuestEnabled ✓`, `LoginwindowText`, `DisableConsoleAccess`, the `*Disabled*` shutdown/restart/sleep locks
- **`menuExtraClock`** — `Show24Hour`, `ShowSeconds`, `ShowDate`, `ShowDayOfWeek`, `FlashDateSeparators`, `IsAnalog`
- **`controlcenter`** (Sonoma+) — `BatteryShowPercentage`, `Sound`, `Bluetooth`, `AirDrop`, `Display`, `FocusModes`, `NowPlaying` (menu-bar toggles)
- **`WindowManager`** (Stage Manager) — `GloballyEnabled`, `AutoHide`, `StandardHideDesktopIcons`, `HideDesktop`, `EnableTilingByEdgeDrag`, `EnableTiledWindowMargins`, …
- **`spaces`** — `spans-displays`
- **`SoftwareUpdate`** — `AutomaticallyInstallMacOSUpdates`
- **`LaunchServices`** — `LSQuarantine` (the "app downloaded from the internet" prompt — a safety guard; left ON deliberately)
- **`smb`** · **`magicmouse`** · **`universalaccess`** · **`ActivityMonitor`** · **`hitoolbox`** · **`iCal`** — present, niche

### Beyond `system.defaults` (top-level nix-darwin options)
- **`system.keyboard`** — `enableKeyMapping`, `remapCapsLockToControl`, `remapCapsLockToEscape`, `swapLeftCommandAndLeftAlt`, `userKeyMapping` (arbitrary remaps). *Left at defaults today; a commented example sits in `core.nix`.*
- **`networking`** — `applicationFirewall.*` (used ✓), `computerName`, `hostName`, `localHostName`, `dns`, `wakeOnLan`, `knownNetworkServices`
- **`time.timeZone`** · **`power`** (`sleep`, `restartAfterPowerFailure`, `restartAfterFreeze`) · **`system.startup.chime`**
- **`fonts.packages`** — system-wide fonts · **`security.sudo.extraConfig`**, extra `security.pam.services`
- **`launchd.daemons` / `launchd.user.agents`** — arbitrary services (this repo uses both)
- **Window managers / bars** via `services.*` — see §5

### The escape hatches (reach anything untyped)
When nix-darwin has no typed option for a `defaults` key, write it raw:

```nix
system.defaults.CustomUserPreferences = {
  "com.apple.desktopservices" = {
    DSDontWriteNetworkStores = true;   # no .DS_Store on network shares
    DSDontWriteUSBStores = true;       # …or USB volumes
  };
  "com.apple.finder".ShowExternalHardDrivesOnDesktop = false;
};
# CustomSystemPreferences is the same, at the /Library/Preferences (system) scope.
```

This maps directly to per-user `defaults write` and covers domains nix-darwin
doesn't model (e.g. per-app plist keys). It is the reason the *practical* ceiling
is "almost anything `defaults`-backed," not "only the typed options."

---

## 3. Homebrew layer (`modules/darwin/homebrew.nix`)

Manages the **entire** brew surface with `onActivation.cleanup = "uninstall"`
(anything not listed is removed on activation):

- **`casks`** — GUI apps (currently ~25: browsers, editors, Docker Desktop, Slack, …)
- **`brews`** — CLI formulae (~45: cloudflared, kubernetes-cli, ffmpeg, pyenv, …)
- **`masApps`** — Mac App Store apps (empty today) · **`taps`** — third-party taps (none today)
- **`onActivation`** — `autoUpdate` / `upgrade` / `cleanup` policy

`nix-homebrew` (`modules/darwin/nix-homebrew.nix`) installs brew *itself* at the
arch prefix. Rule of thumb enforced in the header: tools available in nixpkgs stay
**out** of brew to avoid PATH collisions.

---

## 4. Home Manager layer (`modules/shared/home.nix`)

Per-user config; the GUI/macOS blocks are gated `lib.mkIf pkgs.stdenv.isDarwin`.
Configured today: `programs.git` (SSH commit signing), `programs.ssh` (full
`~/.ssh/config`), `programs.zsh` + `starship` + `bash`, `programs.gh`,
`programs.direnv`, `programs.vscode` (declarative extensions + ~80 `userSettings`),
`programs.claude-code` + the MCP gateway, `fonts.fontconfig`, `home.packages`.

**Available but unused, worth knowing:**
- **`targets.darwin.defaults`** — set **user** defaults from the Home-Manager side
  (the per-user analogue of `system.defaults`), and `targets.darwin.currentHostDefaults`
  for `-currentHost`-scoped keys.
- **`targets.darwin.linkApps` / `copyApps`** — surface Nix-installed GUI apps into
  `~/Applications/Home Manager Apps`. (Recent HM releases flipped the default toward
  `copyApps` because symlinked `.app`s confuse Spotlight/Gatekeeper — verify the
  exact `stateVersion` in the HM release notes before relying on it.)
- `programs.*` for more userland: `tmux`, `neovim`, `fzf`, `bat`, `eza`, `zoxide`,
  plus arbitrary `home.file` / `xdg.configFile` dotfiles and `home.sessionVariables`.

---

## 5. Window managers & bars (available via `services.*`)

nix-darwin ships first-class `services.*` modules (each ~ `enable` + `package` +
`config`/`configFile`, wired to a launchd agent). None are enabled here — `core.nix`
has a commented `services.yabai`/`services.skhd` placeholder.

| Tool | Module | Note |
| --- | --- | --- |
| **AeroSpace** (nikitabobko) | `services.aerospace` | i3-like WM, **no SIP disable needed** — the modern default choice. Also a HM `programs.aerospace`; don't enable both start mechanisms. |
| **yabai** | `services.yabai` | Tiling WM; full tiling needs SIP partially disabled (out of nix-darwin's scope). |
| **skhd** | `services.skhd` | Hotkey daemon, usually paired with yabai. |
| **sketchybar** (FelixKratz) | `services.sketchybar` | Custom status bar. |
| **jankyborders** (FelixKratz) | `services.jankyborders` | Focused-window border; pairs with any WM. |
| **spacebar** | `services.spacebar` | Older lightweight status bar. |
| **karabiner-elements** | `services.karabiner-elements` | Keyboard remapping (deeper than `system.keyboard`). |

⚠️ Every WM needs a **manual** Accessibility / Screen-Recording grant after install
— that's a TCC permission Nix cannot pre-authorize (see §7).

---

## 5a. Login items → launchd agents

The System Settings **Login Items** list ("Open at Login") is **not** declaratively
manageable — it's `SMAppService`-backed and protected like TCC (§7). The Nix-native
way to "start X at login" is a **launchd user agent** with `RunAtLoad`
(version-controlled, wipe-proof). This repo drives Maccy and Docker Desktop this way
(`launchd.user.agents.open-maccy` / `open-docker` in `core.nix`):

```nix
launchd.user.agents.open-maccy.serviceConfig = {
  ProgramArguments = [ "/usr/bin/open" "-a" "Maccy" ];
  RunAtLoad = true;
};
```

Two things to know:
- **Turn off the app's own "launch at login."** Modern apps self-register via
  `SMAppService`; if left on, the app re-adds itself and you get both mechanisms.
- **Where an app's checkbox files itself varies.** A full-app login item (Maccy)
  shows in the **"Open at Login"** list. A **background helper** (Docker Desktop's
  `com.docker.helper`) shows under **"Allow in the Background"** instead — which is
  why "Start Docker Desktop when you sign in" is checked yet Docker never appears in
  the top list. Docker's privileged `com.docker.vmnetd` daemon is separate (installed
  at install time) and unaffected.

## 6. Ecosystem projects (for the toolbox)

| Project | Role | When to reach for it |
| --- | --- | --- |
| **nix-darwin** (`nix-darwin/nix-darwin`) | system layer | always |
| **home-manager** | per-user layer | always |
| **nix-homebrew** (zhaofengli) | manage Brew *itself* + taps declaratively | reproducible brew (used ✓) |
| **mac-app-util** (hraban) | Spotlight/Dock trampolines for Nix-installed `.app`s | if you install GUI apps via Nix instead of casks |
| **agenix** | in-repo encrypted secrets | used ✓ |

> **Org move (act on this eventually):** nix-darwin migrated from `LnL7/nix-darwin`
> to **`nix-darwin/nix-darwin`** (announced 2025-03-21, issue #1394). Our `flake.nix`
> input still points at `github:LnL7/nix-darwin` — it resolves today via GitHub's
> redirect but is deprecated. Repoint it to `github:nix-darwin/nix-darwin` on the
> next input bump. No hard EOL for the old URL is published.

---

## 7. The hard walls (what you *cannot* set declaratively)

1. **TCC / privacy permissions — hard no.** Accessibility, Full Disk Access, Screen
   Recording, Camera/Mic, Automation live in the SIP-protected TCC database with no
   supported CLI. Cannot be modified even as root. This is why the nixvm work hit TCC
   error `-1728`, and why any WM still needs a manual permission grant.
2. **FileVault** — no nix-darwin option enables/disables it or manages recovery keys
   (`fdesetup` / System Settings only).
3. **System Settings items with no `defaults` domain** — Apple ID / iCloud sign-in,
   Time Machine, Wi-Fi passwords & network locations, Focus modes, Touch ID
   enrollment, most Privacy & Security toggles.
4. **Settings that *moved out* of `defaults` in Ventura/Sonoma/Sequoia** — e.g.
   desktop wallpaper (opaque store since ~Sonoma; the old `defaults` path broke).
   Expect churn: a key that worked on Monterey can be a silent no-op on Sequoia. Add
   a "verify on your macOS version" hedge for `alf`/wallpaper/menu-bar keys.
5. **App-internal state that apps rewrite at runtime** (e.g. Claude Desktop's config)
   — reachable only via an activation-script merge, never fully *owned* (see the jq
   merge in `modules/shared/mcp.nix`).

### The "apply immediately" trick
Many defaults don't take effect until logout/restart (Dock, some keyboard/mouse
keys). The community workaround is Apple's private `activateSettings -u`:

```nix
system.activationScripts.postUserActivation.text = ''
  /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
'';
```

Not adopted here (a `darwin-rebuild switch` + occasional logout is fine for a
single operator), but it's the standard remedy if a setting seems to "not apply."

---

## 8. References

**Canonical**
- nix-darwin (new org): <https://github.com/nix-darwin/nix-darwin> · manual/options: <https://nix-darwin.github.io/nix-darwin/manual/>
- Option browsers: <https://mynixos.com/nix-darwin/options/system.defaults> · <https://mynixos.com/home-manager/options/targets.darwin>
- Home Manager manual: <https://nix-community.github.io/home-manager/>
- Org-move rationale: <https://github.com/nix-darwin/nix-darwin/issues/1394>

**Guides**
- Nixcademy, "Setting up Nix on macOS": <https://nixcademy.com/posts/nix-on-macos/>
- Davis Haupt, nix-darwin: <https://davi.sh/blog/2024/01/nix-darwin/> · VS Code on Nix: <https://davi.sh/blog/2024/11/nix-vscode/>
- Ian Johannesen, "Everything You Can Set on macOS with nix-darwin": <https://perlpimp.net/blog/everything-nix-darwin-macos/>
- Patrick Walsh, "Activate Your Preferences" (`activateSettings`): <https://medium.com/@zmre/nix-darwin-quick-tip-activate-your-preferences-f69942a93236>
- Draker Rossman, "Nix on macOS — the Good, the Bad and the Ugly" (candid limits): <https://drakerossman.com/blog/nix-on-macos-the-good-the-bad-and-the-ugly>

**Example configs**
- zmre/nix-config: <https://github.com/zmre/nix-config> · AeroSpace + sketchybar stack: <https://github.com/zmre/aerospace-sketchybar-nix-lua-config>
- AlexNabokikh/nix-config: <https://github.com/AlexNabokikh/nix-config>

---

*Verified against the pinned nix-darwin source (`LnL7/nix-darwin`, rev `d5bd9cd`).
Option availability tracks that pin; re-check after a `nix flake update` — macOS
also removes/relocates `defaults` keys across OS releases.*
