# Tool catalogue

**The published package exposes fewer tools than upstream's documentation lists.** Measured
against `chrome-devtools-mcp@1.8.0` (npm latest, published 2026-08-25) on 2026-09-06:
**29 tools**, identical in both attach mode (`--browser-url`) and launch mode
(`--isolated --headless`). Upstream's generated `docs/tool-reference.md` is written from
`main` and lists roughly twice that.

Trust this list for what can be called today; trust upstream's doc for where the project is
heading. Re-measure after a version bump — never assume a tool exists because a doc mentions
it. The client's own tool list is the final authority.

## The 29 tools that exist in 1.8.0

### Input (9)

`click` · `drag` · `fill` · `fill_form` · `handle_dialog` · `hover` · `press_key` ·
`type_text` · `upload_file`

Elements are addressed by **`uid` from a page snapshot**, never by CSS selector. The loop is
`take_snapshot` → read the `uid` → act, and a `uid` goes stale as soon as the DOM changes.

- **`fill_form` over repeated `fill`/`click`.** Upstream is explicit: always prefer it for
  forms — faster, more reliable, fewer turns.
- **`handle_dialog`** is the only exit from a JavaScript dialog. A dialog blocks the page, so
  an unhandled one makes every later call look hung.
- Most accept `includeSnapshot` (default `false`); setting it saves a follow-up snapshot.

### Navigation (6)

`navigate_page` · `new_page` · `close_page` · `list_pages` · `select_page` · `wait_for`

Page-scoped tools take a **`pageId`** — confirm it with `list_pages` rather than assuming the
last-opened page is current. Prefer `wait_for` to sleeping; the automation already waits for
action results.

### Emulation (2)

`resize_page` · `emulate`

- **`resize_page`** sets an exact viewport — the precise instrument for CSS breakpoints. One
  variable, repeatable, comparable between runs.
- **`emulate`** covers device presets, CPU throttling and network conditions. Several
  variables at once: right for "does this work on a slow phone", wrong for "which breakpoint
  fires".

### Performance (3)

`performance_start_trace` · `performance_stop_trace` · `performance_analyze_insight`

Record with `reload: true` to capture load and `autoStop: true` to end at a settling point,
then analyse a **named insight** rather than reading raw trace JSON.

This is the group `--no-performance-crux` protects: without it, trace URLs leave the machine.

### Network (2)

`list_network_requests` · `get_network_request`

List first, then fetch the single request for headers, timing and status.

### Debugging (6)

`evaluate_script` · `list_console_messages` · `get_console_message` · `take_snapshot` ·
`take_screenshot` · `lighthouse_audit`

- **`evaluate_script`** runs JavaScript in the page — how measurement probes execute.
- **`take_snapshot`** returns structured content and every `uid`; **`take_screenshot`**
  returns pixels. Snapshots drive interaction, screenshots are evidence for a human.
- **`list_console_messages`** carries source-mapped stacks. An empty console where an error
  was expected usually means the code never ran.

### Memory (1)

`take_heapsnapshot`

Only the capture tool ships in 1.8.0.

## Documented upstream but ABSENT from 1.8.0

Do not plan a workflow around these until a measurement shows them present:

| Group | Missing tools | Consequence |
|---|---|---|
| **Extensions** | `install_extension`, `list_extensions`, `reload_extension`, `trigger_extension_action`, `uninstall_extension` | **No way to load an extension into the driven browser.** Testing a userscript manager means attaching to a browser that already has one. |
| **Memory** | the other 12 `*_heapsnapshot*` tools | A snapshot can be captured but not compared or queried, so the compare-two-snapshots leak workflow is unavailable. |
| **PWA** | `get_os_app_state`, `install_pwa`, `launch_pwa`, `uninstall_pwa` | No PWA lifecycle control. |
| **Third-party / WebMCP** | `list_3p_developer_tools`, `execute_3p_developer_tool`, `list_webmcp_tools`, `execute_webmcp_tool` | Not available. |
| **Misc** | `click_at`, `screencast_start`, `screencast_stop` | No coordinate clicking and no screencast; `take_screenshot` is the evidence tool. |

The Extensions gap is the one that changes plans: the appealing idea of "launch a clean
isolated browser, install a userscript manager into it, test there" **cannot be done with
1.8.0**. Attaching to a browser that already has the extension is the only route today.

## Slim mode

`--slim` exposes a reduced set for basic navigate-and-read work. The full 29 are needed for
tracing, snapshots and network inspection.

## How this list was produced

An MCP `initialize` handshake followed by `tools/list` over stdio, against the real server in
both modes. Repeat that after any version bump rather than editing this file from a changelog.
