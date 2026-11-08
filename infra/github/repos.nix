# ---- The repos on the shared gate, and their live ruleset ids --------------------------
#
# Every repo that runs `kattakath/.github`'s shared `gate` (ADR-012 step 3). The id is the
# live ruleset's, for its `import` block (the provider's import id is `<repo>:<id>`).
# fleet-doctor's manifest (.claude/skills/fleet-doctor/fleet-repos.txt) is a NARROWER set,
# composition repos only, so it cannot be the source of this list.
#
# The OWNER decides the tier (stack.nix): only an organization's public repo can have a merge
# queue, so `kattakath` repos are Tier A (queue + QUEUE_ENABLED) and `ismailkattakath` repos
# Tier B (auto-merge only). Add a repo here only after `apply-ruleset.sh` created its ruleset.
{
  kattakath = {
    "nix-config".main = 18461567;
    "skills".main = 23878103;
    "ircc-whatsapp-bot".main = 21202488;
    ".github".main = 26393290;
    "kattakath.github.io".main = 26397005;
    "ismail-landing".main = 26397009;
  };
  ismailkattakath = {
    "agentic-jobseek".main = 26396994;
    "agentic-ledger".main = 26328556;
    "agentic-nomad".main = 26328557;
    "dotfiles".main = 26397000;
    # The one ruleset not built from the shared templates: release tags are immutable.
    "jsonresume-connect" = {
      main = 25995382;
      releaseTags = 25995384;
    };
    "userscripts".main = 23271873;
    "website".main = 26397049;
    "workspace-studio".main = 26397055;
  };
}
