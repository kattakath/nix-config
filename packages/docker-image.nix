# Production-ready dockerTools pipeline: emit a minimal, stateless container
# with ZERO base-OS clutter. There is no Debian/Alpine layer — only the closure
# of the app and what it transitively needs. Built reproducibly by Nix.
#
#   nix build .#packages.x86_64-linux.dockerImage
#   docker load < result
#   docker run --rm nix-config-app:latest
{ pkgs, ... }:

let
  # Stand-in application. Swap `dummyApp` for a real `pkgs.callPackage` of your
  # service; the image pipeline below does not change.
  dummyApp = pkgs.writeShellApplication {
    name = "app";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      echo "nix-config minimal container is running."
      echo "arch: $(uname -m)"
      exec sleep infinity
    '';
  };
in
pkgs.dockerTools.buildImage {
  name = "nix-config-app";
  tag = "latest";

  # No `fromImage` → no base OS. The image is exactly the copied closures.
  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [
      dummyApp
      pkgs.cacert
    ];
    pathsToLink = [
      "/bin"
      "/etc"
    ];
  };

  config = {
    Cmd = [ "${dummyApp}/bin/app" ];
    Env = [
      "PATH=/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    WorkingDir = "/";
  };
}
