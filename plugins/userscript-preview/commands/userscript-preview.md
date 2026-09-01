---
description: Re-inject a Violentmonkey userscript into the matching live Kapture tab (no activate + click).
argument-hint: "[path/to/script.user.js]"
---

Re-inject a userscript **now** via Kapture. Same path the PostToolUse hook takes after a save.

1. Resolve the file: `$ARGUMENTS` if given, else the userscript just edited, else ask.
2. Run:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/preview.py" <absolute-path-to.user.js>
```

3. Report the script's stdout `systemMessage` verbatim.

**Needs:** a matching tab (`@match`) with Kapture connected and **Allow JS execution** on. The userscript must be idempotent (`window.__nix*Teardown` at the top of the IIFE). Persist still needs `activate` + a Violentmonkey click — this is preview only.
