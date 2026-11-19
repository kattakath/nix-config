# ---- The Workspace MCP apps, as DATA ------------------------------------------
#
# ONE list, imported by every stack that needs an app's name or host (`git grep
# workspace-mcp-apps.nix`), so a host cannot exist in one and not another.
#
# ONE PORTAL for every app (https://<portalLabel>.kattakath.com/mcp), so claude.ai holds
# ONE connector, "Kattakath Workspace". Each app is still its own MCP server with its
# own per-user Google grant and its own tool allowlist.
#
# `tools` is the ALLOWLIST every surface sees (phone, web, Mac): each portal lists the
# server with `default_disabled = true` and enables only these (mcp-portals.nix).
# Operator decision 2026-11-19: ALL, GUARDED. Every tool Google's servers sync is
# enabled (it was READ + DRAFTS from the 2026-11-14 security audit until then). The
# guard is two layers, and checks.<system>.mcp-portal-posture fails when an enabled
# outward, destructive or edit tool lacks either: (1) an explicit
# `mcp__*__<app>_<tool>` ask rule in modules/home/claude-guardrails.nix, the floor that
# still prompts under bypassPermissions; (2) a rule in the kattakath-workspace plugin's
# write guard (kattakath/skills), which names the recipients, labels, ranges and write
# mode in its prompt. Neither reaches claude.ai web or phone, cloud sessions or routines,
# where the skill's confirm table is the only guard. A tool Google ADDS upstream stays off until it is listed here.
#
# `scopes` is the MINIMUM that covers `tools`, read 2026-11-19 from each tool's
# "Authorization Scopes" on developers.google.com/workspace/<app>/…/reference/mcp/
# tools_list/<tool> (each tool accepts the scopes listed there, usually several; the
# narrowest set that satisfies EVERY tool wins). It is NOT the server's
# `scopes_supported`, which is the superset and was the first deploy's value. A doc page
# can be wrong (Chat's search_conversations, below), so each change is proven live.
# A token keeps the scopes it was minted with: after a change, revoke the
# "Kattakath Family" grant (myaccount → third-party access) and reconnect.
# Gmail: seven tools (trash_*, mark_*_spam, update_message_labels,
# apply_sensitive_*_label) and the untrash/unspam pair have NO tool page (404,
# 2026-11-19); their scope is inferred from the REST methods they wrap
# (users.messages|threads trash/modify accept gmail.modify). Their input schemas are in
# the tool list Cloudflare synced from Google's server (read the same day). No draft-only scope exists
# that `create_draft` accepts, so a LEAKED token could still send over the plain REST API.
#
# Plain data with no arguments: the zone, the operator and the client id are
# threaded in by the consumers, so nothing per-person lives here.
{
  # The portal's host label: https://mcp.<zone>/mcp follows claude.ai's own example URL
  # (https://mcp.example.com/mcp; operator, 2026-11-14). The app names below are the
  # Cloudflare MCP server ids, and so the prefix of every tool name (gmail_search_threads).
  portalLabel = "mcp";
  # A self-hosted app's host: Cloud Run's deterministic URL form. The ONE copy of the
  # formula, called by every stack that addresses a self-hosted server (the portal's
  # upstream, the service's own advertised URL, the Synthetic Monitoring target).
  runAppHost = projectNumber: h: "${h.service}-${projectNumber}.${h.region}.run.app";
  # What a self-hosted server answers when it is up, for its Cloud Run probes and its
  # Synthetic Monitoring check. workspace-mcp serves GET /health (200); a server without
  # a health route sets its own `health` (mcp-nixos: GET /mcp is 405, measured).
  healthOf =
    h:
    h.health or {
      path = "/health";
      status = 200;
    };
  apps = {
    gmail = {
      title = "Gmail";
      upstream = "gmailmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/gmail.modify"
      ];
      tools = [
        "search_threads"
        "get_thread"
        "get_message"
        "list_drafts"
        "get_draft"
        "list_labels"
        "create_draft"
        "label_thread"
        "label_message"
        "create_label"
        "untrash_thread"
        "untrash_message"
        "unmark_thread_spam"
        "unmark_message_spam"
        "unlabel_thread"
        "unlabel_message"
        "update_message_labels"
        "trash_thread"
        "trash_message"
        "mark_thread_spam"
        "mark_message_spam"
        "apply_sensitive_thread_label"
        "apply_sensitive_message_label"
      ];
    };
    calendar = {
      title = "Calendar";
      upstream = "calendarmcp.googleapis.com";
      scopes = [
        # Every event tool, read and write, accepts calendar.events (suggest_time
        # included); list_calendars needs a calendarlist scope.
        "https://www.googleapis.com/auth/calendar.events"
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
      ];
      tools = [
        "list_events"
        "get_event"
        "list_calendars"
        "suggest_time"
        "search_events"
        "create_event"
        "update_event"
        "delete_event"
        "respond_to_event"
      ];
    };
    drive = {
      title = "Drive";
      upstream = "drivemcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/drive.readonly"
        "https://www.googleapis.com/auth/drive.file"
      ];
      tools = [
        "search_files"
        "list_recent_files"
        "read_file_content"
        "download_file_content"
        "get_file_metadata"
        "get_file_permissions"
        "create_file"
        "copy_file"
      ];
    };
    docs = {
      title = "Docs";
      upstream = "docsmcp.googleapis.com";
      scopes = [
        # update_doc accepts documents, drive or drive.file; drive.file reaches only
        # files this client opened, so it cannot edit an existing Doc.
        "https://www.googleapis.com/auth/documents"
      ];
      tools = [
        "read_doc"
        "update_doc"
      ];
    };
    sheets = {
      title = "Sheets";
      upstream = "sheetsmcp.googleapis.com";
      scopes = [
        # insert_dimension accepts only drive or spreadsheets (no drive.file).
        "https://www.googleapis.com/auth/spreadsheets"
      ];
      tools = [
        "get_values"
        "get_spreadsheet"
        "update_values"
        "update_formulas"
        "update_spreadsheet"
        "insert_dimension"
      ];
    };
    slides = {
      title = "Slides";
      upstream = "slidesmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/presentations"
      ];
      tools = [
        "read_presentation"
        "read_slide_page"
        "read_slide_page_thumbnail"
        "update_presentation"
      ];
    };
    chat = {
      title = "Chat";
      upstream = "chatmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/chat.messages.readonly"
        # send_message accepts chat.messages or chat.messages.create; .create cannot
        # edit or delete existing messages, so it is the narrower of the two.
        "https://www.googleapis.com/auth/chat.messages.create"
        "https://www.googleapis.com/auth/chat.memberships.readonly"
        # Measured 2026-11-14: without it search_conversations gets a 403 insufficient-scope
        # from Google, although its doc page lists memberships.readonly as enough.
        "https://www.googleapis.com/auth/chat.spaces.readonly"
        # mark_as_read/unread; get/update_notification_settings.
        "https://www.googleapis.com/auth/chat.users.readstate"
        "https://www.googleapis.com/auth/chat.users.spacesettings"
      ];
      tools = [
        "search_conversations"
        "list_messages"
        "search_messages"
        "list_memberships"
        "get_notification_settings"
        "send_message"
        "mark_as_read"
        "mark_as_unread"
        "update_notification_settings"
      ];
    };
    # People's MCP server rides the People API's own host, not a `peoplemcp` one.
    people = {
      title = "People";
      upstream = "people.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/directory.readonly"
        "https://www.googleapis.com/auth/userinfo.profile"
        "https://www.googleapis.com/auth/contacts.readonly"
      ];
      tools = [
        "search_contacts"
        "search_directory_people"
        "get_user_profile"
      ];
    };
    # Google's cross-app search server, found in the project's `--available` API list,
    # not documented alongside the per-app servers. Its `scopes_supported` mixes read
    # and write; only the read-only ones are requested, since its one tool searches.
    # KEPT, but last resort (operator, 2026-11-14): the result cannot be narrowed
    # (`pageSize`/`pageToken` are "currently ignored"), and Chat hits carry full
    # message bodies. Measured: one "invoice" query returned 30 hits, 136,585 chars,
    # over claude.ai's tool-result cap. The portal has no per-server "off" flag (only
    # per-tool), so "off by default" lives in the plugin skill: per-app search first.
    workspace = {
      title = "Search";
      upstream = "workspacemcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/gmail.readonly"
        "https://www.googleapis.com/auth/drive.readonly"
        "https://www.googleapis.com/auth/calendar.readonly"
        "https://www.googleapis.com/auth/chat.messages.readonly"
        "https://www.googleapis.com/auth/chat.spaces.readonly"
        "https://www.googleapis.com/auth/chat.memberships.readonly"
      ];
      tools = [ "search_corpus" ];
    };
    # TRIAL (2026-11-14, operator: "I use these google services"). Maps is on Google's
    # supported-products list and serves /mcp, not /mcp/v1. Probed and DROPPED the same
    # day: Home (synced, but every call answers "At least one Home Premium Advanced
    # subscription is required", while its only scope can control devices), Keep (consent refused `keep.readonly`, Error 400 invalid_scope) and
    # Meet (consent passed, then Cloudflare's tool sync failed: meetmcp is not
    # enable-able in the project). Tasks (tasksmcp) was never enable-able either.
    #
    # Maps Grounding Lite: public map data, every tool readOnlyHint. Free while
    # Experimental; billed per call if it reaches GA (developers.google.com/maps/ai/
    # usage-and-billing). The gcp-budget alert covers the project.
    maps = {
      title = "Maps";
      upstream = "mapstools.googleapis.com";
      path = "/mcp";
      scopes = [ "https://www.googleapis.com/auth/maps-platform.mapstools" ];
      tools = [
        "search_places"
        "lookup_weather"
        "compute_routes"
        "search_along_route"
        "resolve_names"
        "resolve_maps_urls"
      ];
    };
    # SELF-HOSTED (2026-11-18): Google serves no Tasks MCP server (not on its
    # supported-products list; tasksmcp is not enable-able), and cloud routines need
    # Tasks. So upstream taylorwilsdon/google_workspace_mcp runs on Cloud Run
    # (infra/gcp/self-hosted-mcp.nix renders it from `selfHosted`) in EXTERNAL OAuth mode:
    # the portal runs the Google sign-in and stores the grant exactly as for Google's
    # servers, and sends the user's Google access token as a Bearer, which the server
    # checks against Google's userinfo. The server holds no token store and no
    # client secret. The host is the service's run.app URL, composed in
    # mcp-portals.nix from the project number.
    #
    # Operator decision 2026-11-18: READ + WRITE. Tasks are private to the user, so
    # writing is not outward. `manage_task`/`manage_task_list` also DELETE (one tool,
    # an `action` argument), and the allowlist cannot split that.
    # `scopes` = the server's own `scopes_supported` (measured from its 401 and its
    # protected-resource metadata): tasks for the tools, openid/email/profile for the
    # userinfo check that validates each token.
    tasks = {
      title = "Tasks";
      selfHosted = {
        service = "tasks-mcp";
        region = "us-central1";
        # The server's `--tools` family.
        family = "tasks";
      };
      path = "/mcp";
      scopes = [
        "https://www.googleapis.com/auth/tasks"
        "https://www.googleapis.com/auth/tasks.readonly"
        "https://www.googleapis.com/auth/userinfo.email"
        "https://www.googleapis.com/auth/userinfo.profile"
        "openid"
      ];
      # Every Tasks tool. They sit in TWO tiers upstream (core: get_task, list_tasks,
      # manage_task; complete: the list tools), so the server runs tier `complete`.
      tools = [
        "list_task_lists"
        "get_task_list"
        "manage_task_list"
        "list_tasks"
        "get_task"
        "manage_task"
      ];
    };

    # The SAME self-hosted pattern as `tasks` (2026-11-18): Google hosts no MCP server for
    # Forms or for Contacts writes, and Google's Docs server reads a document as ~2 MB of
    # structure. Each is its own Cloud Run service (one family, one scope set, one blast
    # radius), rendered by infra/gcp/foundation.nix from `selfHosted`. `scopes` = each
    # server's own advertised set, measured from its 401 with workspace-mcp 2.5.0.
    #
    # Operator decision 2026-11-18: Forms and Contacts get EVERY tool (create, edit,
    # publish forms; create, edit, delete contacts and groups).
    forms = {
      title = "Forms";
      selfHosted = {
        service = "forms-mcp";
        region = "us-central1";
        family = "forms";
      };
      path = "/mcp";
      scopes = [
        "https://www.googleapis.com/auth/forms.body"
        "https://www.googleapis.com/auth/forms.body.readonly"
        "https://www.googleapis.com/auth/forms.responses.readonly"
        "https://www.googleapis.com/auth/userinfo.email"
        "https://www.googleapis.com/auth/userinfo.profile"
        "openid"
      ];
      tools = [
        "create_form"
        "get_form"
        "batch_update_form"
        "set_publish_settings"
        "get_form_response"
        "list_form_responses"
      ];
    };
    contacts = {
      title = "Contacts";
      selfHosted = {
        service = "contacts-mcp";
        region = "us-central1";
        family = "contacts";
      };
      path = "/mcp";
      scopes = [
        "https://www.googleapis.com/auth/contacts"
        "https://www.googleapis.com/auth/contacts.readonly"
        "https://www.googleapis.com/auth/userinfo.email"
        "https://www.googleapis.com/auth/userinfo.profile"
        "openid"
      ];
      tools = [
        "search_contacts"
        "get_contact"
        "list_contacts"
        "manage_contact"
        "manage_contacts_batch"
        "list_contact_groups"
        "get_contact_group"
        "manage_contact_group"
      ];
    };
    # A SUPPLEMENT to Google's `docs` server, never a replacement (decision D1, revisited
    # 2026-11-19: Google's `docs` stays, since its update_doc is the one Docs writer):
    # compact Markdown and comments, which Google's read_doc lacks. READ-ONLY twice over: the server runs
    # WORKSPACE_MCP_READ_ONLY (it registers only read tools and asks only read scopes),
    # and the allowlist lists only reads.
    docsread = {
      title = "Docs Reader";
      selfHosted = {
        service = "docsread-mcp";
        region = "us-central1";
        family = "docs";
        readOnly = true;
      };
      path = "/mcp";
      scopes = [
        "https://www.googleapis.com/auth/documents.readonly"
        "https://www.googleapis.com/auth/drive.readonly"
        "https://www.googleapis.com/auth/userinfo.email"
        "https://www.googleapis.com/auth/userinfo.profile"
        "openid"
      ];
      tools = [
        "get_doc_as_markdown"
        "get_doc_content"
        "inspect_doc_structure"
        "list_document_comments"
        "search_docs"
      ];
    };

    # PUBLIC DATA, NO SIGN-IN (operator, 2026-11-19): nixpkgs packages and NixOS /
    # home-manager / nix-darwin options, so a Nix lookup works on every Claude surface
    # instead of only where the nix-flake-kit plugin's local server runs (that copy is
    # denied in deniedMcpServers). Upstream utensils/mcp-nixos publishes the image
    # (ghcr.io/utensils/mcp-nixos, Nix-built, entrypoint mcp-nixos) and documents HTTP
    # mode (README "Option 4", v3.1.1). It holds no secret and reads only public
    # search APIs, so the portal reaches it `unauthenticated`, and the posture gate
    # admits that ONLY for an app marked `public`. The portal's own Access gate still
    # decides who reaches it; one Cloud Run instance and the budget alert cap abuse.
    nixos = {
      title = "NixOS";
      public = true;
      selfHosted = {
        service = "nixos-mcp";
        region = "us-central1";
        server = "mcp-nixos";
        health = {
          path = "/mcp";
          status = 405;
        };
      };
      path = "/mcp";
      tools = [
        "nix"
        "nix_versions"
      ];
    };
  };
}
