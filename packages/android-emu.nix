# `android-emu [avd-name] [emulator-args…]` — boot an Android emulator,
# provisioning on first run. If the SDK packages or the AVD are missing it
# installs them via the Homebrew `sdkmanager`/`avdmanager` (the
# android-commandlinetools cask + ANDROID_HOME from modules/home/default.nix), then launches.
# Uses a native arm64 system image (fast on Apple Silicon). macOS-only.
#
# The AVD name selects the system image: a name containing "play" — the DEFAULT
# `pixel_play`, launched by a bare `android-emu` — gets the Google Play image (has
# the Play Store, not rootable); any other name (e.g. `android-emu pixel`) gets
# Google APIs (no Play Store, dev-friendly). Each AVD is created with a 64G data
# partition (the `pixel` device default of 6G fills up fast).
#
# Launch defaults that make the emulator actually usable on Apple Silicon:
#   -gpu swiftshader_indirect  software rendering; host-GPU emulation renders a
#                              gray screen here, so we force software.
#   -no-snapshot               always cold boot; a corrupt saved snapshot is
#                              what makes the *second* launch hang on gray.
# Both are also baked into each AVD's config.ini (alongside hw.keyboard=yes so
# the Mac keyboard types into Android). Extra args after the name override the
# emulator flags, so `android-emu pixel -gpu host` still works.
#
# androidSdkRoot and brewPrefix are passed by modules/home/default.nix, which owns both.
{
  writeShellApplication,
  coreutils,
  gnugrep,
  gnused,
  androidSdkRoot,
  brewPrefix,
}:
writeShellApplication {
  name = "android-emu";
  runtimeInputs = [
    coreutils
    gnugrep
    gnused
  ];
  text = ''
    ANDROID_HOME="''${ANDROID_HOME:-${androidSdkRoot}}"
    export ANDROID_HOME
    avd="''${1:-pixel_play}"
    sdkmanager="${brewPrefix}/bin/sdkmanager"
    avdmanager="${brewPrefix}/bin/avdmanager"
    emulator="$ANDROID_HOME/emulator/emulator"

    # Google Play image for *play* AVDs, Google APIs otherwise.
    case "$avd" in
      *play*) image="system-images;android-35;google_apis_playstore;arm64-v8a" ;;
      *)      image="system-images;android-35;google_apis;arm64-v8a" ;;
    esac

    if [ ! -x "$sdkmanager" ]; then
      echo "android-emu: sdkmanager not found — run 'activate' to install the android-commandlinetools cask" >&2
      exit 1
    fi

    # First run: accept licenses + install the emulator and platform-tools.
    if [ ! -x "$emulator" ]; then
      echo "android-emu: installing SDK packages (first run, a few GB)…" >&2
      yes | "$sdkmanager" --licenses >/dev/null || true
      "$sdkmanager" "platform-tools" "emulator"
    fi

    # Ensure the chosen system image is present (~1.5 GB per image).
    if [ ! -d "$ANDROID_HOME/''${image//;//}" ]; then
      echo "android-emu: downloading system image ($image)…" >&2
      yes | "$sdkmanager" --licenses >/dev/null || true
      "$sdkmanager" "$image"
    fi

    # Create the AVD on first use (decline the custom-hardware prompt), then
    # persist the settings that make it work: software GPU + hardware keyboard,
    # and PlayStore.enabled for play images.
    if ! "$avdmanager" list avd -c | grep -qx "$avd"; then
      echo "android-emu: creating AVD '$avd'…" >&2
      echo "no" | "$avdmanager" create avd -n "$avd" -k "$image" -d pixel

      cfg="$HOME/.android/avd/$avd.avd/config.ini"
      set_key() {
        if grep -q "^$1=" "$cfg"; then
          sed -i "s|^$1=.*|$1=$2|" "$cfg"
        else
          echo "$1=$2" >> "$cfg"
        fi
      }
      set_key hw.gpu.enabled yes
      set_key hw.gpu.mode swiftshader_indirect
      set_key hw.keyboard yes
      # Serious internal-storage bump: the `pixel` device profile defaults to a
      # cramped 6G data partition (fills up fast once the Play Store + a few apps
      # land). 64G is sparse (qcow2), so it costs real disk only as it fills.
      set_key disk.dataPartition.size 64G
      case "$avd" in *play*) set_key PlayStore.enabled yes ;; esac
    fi

    exec "$emulator" -avd "$avd" -no-snapshot -gpu swiftshader_indirect "''${@:2}"
  '';
}
