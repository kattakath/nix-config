# The two-guest slot budget's DEFAULTS, ONE spelling. ./slots.nix builds the
# option defaults from it and packages/gitlab-tart.nix (passed it as an argument,
# never a `..` path) builds its imperative-route fallbacks from it, so the two
# lanes cannot resolve different slot dirs or ceilings.
{
  # Relative to the login user's home: primaryUserHome at eval, $HOME at runtime.
  stateSubdir = ".local/state/tart-runner";
  # Apple's hard ceiling of two concurrent macOS guests per host.
  max = 2;
}
