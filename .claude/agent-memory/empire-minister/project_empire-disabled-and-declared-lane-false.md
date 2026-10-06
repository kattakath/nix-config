---
name: empire-disabled-and-declared-lane-false
description: empire@kattakath was turned OFF on 2026-10-06 as an explicit `false`, not a deletion — deleting a declared key leaves the stale `true` the last activation wrote
metadata:
  type: project
---

`empire@kattakath` is **`false`** in `local.claudePlugins.declared`
(`modules/home/default.nix`), since **2026-10-06**. Landed as `74bec9f` straight on `main`,
activated (system generation 498 → 499), and confirmed on the live
`~/.claude/settings.json` (`enabledPlugins["empire@kattakath"] == False`).

**Why:** the operator judged the plugin inefficient in use. While enabled, `empire`'s
manifest `settings.agent = "empire:queen"` changed the **default agent of every session on
this Mac** with no flag — so this is not a cosmetic toggle. Do not re-enable it without the
operator asking.

**How to apply — the mechanism, which is the part that gets guessed wrong:**

- `declared` is an `attrsOf bool` **re-asserted into `~/.claude/settings.json` on every
  activation**, where `false` is first-class (`modules/home/claude-plugins.nix`, the
  `declared` option description: "`true` enables, `false` disables").
- **Deleting the key does NOT disable the plugin.** No key is emitted, so the jq merge in
  `claude-code-settings.nix` (`.[0] * $nix[0]`) leaves whatever the previous activation
  wrote — i.e. the stale `true`. Deletion abandons the id; `false` disables it. The old
  in-tree comment claimed "deleting this line is the whole rollback" and was wrong.
- **The `"empire"` entry in `marketplaces.kattakath.plugins` must STAY.**
  `claude-plugins.nix` asserts every `declared` id names a plugin present in that
  marketplace's `plugins` list — removing it fails the build. It also keeps the id
  resolvable from `/plugin`.
- `declared` is a **default, not a lock**: a session can flip it by hand until the next
  `activate`.

Related: [[empire-plugin-landed-learnings]] (the plugin's prompt text lives in
`kattakath/skills`, not here — disabling it here changes nothing there).
