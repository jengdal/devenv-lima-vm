# Project-specific additions to the VM. Library defaults use mkDefault,
# so plain assignments here override them.
{
  pkgs,
  pkgsFrom,
  inputs,
  ...
}:
{
  # I recommend starting the VM once before making changes here.
  # After you've made changes here, commit them. Pull them into the vm and run `vm-provision` from
  # within the VM.
  #
  # Use a `devenv.local.nix` to personalize the VM, eg. installing coding agents etc.
  # One point with the VM is to run agents inside it, so do not install the agents on your host,
  # or using the regular `devenv.nix`. Use your own, uncommitted `devenv.local.nix` inside the VM.

  # Uncomment this if you want to install "unfree" software:
  # nixpkgs.config = {
  #   allowUnfree = true;
  # };
  #
  # environment.systemPackages = [
  #   pkgs.neovim
  #   pkgsFrom.nixpkgs-unstable.example
  # ];
  # boot.kernelPackages = pkgs.linuxPackages;   # LTS instead of latest
  #
  # Editors that connect over SSH (VS Code, Zed, IntelliJ, …) upload a prebuilt server to the VM.
  # If it does not start, uncomment this so NixOS can run such binaries:
  # programs.nix-ld.enable = true;
}
