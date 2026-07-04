{
  pkgs,
  diskoInstall,
  handleName,
}:
pkgs.writeShellApplication {
  name = "nixarm-bootstrap";
  text = ''
    sudo ${diskoInstall}/bin/disko-install --flake github:${handleName}/nix-config#nixarm --disk vda /dev/vda
  '';
}
