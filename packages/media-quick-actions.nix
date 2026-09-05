# media-quick-actions (macOS only) — Finder right-click → SERVICES entries for
# the media-toolkit CLIs, generated declaratively.
#
# Note the submenu: these land under **Services**, not "Quick Actions", even
# with presentationMode = 11 below. Finder's Quick Actions submenu is fed by
# App Extensions and Shortcuts actions (see `defaults read pbs` → FinderActive,
# which lists only APPEXTENSION-* and is.workflow.actions.* entries); an
# Automator .workflow service cannot appear there. Verified on macOS 26.6.2.
#
# A Quick Action is just an Automator `.workflow` BUNDLE OF TWO PLISTS —
# Contents/Info.plist (what the menu item is called, and which file types it
# attaches to) and Contents/document.wflow (what it runs). Nothing needs
# Automator.app to author it, so both are generated here with
# `lib.generators.toPlist` and the bundle is linked into ~/Library/Services by
# home.nix. Verified: macOS registers a bundle reached through a SYMLINK, so
# the home.file/store-path model works — no copy-into-place needed.
#
# Two details that are load-bearing and non-obvious:
#
#   inputMethod = 1  — pass the selected files to the script as "$@". The
#     default (0) pipes them on stdin instead, which silently produces a
#     script that runs and does nothing.
#   presentationMode = 11  — what Automator writes for a Quick Action. Kept
#     because this exact bundle shape is the one verified working; it does NOT
#     actually move the item into the Quick Actions submenu (see above).
#
# The script execs an absolute /nix/store path because a Service inherits a
# minimal PATH, not the login shell's.
{
  lib,
  runCommand,
  writeText,
  writeShellApplication,
  callPackage,
  media-toolkit ? callPackage ./media-toolkit.nix { },
}:
let
  # One entry per menu item. `cmd` is appended to the store path, so adding an
  # action is a line here rather than another copy of the plist scaffolding.
  #
  # `sendTypes` decides which selections Finder offers the item on, and
  # `inputType` is Automator's matching declaration. They are per-action rather
  # than a shared constant because the actions do not agree: two are video-only,
  # while Fix File Extension is exactly the tool you reach for when the
  # extension is wrong, so it has to be offered on images too.
  actions = [
    {
      name = "Extract Audio";
      id = "extractAudio";
      cmd = "extract-audio"; # MP3 by default; --copy is the lossless path
      sendTypes = [ "public.movie" ];
      inputType = "com.apple.Automator.fileSystemObject.movie";
    }
    {
      name = "Fix Google Video";
      id = "fixGoogleVideo";
      cmd = "fix-google-video";
      sendTypes = [ "public.movie" ];
      inputType = "com.apple.Automator.fileSystemObject.movie";
    }
    {
      name = "Fix File Extension";
      id = "fixExtension";
      cmd = "fix-extension";
      # A JPEG named `.png` still gets `public.png` from its extension, which
      # conforms to `public.image`, so the mislabeled file this action exists
      # for does reach the menu. `public.folder` makes a whole export folder
      # one right-click. `public.data` — every extensionless file — is
      # deliberately absent: it would put this item on the menu for literally
      # everything, and a file with no extension is not the reported problem.
      sendTypes = [
        "public.image"
        "public.movie"
        "public.audio"
        "public.folder"
      ];
      inputType = "com.apple.Automator.fileSystemObject";
    }
  ];

  # Kept in its own file rather than a heredoc: the script has to survive being
  # embedded in a Nix indented string AND an XML plist, and quoting it twice is
  # how you get a Service that silently does nothing.
  notifyScript = writeText "notify.applescript" ''
    on run argv
      display notification (item 1 of argv) with title (item 2 of argv)
    end run
  '';

  # A Finder Service has nowhere to put stdout or stderr, so "skipped, already
  # done" and "crashed" look identical: you click and nothing happens. That
  # ambiguity is exactly what makes a working Service look broken, so each
  # action runs through this wrapper, which summarises the CLI's output into a
  # notification. The CLIs themselves stay quiet — in a terminal you can read
  # them directly.
  mkRunner =
    a:
    writeShellApplication {
      name = "media-service-${a.id}";
      runtimeInputs = [ media-toolkit ];
      text = ''
        output=$(${a.cmd} "$@" 2>&1) && rc=0 || rc=$?

        # grep -c prints 0 and exits 1 when nothing matches, and errexit is on.
        did=$(printf '%s\n' "$output" | grep -c ': done:' || true)
        skipped=$(printf '%s\n' "$output" | grep -cE ': (skip|OK):' || true)

        if [ "$rc" -ne 0 ]; then
          body=$(printf '%s\n' "$output" | grep ': error:' | head -1 || true)
          [ -n "$body" ] || body="Failed (exit $rc)"
        elif [ "$did" -eq 0 ] && [ "$skipped" -eq 1 ]; then
          # One file and nothing happened: say WHY. The CLIs skip for several
          # different reasons — already converted, no audio track, not found,
          # already editor-safe — and collapsing them all into "already done"
          # reports a missing file as a success.
          body=$(printf '%s\n' "$output" | grep -m1 -E ': (skip|OK):' \
                 | sed -E "s/^[^:]*: (skip|OK): '[^']*' *//; s/^[—-] *//" || true)
          [ -n "$body" ] || body="Nothing to do"
        elif [ "$did" -eq 0 ]; then
          # A directory walk stays quiet about files it had no opinion on, so
          # "0 skipped" is the normal shape of a folder that was already fine —
          # printing the count there reads like something went wrong.
          body="Nothing to do"
          [ "$skipped" -gt 0 ] && body="$body — $skipped skipped"
        else
          body="$did file(s) processed"
          [ "$skipped" -gt 0 ] && body="$body, $skipped skipped"
        fi

        # argv, never string interpolation: a body built from file paths will
        # contain a quote sooner or later.
        /usr/bin/osascript ${notifyScript} "$body" ${lib.escapeShellArg a.name} >/dev/null 2>&1 || true
      '';
    };

  infoPlist =
    {
      name,
      id,
      sendTypes,
      ...
    }:
    lib.generators.toPlist { escape = true; } {
      CFBundleIdentifier = "com.kattakath.services.${id}";
      CFBundleName = name;
      CFBundleShortVersionString = "1.0";
      NSServices = [
        {
          NSMenuItem.default = name;
          NSMessage = "runWorkflowAsService";
          # Only offer it inside Finder — these act on selected files.
          NSRequiredContext.NSApplicationIdentifier = "com.apple.finder";
          NSSendFileTypes = sendTypes;
        }
      ];
    };

  documentWflow =
    {
      runner,
      inputType,
      ...
    }:
    lib.generators.toPlist { escape = true; } {
      AMApplicationVersion = "2.10";
      AMDocumentVersion = "2";
      actions = [
        {
          action = {
            AMAccepts = {
              Container = "List";
              Optional = true;
              Types = [ "com.apple.cocoa.string" ];
            };
            AMActionVersion = "2.0.3";
            AMProvides = {
              Container = "List";
              Types = [ "com.apple.cocoa.string" ];
            };
            ActionBundlePath = "/System/Library/Automator/Run Shell Script.action";
            ActionName = "Run Shell Script";
            ActionParameters = {
              COMMAND_STRING = ''exec ${runner}/bin/${runner.name} "$@"'';
              CheckedForUserDefaultShell = true;
              inputMethod = 1; # files as "$@", NOT stdin
              shell = "/bin/zsh";
              source = "";
            };
            BundleIdentifier = "com.apple.RunShellScript";
            CFBundleVersion = "2.0.3";
            "Class Name" = "RunShellScriptAction";
            # Automator wants these present; the values only have to be stable.
            InputUUID = "0A1B2C3D-0001-4000-8000-000000000001";
            OutputUUID = "0A1B2C3D-0002-4000-8000-000000000002";
            UUID = "0A1B2C3D-0003-4000-8000-000000000003";
            isViewVisible = 1;
          };
          isViewVisible = 1;
        }
      ];
      connectors = { };
      workflowMetaData = {
        presentationMode = 11; # what Automator writes; item still lands under Services
        serviceApplicationBundleID = "com.apple.finder";
        serviceApplicationPath = "/System/Library/CoreServices/Finder.app";
        serviceInputTypeIdentifier = inputType;
        serviceOutputTypeIdentifier = "com.apple.Automator.nothing";
        workflowTypeIdentifier = "com.apple.Automator.servicesMenu";
      };
    };

  mkAction =
    a:
    runCommand "quick-action-${a.id}" { } ''
      d="$out/${a.name}.workflow/Contents"
      mkdir -p "$d"
      cp ${writeText "Info.plist" (infoPlist a)} "$d/Info.plist"
      cp ${writeText "document.wflow" (documentWflow (a // { runner = mkRunner a; }))} "$d/document.wflow"
    '';
in
runCommand "media-quick-actions"
  {
    passthru.actionNames = map (a: a.name) actions;
    meta.description = "Finder right-click → Services entries for the media-toolkit CLIs";
  }
  ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (a: "cp -r ${mkAction a}/*.workflow $out/") actions}
  ''
