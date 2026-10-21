# korotovsky/slack-mcp-server, built from source at a pinned tag.
#
# WHY THIS SERVER EXISTS NEXT TO THE HOSTED ONE. Slack's hosted MCP (mcp.slack.com,
# the official `slack` plugin and any second-workspace twin) appends `*Sent using* <@…|Claude>` to every
# message it posts, with no opt-out (slackapi/slack-skills-plugin#25). #824 therefore
# denies its post tools and routes through drafts the operator sends by hand. This
# server posts with the operator's OWN user token (xoxp) through `chat.postMessage`
# (pkg/handler/conversations.go:266) and adds nothing to the text, so a post reads as
# the operator's own message with no draft step. Chosen 2026-10-16 over a machine-wide
# `SLACK_ALLOW_SENT_USING_CLAUDE=1`, which would keep the footer on every post.
#
# WHY BUILT, not the release binary or npx: not in nixpkgs (searched 2026-10-16), and a
# source build is reproducible and pinned by hash, where the release asset is an opaque
# Darwin-only download and `npx` fetches at first run, outside the closure.
#
# MIT, ~1.9k stars; v1.3.0 is the latest tag (2026-05-14).
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "slack-mcp-server";
  version = "1.3.0";

  src = fetchFromGitHub {
    owner = "korotovsky";
    repo = "slack-mcp-server";
    rev = "v${version}";
    hash = "sha256-I4f6yKV0BXtaxnqi/XNID+Pwl2mWjSqxIHhb07U7sc4=";
  };

  vendorHash = "sha256-+uQRODO9oL8mGKBmdghTxE6R9Fz+3GJFVTi17306gT8=";

  subPackages = [ "cmd/slack-mcp-server" ];

  # Mirrors the upstream Makefile's LD_FLAGS (line 13); git describe is unavailable in
  # the sandbox, so the tag stands in for it.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/korotovsky/slack-mcp-server/pkg/version.Version=v${version}"
  ];

  # The suite includes live-API integration tests that need a token and network.
  doCheck = false;

  meta = {
    description = "MCP server for Slack workspaces (stdio/SSE/HTTP), user-token posting";
    homepage = "https://github.com/korotovsky/slack-mcp-server";
    license = lib.licenses.mit;
    mainProgram = "slack-mcp-server";
  };
}
