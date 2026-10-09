{
  config,
  modulesPath,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.devenv-vm;

  # Every command reads the settings the host wrote at boot.
  loadEnv = ''
    # shellcheck source=/dev/null
    . /var/lib/devenv-vm/env
    cd "$repo"
  '';

  # shellcheck can't see the assignments in the sourced file, hence SC2154
  # (referenced but not assigned).
  mkVmCommand =
    args:
    pkgs.writeShellApplication (
      args
      // {
        excludeShellChecks = [ "SC2154" ];
        text = loadEnv + args.text;
      }
    );

  vm-provision = mkVmCommand {
    name = "vm-provision";
    runtimeInputs = [ pkgs.git ];
    text = ''
      marker=/var/lib/devenv-vm/provisioned
      key=$(git rev-parse "HEAD:$configdir")
      if [ "''${1:-}" != --force ] && [ "$(cat "$marker" 2>/dev/null || true)" = "$key" ]; then
        echo "Up to date ($configdir/ tree $key). Use --force to rebuild anyway."
        exit 0
      fi
      git diff --quiet HEAD -- "$configdir" \
        || echo "Note: uncommitted changes in $configdir/ are not applied." >&2
      nixos-rebuild switch --sudo \
        --flake "git+file://$repo?rev=$(git rev-parse HEAD)&dir=$configdir#$configname-$(uname -m)"
      echo "$key" | sudo install -D /dev/stdin "$marker"
      if [ "$(readlink /run/booted-system/kernel)" != "$(readlink /run/current-system/kernel)" ]; then
        echo "Kernel changed: restart the 'vm' process on the host to boot it." >&2
      fi
    '';
  };

  vm-sync = mkVmCommand {
    name = "vm-sync";
    runtimeInputs = [
      pkgs.git
      vm-provision
    ];
    text = ''
      git pull --ff-only
      vm-provision
    '';
  };

  # Updates every input except `devenv` (pinned with vm-pin-devenv),
  # or only the inputs given as arguments.
  vm-update-system = mkVmCommand {
    name = "vm-update-system";
    runtimeInputs = [
      pkgs.git
      pkgs.jq
      vm-provision
    ];
    text = ''
      if [ "$#" -gt 0 ]; then
        inputs=("$@")
      else
        mapfile -t inputs < <(jq -r '.nodes.root.inputs | keys[] | select(. != "devenv")' \
          "$configdir/flake.lock")
      fi
      nix flake update --flake "./$configdir" "''${inputs[@]}"
      if git diff --quiet -- "$configdir/flake.lock"; then
        echo "$configdir/flake.lock unchanged"
      else
        git commit --only "$configdir/flake.lock" -m "Update VM flake inputs: ''${inputs[*]}"
      fi
      vm-provision
    '';
  };

  vm-pin-devenv = mkVmCommand {
    name = "vm-pin-devenv";
    runtimeInputs = [
      pkgs.git
      pkgs.jq
      vm-provision
    ];
    text = ''
      rev=$(jq -r '.nodes.devenv.locked.rev' devenv.lock)
      nix flake lock "./$configdir" --override-input devenv "github:cachix/devenv/$rev"
      if git diff --quiet -- "$configdir/flake.lock"; then
        echo "VM devenv already at $rev"
      else
        git commit --only "$configdir/flake.lock" -m "Pin VM devenv to $rev"
      fi
      vm-provision
    '';
  };
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  options.devenv-vm.devenvPackage = lib.mkOption {
    type = lib.types.package;
    description = "devenv CLI installed in the guest (set by lib.mkVms).";
  };

  config = {
    # No static hostname by default: the host sends one (vm.hostName) and it is applied at
    # runtime. Set networking.hostName to pin a static one instead.
    networking.hostName = lib.mkDefault "";
    systemd.services.devenv-vm-hostname = lib.mkIf (config.networking.hostName == "") {
      description = "Set the hostname from the host's devenv project";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/var/lib/devenv-vm/env";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        . /var/lib/devenv-vm/env
        [ -z "''${hostname:-}" ] || ${pkgs.hostname}/bin/hostname "$hostname"
      '';
    };

    # Marks this machine as the guest, so the host module stays inactive here.
    environment.etc."devenv-vm".text = "";

    # Lima integration
    services.lima.enable = true;
    users.mutableUsers = true;
    services.openssh.enable = true;
    security.sudo.wheelNeedsPassword = lib.mkDefault false;

    # 9p shares on Linux hosts (QEMU)
    boot.kernelModules = [
      "9p"
      "9pnet_virtio"
    ];

    # Match the nixos-lima image
    boot.loader.grub = {
      device = "nodev";
      efiSupport = true;
      efiInstallAsRemovable = true;
      configurationLimit = lib.mkDefault 10;
    };
    fileSystems."/boot" = {
      device = lib.mkForce "/dev/vda1";
      fsType = "vfat";
    };
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      autoResize = true;
      fsType = "ext4";
      options = [
        "noatime"
        "nodiratime"
        "discard"
      ];
    };
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

    # Nix
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        "@wheel"
      ];
      auto-optimise-store = lib.mkDefault true;
      extra-substituters = [
        "https://nix-community.cachix.org"
        "https://devenv.cachix.org"
      ];
      extra-trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      ];
    };

    nix.gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
      options = lib.mkDefault "--delete-older-than 14d";
    };

    environment.systemPackages = [
      cfg.devenvPackage
      pkgs.git
      pkgs.home-manager
      vm-provision
      vm-sync
      vm-update-system
      vm-pin-devenv
    ];

    programs.direnv = {
      enable = lib.mkDefault true;
      nix-direnv.enable = lib.mkDefault true;
    };

    system.stateVersion = lib.mkDefault "26.05";
  };
}
