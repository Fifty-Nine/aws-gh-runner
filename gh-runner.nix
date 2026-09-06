# NixOS module applied by the Determinate Systems AMI via
# `fh apply nixos Fifty-Nine/aws-gh-runner/0.1#nixosConfigurations.gh-runner`.
#
# The baseline closure carries only shared plumbing; deployers layer a
# generated flake on top that sets `gh-runner.repos` to the user-provided
# list, which materializes one GitHub Actions runner per repo.
#
# Secrets come from AWS Secrets Manager at boot, authenticated via the
# instance's IAM profile (no secrets ship in the flake).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    listToAttrs
    map
    replaceStrings
    ;

  # `org/name` -> `org-name`, the systemd-safe instance name.
  runnerName = replaceStrings [ "/" ] [ "-" ];
in
{
  options.gh-runner = {
    repos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        GitHub repositories (`org/name`) to serve. Each gets a
        `services.github-runners.` instance. The Secrets Manager PAT must
        be scoped to every listed repository.
      '';
    };

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

    nix.settings.trusted-users = [
      "@wheel"
      "root"
      "gh-runner"
    ];

    users.users.gh-runner = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };

    systemd.services = {
      gh-runner-pat = {
        description = "Fetch GitHub runner PAT from AWS Secrets Manager";
        wantedBy = [ "multi-user.target" ];
        before = map (repo: "github-runner-${runnerName repo}.service") config.gh-runner.repos;
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
    }
    // listToAttrs (
      map (repo: {
        name = "github-runner-${runnerName repo}";
        value = {
          after = [ "gh-runner-pat.service" ];
          requires = [ "gh-runner-pat.service" ];
        };
      }) config.gh-runner.repos
    );

    services.github-runners = listToAttrs (
      map (repo: {
        name = runnerName repo;
        value = {
          enable = true;
          url = "https://github.com/${repo}";
          tokenFile = "/run/gh-runner/gh_pat";
          user = "gh-runner";
          # Matches labels used to target this runner from workflows.
          extraLabels = [
            "arm64"
            "nixos"
          ];
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
      }) config.gh-runner.repos
    );

    system.stateVersion = "26.11";
  };
}
