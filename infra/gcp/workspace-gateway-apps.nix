# ---- The Workspace gateway's apps, as DATA -----------------------------------
#
# ONE list, read by two stacks, so a host cannot exist in one and not the other:
#   infra/gcp/workspace-gateway.nix   a Cloud Run domain mapping + a Pomerium route each
#   infra/cloudflare/kattakath-dns.nix  the DNS-only CNAME each mapping needs
#
# ONE HOST PER APP, never two routes on one host. Measured 2026-11-14 in the local
# spike: two MCP routes sharing a host (prefix + prefix_rewrite) handed one route the
# OTHER route's upstream token, and Google answered 403. A host per app keeps each
# route's upstream_oauth2 token store separate.
#
# `tools` is the ALLOWLIST the gateway enforces on every surface (phone, web, Mac):
# Pomerium denies any `tools/call` outside it (`mcp_tool: not_in`, workspace-gateway.nix).
# Operator decision 2026-11-14 after the security audit: READ + DRAFTS. Every tool
# Google annotates readOnlyHint, plus Gmail drafts, labels and untrash/unspam, plus
# Drive create/copy into the user's own Drive. Denied: Chat send, calendar invites
# and edits, Docs/Sheets/Slides edits, trash, spam, unlabel (outward, injectable into
# attacker-shared files, or able to hide security alerts). A tool Google ADDS upstream
# is denied until it is listed here.
#
# `scopes` is the MINIMUM that covers `tools`, read 2026-11-14 from each tool's
# "Authorization Scopes" on developers.google.com/workspace/<app>/…/reference/mcp/
# tools_list/<tool> (every tool takes ONE OF several). It is NOT the server's
# `scopes_supported`, which is the superset and was the first deploy's value.
# Narrowing does not shrink a token already stored: after a change, revoke the
# "Kattakath Family" grant (myaccount → third-party access) and reconnect.
# Gmail has no draft-only scope: gmail.modify (needed for labels) can also send over
# the plain REST API, so a LEAKED token could send; the allowlist blocks it in Claude.
#
# Plain data with no arguments: the zone, the operator and the client id are
# threaded in by the consumers, so nothing per-person lives here.
{
  # Every host is <app>.<zone> at the APEX level (operator, 2026-11-14: no
  # `workspace.` label). The app names are the host labels.

  # Pomerium's own sign-in host (authenticate_service_url), <label>.<zone>.
  # `authenticate`, Pomerium's own name for the service (operator, 2026-11-14), so
  # auth./sso./login. stay free for a future family IdP.
  authenticateLabel = "authenticate";

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
        "update_message_labels"
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
