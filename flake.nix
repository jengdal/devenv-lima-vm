{
  description = "Lima-managed NixOS VMs for devenv projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-lima = {
      url = "github:nixos-lima/nixos-lima/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixos-lima, ... }: {
    nixosModules.default = {
      imports = [
        nixos-lima.nixosModules.lima
        ./nixos/module.nix
      ];
    };

    lib.mkVms =
      {
        inputs,
        nixpkgs ? inputs.nixpkgs,
        devenv ? inputs.devenv,
        prefix ? "devenv-vm",
        modules ? [ ],
        systems ? [
          "aarch64-linux"
          "x86_64-linux"
        ],
      }:
      builtins.listToAttrs (
        map (system: {
          name = "${prefix}-${nixpkgs.lib.removeSuffix "-linux" system}";
          value = nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = { inherit inputs; };
            modules = [
              self.nixosModules.default
              { devenv-vm.devenvPackage = devenv.packages.${system}.devenv; }
              ({ config, ... }: {
                # pkgsFrom.<input> = that nixpkgs, same system and config (allowUnfree…)
                # as the VM. Lazy, so each one is only evaluated if used, and only once.
                _module.args.pkgsFrom = builtins.mapAttrs (
                  _: input:
                  import input {
                    inherit system;
                    config = config.nixpkgs.config;
                  }
                ) inputs;
              })
            ]
            ++ modules;
          };
        }) systems
      );

    templates.default = {
      path = ./template;
      description = "vm/ directory for a devenv project using devenv-vm";
    };
  };
}
