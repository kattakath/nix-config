{
  pkgs,
  diskoInstall,
  handleName,
}:
pkgs.writeShellApplication {
  name = "nixamd";
  text = ''
    sudo ${diskoInstall}/bin/disko-install --flake github:${handleName}/nix-config#nixamd --disk vda /dev/vda
  '';
}
