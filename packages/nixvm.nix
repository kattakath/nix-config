# Bootstrap installer for the nixvm sandbox VM — disko-install straight from
# this flake, run from the nixvm-installer live ISO.
{
  pkgs,
  diskoInstall,
  handleName,
}:
pkgs.writeShellApplication {
  name = "nixvm";
  text = ''
    sudo ${diskoInstall}/bin/disko-install --flake github:${handleName}/nix-config#nixvm --disk vda /dev/vda
  '';
}
