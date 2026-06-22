# Cloudflare Tunnel daemon — per-host tunnel config lives in hosts/*.nix
{ pkgs, ... }:
{
  services.cloudflared = {
    enable = true;
    package = pkgs.cloudflared;
  };
}
