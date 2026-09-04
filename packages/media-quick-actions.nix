# media-quick-actions (macOS only) — Finder right-click → Quick Actions entries
# for the media-toolkit CLIs, generated declaratively.
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
#   presentationMode = 11  — "Quick Action". Other values put the item in the
#     Services menu but NOT in Finder's right-click Quick Actions submenu.
#
# The script execs an absolute /nix/store path because a Service inherits a
# minimal PATH, not the login shell's.
{
  lib,
  runCommand,
  writeText,
  callPackage,
  media-toolkit ? callPackage ./media-toolkit.nix { },
}:
let
  # One entry per menu item. `cmd` is appended to the store path, so adding an
  # action is a line here rather than another copy of the plist scaffolding.
  actions = [
    {
      name = "Extract Audio";
      id = "extractAudio";
      cmd = "extract-audio";
    }
    {
      name = "Extract Audio as MP3";
      id = "extractAudioMp3";
      cmd = "extract-audio --mp3";
    }
    {
      name = "Fix Google Video";
      id = "fixGoogleVideo";
      cmd = "fix-google-video";
    }
  ];

  infoPlist =
    { name, id, ... }:
    lib.generators.toPlist { } {
      CFBundleIdentifier = "com.kattakath.services.${id}";
      CFBundleName = name;
      CFBundleShortVersionString = "1.0";
      NSServices = [
        {
          NSMenuItem.default = name;
          NSMessage = "runWorkflowAsService";
          # Only offer it inside Finder — these act on selected files.
          NSRequiredContext.NSApplicationIdentifier = "com.apple.finder";
          NSSendFileTypes = [ "public.movie" ];
        }
      ];
    };

  documentWflow =
    { cmd, ... }:
    lib.generators.toPlist { } {
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
              COMMAND_STRING = ''exec ${media-toolkit}/bin/${cmd} "$@"'';
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
        presentationMode = 11; # Quick Action (Finder's submenu)
        serviceApplicationBundleID = "com.apple.finder";
        serviceApplicationPath = "/System/Library/CoreServices/Finder.app";
        serviceInputTypeIdentifier = "com.apple.Automator.fileSystemObject.movie";
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
      cp ${writeText "document.wflow" (documentWflow a)} "$d/document.wflow"
    '';
in
runCommand "media-quick-actions"
  {
    passthru.actionNames = map (a: a.name) actions;
    meta.description = "Finder Quick Actions (right-click) for the media-toolkit CLIs";
  }
  ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (a: "cp -r ${mkAction a}/*.workflow $out/") actions}
  ''
