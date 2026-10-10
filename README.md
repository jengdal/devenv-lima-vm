# devenv-lima-vm

**This is an experiment, you should probably not use it**

Run a [devenv](https://devenv.sh) project inside its own NixOS VM, managed by
[Lima](https://lima-vm.io). Handy when you want coding agents (or anything else you don't fully
trust) to work in a sandbox instead of on your machine.

## Motivation

Coding agents work best when they can run freely, and that is not something you want on your own
machine. In the VM, an agent **can**:

- **Run the whole project.** The VM has your full devenv setup: the same `devenv.nix` as on the
  host, with every service and dependency. The agent can start the project, run the tests and
  experiment.
- **Do what it likes to the system.** It has root in the VM. If it breaks something, delete the VM
  and `devenv up` builds a fresh one from what is committed.

You can work in the VM too: edit and run things there with a terminal editor, or connect over SSH
from VS Code, Zed, IntelliJ and the like.

The agent **cannot**:

- **Read your files.** The only thing shared from the host is the repo's `.git` directory,
  read-only. That does include the history and `.git/config`, so keep tokens out of remote URLs.
- **Use your SSH keys.** Your ssh-agent is not forwarded, so it cannot log in to your servers. Don't
  forward it yourself (eg. using `ssh -A`, or `ForwardAgent yes` in your SSH config).
- **(Force) push to your repos.** The VM has no credentials for your remotes, and the host's copy is
  read-only to it. Work only leaves the VM when you `git fetch vm` on the host. Review it before you
  merge it.
- **Open ports on your machine.** Lima's automatic port forwarding is switched off. You reach
  services in the VM on the VM's own IP address.

Not solved yet: network access. The VM can reach the internet and your local network without
restriction. It should be possible to force all traffic through a proxy with allow/deny rules, but I
haven't looked into that yet.

## How it works

- `devenv up` on the host starts a `vm` process that creates, sets up and runs the VM.
- The VM works in **its own clone** of your repo. The only thing shared from the host is the repo's
  `.git` directory, read-only. Work moves between the two with git.
- The VM's system is a NixOS configuration that lives in your repo, in `vm/`.

Below, `<project>` is the name of your repo's directory.

## Requirements

- Nix (with flakes) and devenv on the host. Lima comes with the devenv shell.
- **Linux:** access to `/dev/kvm`. QEMU also comes with the devenv shell.
- This line in `~/.ssh/config`, used both for `ssh` and for fetching from the VM with git:

  ```
  Include ~/.devenv-lima-vm/*/ssh.config
  ```

The VMs live in their own Lima home, `~/.devenv-lima-vm`, so settings in your regular `~/.lima` do
not apply to them. The devenv shell sets `LIMA_HOME` to it, so `limactl` there sees these VMs.

Lima picks the VM type. To change it, set it in `~/.devenv-lima-vm/_config/default.yaml`:

```yaml
vmType: qemu
```

Don't add `mounts` to that file: Lima applies them to every VM, and these should only see the repo's
`.git`.

## Setup

1. Add the input to `devenv.yaml`:

   ```yaml
   require_version: true
   inputs:
     devenv-lima-vm:
       url: github:jengdal/devenv-lima-vm
       flake: false
   imports:
     - devenv-lima-vm/devenv
   ```

2. Enable it in `devenv.nix`:

   ```nix
   { pkgs, ... }: {
     vm.enable = true;
   }
   ```

3. Create the VM's NixOS configuration and commit everything. The VM is built from what is
   committed, so nothing works until this is in git.

   ```bash
   nix flake init -t github:jengdal/devenv-lima-vm # creates vm/flake.nix, vm/configuration.nix
   nix flake lock ./vm                             # creates vm/flake.lock
   devenv update                                   # creates devenv.lock
   git add vm devenv.yaml devenv.nix devenv.lock
   git commit -m "Add devenv-lima-vm"
   ```

4. Start it:

   ```bash
   devenv up
   ```

   The first start downloads the image, clones the repo into the VM and builds NixOS. Wait for
   `[vm] bootstrap done`. `devenv up` keeps running in the foreground; stopping it stops the VM.

## Options

All optional; defaults shown.

```nix
vm.name        = "devenv-<project>";   # Lima instance name
vm.hostName    = "<project>";          # hostname inside the VM
vm.checkoutDir = "<project>";          # the VM's clone, relative to its home directory
vm.configDir   = "vm";                 # where the NixOS configuration lives in the repo
vm.configName  = "devenv-vm";          # must match `prefix` in vm/flake.nix
vm.remote      = "vm";                 # git remote on the host that points at the VM
vm.template    = "github:nixos-lima";  # Lima template for new VMs
vm.networks    = [ ];                  # Lima networks; see "Reaching services in the VM"
vm.cpus        = 4;
vm.memory      = "8GiB";
vm.disk        = "100GiB";
```

`vm.hostName` is ignored if you set `networking.hostName` in `vm/configuration.nix`.

`vm.template`, `vm.networks`, `vm.cpus`, `vm.memory` and `vm.disk` are applied when the VM is
created. Changing them later has no effect on an existing VM.

## Using the VM

```bash
ssh lima-devenv-<project>
cd ~/<project>
devenv shell    # not needed if the repo has an .envrc and you have run `direnv allow`
```

To use an editor on the host, open the VM as an SSH remote: host `lima-devenv-<project>`, folder
`~/<project>`. That should work in anything with remote-over-SSH support, such as VS Code, Zed and
IntelliJ. If the editor's remote server does not start, enable `programs.nix-ld` in
`vm/configuration.nix`; the template has the line ready to uncomment.

Host and VM each have their own working copy. Move work between them with git:

| Direction | How                                                   |
| --------- | ----------------------------------------------------- |
| Host → VM | Commit on the host, then run `vm-sync` in the VM      |
| VM → host | Commit in the VM, then run `git fetch vm` on the host |

To commit in the VM it needs a git identity; see the next section.

## Reaching services in the VM

Ports the VM listens on are not forwarded to the host. To reach a service, connect to the VM's IP
address, which takes two steps:

1. Give the VM an address the host can reach, with `vm.networks` in `devenv.nix`:

   | Host and VM type | `vm.networks`              | Needs                                                                  |
   | ---------------- | -------------------------- | ---------------------------------------------------------------------- |
   | macOS, vz        | `[ { vzNAT = true; } ]`    | Nothing                                                                |
   | macOS, QEMU      | `[ { lima = "shared"; } ]` | [socket_vmnet](https://lima-vm.io/docs/config/network/vmnet/), as root |
   | Linux, QEMU      | Not available              | Use an SSH tunnel: `ssh -L 3000:localhost:3000 lima-devenv-<project>`  |

   The `vm` process prints the VM's addresses when it starts (`[vm] addresses: …`).

2. Open the port in the VM's firewall, in `vm/configuration.nix`:

   ```nix
   networking.firewall.allowedTCPPorts = [ 3000 ];
   ```

Lima itself still listens on a few random `127.0.0.1` ports on the host, and this cannot be turned
off: one forwards to the VM's SSH server (`ssh` and `git fetch vm` use it, and it only accepts
Lima's own key), the others are Lima's DNS resolver for the VM.

## Personal setup in the VM

Things that are yours rather than the project's, such as a git identity and coding agents, go in a
`devenv.local.nix` in the VM's clone or in Home Manager (installed in the VM, but not yet tested).

devenv loads `devenv.local.nix` on top of `devenv.nix`. Keep it out of git (devenv's default
`.gitignore` already lists it) and create it only in the VM, not on the host.

`~/<project>/devenv.local.nix` in the VM:

```nix
{ pkgs, ... }:

let
  gitName = "Your Name";
  gitEmail = "you@example.com";
in
{
  packages = [
    pkgs.git
    pkgs.claude-code
    pkgs.tree-sitter
    pkgs.neovim
  ];

  # Git identity, scoped to this dev shell (doesn't touch ~/.gitconfig)
  env = {
    GIT_AUTHOR_NAME = gitName;
    GIT_AUTHOR_EMAIL = gitEmail;
    GIT_COMMITTER_NAME = gitName;
    GIT_COMMITTER_EMAIL = gitEmail;
  };

  # Also write it to the repo's local .git/config so tools that
  # read config directly (rather than env vars) pick it up too
  enterShell = ''
    if git rev-parse --git-dir >/dev/null 2>&1; then
      git config user.name "${gitName}"
      git config user.email "${gitEmail}"
    fi
  '';
}
```

`claude-code` is an unfree package. Allow it with a `devenv.local.yaml` next to the file:

```yaml
allowUnfree: true
```

## Changing the VM's system

Edit `vm/configuration.nix`, commit, and run `vm-sync` in the VM (or just `vm-provision` if you
committed inside the VM). Uncommitted changes are not applied.

Use this for things every user of the project should get. Your own tools belong in
[`devenv.local.nix`](#personal-setup-in-the-vm).

## Commands in the VM

| Command                      | What it does                                                   |
| ---------------------------- | -------------------------------------------------------------- |
| `vm-sync`                    | Pull from the host repo, then `vm-provision`                   |
| `vm-provision [--force]`     | Rebuild NixOS from the committed `vm/`, if it changed          |
| `vm-update-system [inputs…]` | Update `vm/flake.lock` (all inputs except `devenv`), provision |
| `vm-pin-devenv`              | Set the VM's devenv CLI to the version in `devenv.lock`        |

`vm-update-system` and `vm-pin-devenv` commit the changed `vm/flake.lock` and then provision.

## Updating devenv-lima-vm

Your project pins this repo twice: in `devenv.lock` (host side) and in `vm/flake.lock` (VM side).
Update **both** — they are developed together, and updating only one can leave features half
working.

```bash
devenv update devenv-lima-vm                 # host side -> devenv.lock
nix flake update --flake ./vm devenv-lima-vm # VM side   -> vm/flake.lock
git commit devenv.lock vm/flake.lock -m "Update devenv-lima-vm"
```

Then restart the `vm` process on the host and run `vm-sync` in the VM.

Leave out the input name to update everything instead: `devenv update` and
`nix flake update --flake ./vm`.

## Removing the VM

**First copy everything you want to keep to the host.** Deleting the VM also deletes commits you
have not fetched, uncommitted changes, and files that only exist there, such as `devenv.local.nix`.

Stop `devenv up`. From the project's devenv shell:

```bash
limactl delete devenv-<project>
git remote remove vm
```

## This repository

```
flake.nix             nixosModules.default, lib.mkVms, templates.default
devenv/devenv.nix     host module (imported via devenv.yaml)
nixos/module.nix      guest NixOS module, on top of nixos-lima
template/vm/          scaffold for a project's vm/ directory
```
