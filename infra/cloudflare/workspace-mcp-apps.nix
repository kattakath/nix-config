# ---- The Workspace MCP apps, as DATA ------------------------------------------
#
# ONE list, read by two stacks, so a host cannot exist in one and not the other:
#   infra/cloudflare/mcp-portals.nix   a Cloudflare MCP server per app, all in ONE portal
#   infra/cloudflare/kattakath-dns.nix the proxied CNAME the portal hostname needs
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
  };
}
