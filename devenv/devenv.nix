{
  pkgs,
  lib,
  config,
  ...
}:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.vm;

  root = config.devenv.root;
  project = baseNameOf root;

  # The project name as a valid hostname: [a-z0-9-], no leading/trailing "-", at most 63 chars.
  toHostName =
    name:
    let
      clean = lib.stringAsChars (c: if builtins.match "[a-z0-9-]" c != null then c else "-") (
        lib.toLower name
      );
      trim =
        s:
        let
          m = builtins.match "-*(.*[^-])-*" s;
        in
        if m == null then "" else builtins.head m;
    in
    trim (builtins.substring 0 63 (trim clean));

  # Written by the guest's NixOS module; absent on hosts.
  isVmGuest = builtins.pathExists "/etc/devenv-vm";

  limaSet = lib.concatStringsSep " | " [
    ".cpus = ${toString cfg.cpus}"
    ''.memory = "${cfg.memory}"''
    ''.disk = "${cfg.disk}"''
    ''.mounts = [{"location": "${root}/.git", "mountPoint": "/mnt/host-repo.git", "writable": false}]''
  ];

  # Settings for the in-VM commands; $HOME expands in the guest when sourced.
  envFile = pkgs.writeText "devenv-vm-env" ''
    repo="$HOME/${cfg.checkoutDir}"
    hostname="${cfg.hostName}"
    configdir="${cfg.configDir}"
    configname="${cfg.configName}"
  '';

  # Runs once inside the VM (under `nix shell nixpkgs#git`): clone + first provision.
  bootstrap = pkgs.writeText "devenv-vm-bootstrap.sh" ''
    set -euo pipefail
    . /var/lib/devenv-vm/env
    mkdir -p "$(dirname "$repo")"
    [ -d "$repo/.git" ] || git clone --no-local /mnt/host-repo.git "$repo"
    cd "$repo"
    git cat-file -e "HEAD:$configdir/flake.lock" || {
      echo "$configdir/ (flake.nix, flake.lock) must be committed" >&2; exit 1; }
    nixos-rebuild switch --sudo \
      --option extra-substituters "https://nix-community.cachix.org https://devenv.cachix.org" \
      --option extra-trusted-public-keys "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs= devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" \
      --flake "git+file://$repo?rev=$(git rev-parse HEAD)&dir=$configdir#$configname-$(uname -m)"
    git rev-parse "HEAD:$configdir" | sudo install -D /dev/stdin /var/lib/devenv-vm/provisioned
  '';
in
{
  options.vm = {
    enable = mkEnableOption "a Lima-managed NixOS VM for this devenv";
    name = mkOption {
      type = types.str;
      default = "devenv-${project}";
      description = "Lima instance name.";
    };
    hostName = mkOption {
      type = types.str;
      default = toHostName project;
      description = ''
        Hostname of the guest, applied at runtime. Setting `networking.hostName` in the guest's
        NixOS configuration takes precedence.
      '';
    };
    checkoutDir = mkOption {
      type = types.str;
      default = project;
      description = "Path of the VM's working checkout, relative to the guest home.";
    };
    configDir = mkOption {
      type = types.str;
      default = "vm";
      description = "Directory in the repo containing the guest's NixOS flake.";
    };
    configName = mkOption {
      type = types.str;
      default = "devenv-vm";
      description = "nixosConfigurations prefix (mkVms `prefix`); the guest builds <configName>-<uname -m>.";
    };
    remote = mkOption {
      type = types.str;
      default = "vm";
      description = "Name of the git remote on the host pointing at the VM's checkout.";
    };
    template = mkOption {
      type = types.str;
      default = "github:nixos-lima";
      description = "Lima template used when creating the instance.";
    };
    cpus = mkOption {
      type = types.int;
      default = 4;
    };
    memory = mkOption {
      type = types.str;
      default = "8GiB";
    };
    disk = mkOption {
      type = types.str;
      default = "100GiB";
    };
  };

  config = lib.mkIf (cfg.enable && !isVmGuest) {
    # Lima on every host, plus QEMU on Linux, where it is Lima's default VM type.
    packages = [ pkgs.lima ] ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.qemu ];

    processes.vm.exec = ''
      if ! limactl list -q | grep -qx ${cfg.name}; then
        limactl create --tty=false --name=${cfg.name} \
          --set '${limaSet}' ${cfg.template}
      fi

      # Let the host fetch from the VM's checkout.
      git -C ${root} remote get-url ${cfg.remote} >/dev/null 2>&1 \
        || git -C ${root} remote add ${cfg.remote} lima-${cfg.name}:${cfg.checkoutDir}

      # Once SSH is up: refresh the guest's settings, bootstrap on first boot.
      (
        until limactl shell --workdir / ${cfg.name} -- true 2>/dev/null; do sleep 3; done
        limactl shell --workdir / ${cfg.name} -- \
          sudo install -D -m 644 /dev/stdin /var/lib/devenv-vm/env < ${envFile}
        # Apply a changed hostname; the unit is missing before the first provision.
        limactl shell --workdir / ${cfg.name} -- \
          sudo systemctl restart devenv-vm-hostname.service 2>/dev/null || true
        if ! limactl shell --workdir / ${cfg.name} -- test -e /var/lib/devenv-vm/provisioned; then
          echo "[vm] bootstrapping: clone + first provision"
          limactl shell --workdir / ${cfg.name} -- \
            nix --extra-experimental-features "nix-command flakes" \
              shell nixpkgs#git -c bash -s < ${bootstrap}
          echo "[vm] bootstrap done"
        fi
      ) &

      exec limactl start --foreground ${cfg.name}
    '';
  };
}
