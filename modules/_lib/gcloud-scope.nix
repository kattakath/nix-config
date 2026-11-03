# The repo-scoped gcloud config dir and the ADC file inside it, as two shell `export`s.
# ONE copy for both places that set them: the devShell (modules/parts/devshell.nix, which
# carries the measured why of each line) and the launchd drift check
# (packages/terranix-drift.nix, handed this text by modules/parts/terranix.nix).
#
# NOT auto-imported — `modules/_lib/` is excluded from import-tree by convention
# (see ./nix-ld-libraries.nix). Consumers `import` it explicitly; a package receives it
# from the module that calls it, never by reaching into modules/ itself.
''
  export CLOUDSDK_CONFIG="''${XDG_CONFIG_HOME:-$HOME/.config}/gcloud-nix-config"
  export GOOGLE_APPLICATION_CREDENTIALS="$CLOUDSDK_CONFIG/application_default_credentials.json"''
