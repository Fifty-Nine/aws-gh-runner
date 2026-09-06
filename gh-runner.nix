# NixOS configuration applied by the Determinate Systems AMI via
# `fh apply nixos Fifty-Nine/aws-gh-runner/0.1#nixosConfigurations.gh-runner`.
#
# Secrets are provisioned at boot by the EC2 instance's user_data:
#   /var/run/gh_pat  — fine-grained GitHub PAT used to mint a registration token
{ config, lib, pkgs, ... }: {
  ec2.hvm = true;

  # The root volume is expanded to the Terraform-managed size; grow the
  # filesystem to match on first boot.
  boot.growPartition = true;

  time.timeZone = "UTC";

  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  nix.settings.trusted-users = [ "@wheel" "root" "gh-runner" ];

  users.users.gh-runner = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  services.github-runners.gh-runner = {
    enable = true;
    name = "arm-gh-runner";
    url = "https://github.com/Fifty-Nine/aws-gh-runner";
    tokenFile = "/var/run/gh_pat";
    user = "gh-runner";
    # Matches labels used to target this runner from workflows.
    extraLabels = [ "arm64" "nixos" ];
    extraPackages = with pkgs; [
      bash
      coreutils
      curl
      git
      gh
      gnutar
      gzip
      jq
      nix
      nodejs
      openssh
      unzip
      xz
    ];
  };

  system.stateVersion = "25.05";
}