# `android-emu [avd-name] [emulator-args…]` — boot an Android emulator, creating the AVD
# on first use. The SDK (emulator, platform-tools, cmdline-tools and the system images)
# is nixpkgs' androidenv, pinned by flake.lock and passed in as androidSdkRoot by
# modules/home/default.nix — nothing is installed at run time, so there is no sdkmanager
# step. Native arm64 images (fast on Apple Silicon). macOS-only.
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
# The GPU mode is also baked into each AVD's config.ini at creation (alongside
# hw.keyboard=yes so the Mac keyboard types into Android). Cold boot is baked in
# on EVERY launch (fastboot.forceColdBoot), because a bare `emulator -avd` that
# skips this wrapper otherwise quick-boots: loading a quick-boot snapshot also
# REVERTS the disk to it. Extra args after the name override the emulator flags, so
# `android-emu pixel -gpu host` still works.
{
  writeShellApplication,
  coreutils,
  gnugrep,
  gnused,
  androidSdkRoot,
  # { play, apis } sdkmanager ids, from the same attrset modules/home/default.nix
  # composes the SDK with — the single source for which images exist.
  androidSystemImages,
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
    avdmanager=$(echo "$ANDROID_HOME"/cmdline-tools/*/bin/avdmanager)
    emulator="$ANDROID_HOME/emulator/emulator"

    # Google Play image for *play* AVDs, Google APIs otherwise. Both ship in the SDK
    # (modules/home/default.nix's androidenv composition).
    case "$avd" in
      *play*) image="${androidSystemImages.play}" ;;
      *)      image="${androidSystemImages.apis}" ;;
    esac

    # Create the AVD on first use (decline the custom-hardware prompt), then
    # persist the settings that make it work: software GPU + hardware keyboard,
    # and PlayStore.enabled for play images.
    cfg="$HOME/.android/avd/$avd.avd/config.ini"
    set_key() {
      if grep -q "^$1=" "$cfg"; then
        sed -i "s|^$1=.*|$1=$2|" "$cfg"
      else
        echo "$1=$2" >> "$cfg"
      fi
    }

    if ! "$avdmanager" list avd -c | grep -qx "$avd"; then
      echo "android-emu: creating AVD '$avd'…" >&2
      echo "no" | "$avdmanager" create avd -n "$avd" -k "$image" -d pixel

      set_key hw.gpu.enabled yes
      set_key hw.gpu.mode swiftshader_indirect
      set_key hw.keyboard yes
      # Serious internal-storage bump: the `pixel` device profile defaults to a
      # cramped 6G data partition (fills up fast once the Play Store + a few apps
      # land). 64G is sparse (qcow2), so it costs real disk only as it fills.
      set_key disk.dataPartition.size 64G
      case "$avd" in *play*) set_key PlayStore.enabled yes ;; esac
    fi

    # Every launch, not just creation: an AVD made before this line still says
    # forceFastBoot=yes, which is what lets a bare `emulator -avd` quick-boot.
    set_key fastboot.forceColdBoot yes
    set_key fastboot.forceFastBoot no

    exec "$emulator" -avd "$avd" -no-snapshot -gpu swiftshader_indirect "''${@:2}"
  '';
}
