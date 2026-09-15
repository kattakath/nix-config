# fal.ai, as two binaries that answer two different questions.
#
#   fal       the VENDOR's own CLI (PyPI `fal`) — `fal run`, `fal deploy`.
#             fal.ai describes it as "a serverless Python runtime that lets you
#             run and scale code in the cloud". It deploys YOUR functions; it is
#             not a way to call a hosted model.
#   fal-gen   a thin wrapper over PyPI `fal-client`, the vendor's inference
#             library. This is the half that actually generates media, and the
#             vendor ships NO CLI for it — hence ours.
#
# Both are packaged the way this tree already packages Python tooling that is
# not in nixpkgs (modules/features/media-cli/packages/fidelity-enhance.nix, and
# jobspy before it): an EPHEMERAL `uv run --with` environment, uv and Python
# pinned from Nix, the distribution fetched once and cached. Nothing is
# pip-installed globally and there is no hand-made venv in $HOME to depend on.
#
# WHY NOT A NIX DERIVATION. `fal` is a serverless runtime with a deep dependency
# tree, none of it in nixpkgs (searched: 15 hits for "fal", not one is fal.ai).
# buildPythonApplication would mean packaging that tree by hand and re-doing it
# on every bump — the wrong trade for a vendor CLI that already resolves its own
# dependencies correctly.
#
# WHY NOT AN MCP SERVER. There is no vendor-official fal.ai MCP server. The
# community ones found in the registry (avieirox/fal-mcp-server,
# MalcolmXavier7/fal, mertagralii/fal-butler) are all single-source, confidence
# 0.40, with no update date — a long-running process holding an API key is the
# widest blast radius on offer, and these do not earn it.
#
# CREDENTIAL. Both read `FAL_KEY` from the environment, which on this fleet
# comes from the login Keychain via the `secret` loader — the value never
# reaches argv, a dotfile, or the store. Neither binary prints it.
#
# THIS IS CLOUD INFERENCE, unlike the rest of the media stack. photo-describe
# and the queue run against the LOCAL ollama daemon; anything sent through
# fal-gen leaves the machine and is billed. That is a deliberate difference in
# posture, not a drop-in substitute.
{
  lib,
  writeShellApplication,
  writeText,
  symlinkJoin,
  uv,
  coreutils,
}:
let
  # Pinned deliberately. `uv run --with fal` would silently float to whatever
  # the index serves that day, which is the drift this repo packages away.
  cliSpec = "fal==1.80.0";
  clientSpec = "fal-client==1.0.1";

  # Python 3.12 rather than latest, matching fidelity-enhance: wheel coverage is
  # reliable there and both distributions only require >=3.8.
  python = "3.12";

  genScript = writeText "fal-gen.py" ''
    """Generate media from a hosted fal.ai model and save the result.

    The vendor ships a client library but no inference CLI, so this is the
    smallest thing that turns `fal-client` into one. It deliberately does NOT
    wrap every endpoint's options: --arg takes arbitrary key=value pairs, so a
    new model needs no change here.
    """
    import argparse
    import json
    import os
    import sys
    import urllib.request

    import fal_client


    def main() -> int:
        ap = argparse.ArgumentParser(
            prog="fal-gen",
            description="Run a hosted fal.ai model and save what it returns.",
        )
        ap.add_argument("endpoint", help="model id, e.g. fal-ai/flux/schnell")
        ap.add_argument("prompt", nargs="?", default=None, help="text prompt")
        ap.add_argument(
            "--arg",
            action="append",
            default=[],
            metavar="KEY=VALUE",
            help="extra model argument; repeatable. JSON values are parsed as JSON.",
        )
        ap.add_argument("-o", "--out", help="write the first returned file here")
        ap.add_argument(
            "--json", action="store_true", help="print the raw result and exit"
        )
        args = ap.parse_args()

        if not os.environ.get("FAL_KEY"):
            # Name it, never read it back out for display.
            print(
                "fal-gen: FAL_KEY is not set. It lives in the login Keychain — "
                "`secret set fal:fal.ai:key` once, then start a new shell.",
                file=sys.stderr,
            )
            return 2

        arguments: dict[str, object] = {}
        if args.prompt is not None:
            arguments["prompt"] = args.prompt
        for pair in args.arg:
            if "=" not in pair:
                print(f"fal-gen: --arg expects KEY=VALUE, got {pair!r}", file=sys.stderr)
                return 2
            key, _, raw = pair.partition("=")
            try:
                arguments[key] = json.loads(raw)
            except json.JSONDecodeError:
                arguments[key] = raw

        # subscribe() blocks until the run finishes and surfaces queue updates,
        # which is what a CLI wants; run() would return before the result exists.
        result = fal_client.subscribe(args.endpoint, arguments=arguments)

        if args.json or not args.out:
            print(json.dumps(result, indent=2))
            if not args.out:
                return 0

        # Endpoints disagree on the shape: some return {"images": [...]}, some
        # {"video": {...}}, some {"audio": {...}}. Take the first thing that
        # carries a url rather than special-casing each family.
        def first_url(node: object) -> str | None:
            if isinstance(node, dict):
                if isinstance(node.get("url"), str):
                    return node["url"]
                for value in node.values():
                    found = first_url(value)
                    if found:
                        return found
            elif isinstance(node, list):
                for item in node:
                    found = first_url(item)
                    if found:
                        return found
            return None

        url = first_url(result)
        if not url:
            print("fal-gen: no file url in the result", file=sys.stderr)
            return 1

        urllib.request.urlretrieve(url, args.out)  # noqa: S310 - https from fal
        print(args.out)
        return 0


    if __name__ == "__main__":
        raise SystemExit(main())
  '';

  # --no-project is load-bearing, exactly as fidelity-enhance records: `uv run`
  # otherwise adopts whatever project sits in the CURRENT directory, so running
  # this from a checkout with its own pyproject.toml would resolve that project's
  # dependencies instead of the pinned spec above.
  vendorCli = writeShellApplication {
    name = "fal";
    runtimeInputs = [
      uv
      coreutils
    ];
    text = ''
      exec uv run --quiet --no-project --python ${python} --with "${cliSpec}" fal "$@"
    '';
  };

  gen = writeShellApplication {
    name = "fal-gen";
    runtimeInputs = [
      uv
      coreutils
    ];
    text = ''
      exec uv run --quiet --no-project --python ${python} --with "${clientSpec}" \
        python ${genScript} "$@"
    '';
  };
in
symlinkJoin {
  name = "fal";
  paths = [
    vendorCli
    gen
  ];
  meta = {
    description = "fal.ai: the vendor's deploy CLI plus an inference wrapper";
    homepage = "https://fal.ai";
    license = lib.licenses.mit; # both distributions are MIT-licensed by fal.ai
    platforms = lib.platforms.all;
  };
}
