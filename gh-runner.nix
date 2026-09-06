# NixOS configuration applied by the Determinate Systems AMI via
# `fh apply nixos Fifty-Nine/aws-gh-runner/0.1#nixosConfigurations.gh-runner`.
#
# Secrets come from AWS Secrets Manager at boot, authenticated via the
# instance's IAM profile (no secrets ship in the flake).
{ config, lib, pkgs, ... }: {
  options.gh-runner = {
    patSecretArn = lib.mkOption {
      type = lib.types.str;
      default = "github-runner/pat";
      description = "Secrets Manager secret holding the fine-grained GitHub PAT used to mint registration tokens";
    };
  };

  config = {
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

    systemd.services.gh-runner-pat = {
      description = "Fetch GitHub runner PAT from AWS Secrets Manager";
      wantedBy = [ "multi-user.target" ];
      before = [ "github-runner-gh-runner.service" ];
      path = [ pkgs.awscli2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "gh-runner";
      };
      script = ''
        aws secretsmanager get-secret-value \
          --secret-id ${lib.escapeShellArg config.gh-runner.patSecretArn} \
          --query SecretString --output text > /run/gh-runner/gh_pat
        chmod 0600 /run/gh-runner/gh_pat
      '';
    };

    services.github-runners.gh-runner = {
      enable = true;
      name = "arm-gh-runner";
      url = "https://github.com/Fifty-Nine/aws-gh-runner";
      tokenFile = "/run/gh-runner/gh_pat";
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

    systemd.services."github-runner-gh-runner" = {
      after = [ "gh-runner-pat.service" ];
      requires = [ "gh-runner-pat.service" ];
    };

    system.stateVersion = "25.05";
  };
}