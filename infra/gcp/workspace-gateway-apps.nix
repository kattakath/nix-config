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
# `scopes` is each server's own `scopes_supported`, read 2026-11-14 from
#   https://<upstream>/.well-known/oauth-protected-resource/mcp/v1
# (RFC 9728 protected-resource metadata). Re-read it there when Google adds a tool;
# a scope missing here is a 403 on that tool, not an error at plan time.
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
        "https://mail.google.com/"
        "https://www.googleapis.com/auth/gmail.compose"
        "https://www.googleapis.com/auth/gmail.drafts"
        "https://www.googleapis.com/auth/gmail.drafts.create"
        "https://www.googleapis.com/auth/gmail.drafts.readonly"
        "https://www.googleapis.com/auth/gmail.labels"
        "https://www.googleapis.com/auth/gmail.labels.create"
        "https://www.googleapis.com/auth/gmail.labels.readonly"
        "https://www.googleapis.com/auth/gmail.messages"
        "https://www.googleapis.com/auth/gmail.messages.delete"
        "https://www.googleapis.com/auth/gmail.messages.modify"
        "https://www.googleapis.com/auth/gmail.messages.readonly"
        "https://www.googleapis.com/auth/gmail.metadata"
        "https://www.googleapis.com/auth/gmail.modify"
        "https://www.googleapis.com/auth/gmail.readonly"
        "https://www.googleapis.com/auth/gmail.send"
        "https://www.googleapis.com/auth/gmail.send.self"
        "https://www.googleapis.com/auth/gmail.settings.basic"
        "https://www.googleapis.com/auth/gmail.settings.filters"
        "https://www.googleapis.com/auth/gmail.settings.filters.readonly"
      ];
    };
    calendar = {
      title = "Calendar";
      upstream = "calendarmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/calendar"
        "https://www.googleapis.com/auth/calendar.acls"
        "https://www.googleapis.com/auth/calendar.calendarlist"
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
        "https://www.googleapis.com/auth/calendar.calendars"
        "https://www.googleapis.com/auth/calendar.calendars.readonly"
        "https://www.googleapis.com/auth/calendar.events"
        "https://www.googleapis.com/auth/calendar.events.freebusy"
        "https://www.googleapis.com/auth/calendar.events.readonly"
        "https://www.googleapis.com/auth/calendar.freebusy"
        "https://www.googleapis.com/auth/calendar.readonly"
        "https://www.googleapis.com/auth/calendar.settings.readonly"
      ];
    };
    drive = {
      title = "Drive";
      upstream = "drivemcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/drive"
        "https://www.googleapis.com/auth/drive.readonly"
        "https://www.googleapis.com/auth/drive.file"
      ];
    };
    docs = {
      title = "Docs";
      upstream = "docsmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/drive.readonly"
        "https://www.googleapis.com/auth/documents.readonly"
        "https://www.googleapis.com/auth/drive"
        "https://www.googleapis.com/auth/documents"
      ];
    };
    sheets = {
      title = "Sheets";
      upstream = "sheetsmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/drive.readonly"
        "https://www.googleapis.com/auth/spreadsheets.readonly"
        "https://www.googleapis.com/auth/drive"
        "https://www.googleapis.com/auth/spreadsheets"
      ];
    };
    slides = {
      title = "Slides";
      upstream = "slidesmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/drive.readonly"
        "https://www.googleapis.com/auth/presentations.readonly"
        "https://www.googleapis.com/auth/drive"
        "https://www.googleapis.com/auth/drive.file"
        "https://www.googleapis.com/auth/presentations"
      ];
    };
    chat = {
      title = "Chat";
      upstream = "chatmcp.googleapis.com";
      scopes = [
        "https://www.googleapis.com/auth/chat.spaces"
        "https://www.googleapis.com/auth/chat.spaces.readonly"
        "https://www.googleapis.com/auth/chat.memberships"
        "https://www.googleapis.com/auth/chat.memberships.readonly"
        "https://www.googleapis.com/auth/chat.messages"
        "https://www.googleapis.com/auth/chat.messages.readonly"
        "https://www.googleapis.com/auth/chat.messages.create"
        "https://www.googleapis.com/auth/chat.users.readstate"
        "https://www.googleapis.com/auth/chat.users.readstate.readonly"
        "https://www.googleapis.com/auth/chat.users.spacesettings"
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
    };
  };
}
