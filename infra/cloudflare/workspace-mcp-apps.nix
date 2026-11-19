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
# Operator decision 2026-11-14 after the security audit: READ + DRAFTS. Every tool
# Google annotates readOnlyHint, plus Gmail drafts, labels and untrash/unspam, plus
# Drive create/copy into the user's own Drive. Denied: Chat send, calendar invites
# and edits, Docs/Sheets/Slides edits, trash, spam, unlabel (outward, injectable into
# attacker-shared files, or able to hide security alerts). A tool Google ADDS upstream
# is denied until it is listed here.
#
# `scopes` is the MINIMUM that covers `tools`, read 2026-11-14 from each tool's
# "Authorization Scopes" on developers.google.com/workspace/<app>/…/reference/mcp/
# tools_list/<tool> (each tool accepts the scopes listed there, usually several). It is NOT the server's
# `scopes_supported`, which is the superset and was the first deploy's value.
# Narrowing does not shrink a token already stored: after a change, revoke the
# "Kattakath Family" grant (myaccount → third-party access) and reconnect.
# Gmail has no draft-only scope that `create_draft` accepts (only mail.google.com,
# gmail.compose or gmail.modify), and the label tools need gmail.modify anyway, so a
# LEAKED token could still send over the plain REST API; the allowlist blocks it in
# Claude. `update_message_labels` is NOT allowed: it can remove INBOX/UNREAD, which
# hides mail. Residual: adding a CATEGORY_* label moves a thread out of Primary.
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
      ];
    };
    calendar = {
      title = "Calendar";
      upstream = "calendarmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/calendar.events.readonly"
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
        "https://www.googleapis.com/auth/calendar.events.freebusy"
      ];
      tools = [
        "list_events"
        "get_event"
        "list_calendars"
        "suggest_time"
        "search_events"
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
        "https://www.googleapis.com/auth/documents.readonly"
      ];
      tools = [
        "read_doc"
      ];
    };
    sheets = {
      title = "Sheets";
      upstream = "sheetsmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/spreadsheets.readonly"
      ];
      tools = [
        "get_values"
        "get_spreadsheet"
      ];
    };
    slides = {
      title = "Slides";
      upstream = "slidesmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/presentations.readonly"
      ];
      tools = [
        "read_presentation"
        "read_slide_page"
        "read_slide_page_thumbnail"
      ];
    };
    chat = {
      title = "Chat";
      upstream = "chatmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/chat.messages.readonly"
        "https://www.googleapis.com/auth/chat.memberships.readonly"
        # Measured 2026-11-14: without it search_conversations gets a 403 insufficient-scope
        # from Google, although its doc page lists memberships.readonly as enough.
        "https://www.googleapis.com/auth/chat.spaces.readonly"
      ];
      tools = [
        "search_conversations"
        "list_messages"
        "search_messages"
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
    # A SUPPLEMENT to Google's `docs` server, never a replacement: compact Markdown and
    # comments, which Google's read_doc lacks. READ-ONLY twice over: the server runs
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
  };
}
