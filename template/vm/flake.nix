{
  description = "NixOS Lima guest for this devenv project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    devenv-lima-vm = {
      url = "github:jengdal/devenv-lima-vm";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devenv.url = "github:cachix/devenv"; # pinned with vm-pin-devenv
  };

  outputs =
    inputs@{ devenv-lima-vm, ... }:
    {
      nixosConfigurations = devenv-lima-vm.lib.mkVms {
        inherit inputs;
        # prefix = "devenv-vm";            # must match vm.configName on the host
        modules = [ ./configuration.nix ];
      };
    };

}
