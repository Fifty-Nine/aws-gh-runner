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

  user = "gh-runner";

  # `org/name` -> `org-name`, the systemd-safe instance name.
  runnerName = replaceStrings [ "/" ] [ "-" ];

  # The determinate-nixd binary ships in the host system environment, not in
  # any single package; shim it onto the runner's PATH so CI jobs can run
  # `determinate-nixd login github-action` (required for FlakeHub Cache push
  # access).
  determinate-nixd-shim = pkgs.runCommand "determinate-nixd-shim" { } ''
    mkdir -p $out/bin
    ln -s /run/current-system/sw/bin/determinate-nixd $out/bin/determinate-nixd
  '';
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

    swapSizeMiB = lib.mkOption {
      type = with lib.types; nullOr ints.positive;
      default = null;
      description = ''
        Size in MiB of a swapfile created on the root volume (e.g. `4096`
        for 4 GiB); null disables swap. Set for memory-constrained
        instances (e.g. t4g).
      '';
    };

    patSecretArn = lib.mkOption {
      type = lib.types.str;
      default = "github-runner/pat";
      description = "Secrets Manager secret holding the fine-grained GitHub PAT used to mint registration tokens";
    };

    flakehubTokenSecretArn = lib.mkOption {
      type = lib.types.str;
      default = "github-runner/flakehub-token";
      description = "Secrets Manager secret holding the FlakeHub device token used to restore host cache login between runner jobs";
    };
  };

  config = {
    ec2.hvm = true;

    # The root volume is expanded to the Terraform-managed size; grow the
    # filesystem to match on first boot.
    boot.growPartition = true;

    swapDevices = lib.optionals (config.gh-runner.swapSizeMiB != null) [
      { device = "/swapfile"; size = config.gh-runner.swapSizeMiB; }
    ];

    time.timeZone = "UTC";

    services.openssh.enable = true;
    networking.firewall.allowedTCPPorts = [ 22 ];

    # magic-nix-cache refuses to run when the daemon does not trust the job
    # user; trust is also required for it to register its substituter.
    nix.settings.trusted-users = [
      "@wheel"
      "root"
      user
    ];

    users.users.${user} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/determinate 0755 ${user} ${user} -"
    ];

    systemd.services = {
      gh-runner-secrets = {
        description = "Fetch GitHub runner secrets from AWS Secrets Manager";
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
          chown ${user}:${user} /run/gh-runner/gh_pat

          aws secretsmanager get-secret-value \
            --secret-id ${lib.escapeShellArg config.gh-runner.flakehubTokenSecretArn} \
            --query SecretString --output text > /run/gh-runner/fh_token
          chmod 0600 /run/gh-runner/fh_token
          chown ${user}:${user} /run/gh-runner/fh_token
        '';
      };
    }
    // listToAttrs (
      map (repo: {
        name = "github-runner-${runnerName repo}";
        value = {
          after = [ "gh-runner-secrets.service" ];
          requires = [ "gh-runner-secrets.service" ];
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
          user = user;
          ephemeral = true;
          replace = true;
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
            determinate-nixd-shim
          ];

          # Ephemeral runners exit after each job; on the restart, restore the
          # host's device FlakeHub login, which the job's CI (OIDC) login
          # replaced for FlakeHub Cache push access.
          serviceOverrides.ExecStartPost = [
            "-${pkgs.writeShellScript "restore-flakehub-login" ''
              exec ${determinate-nixd-shim}/bin/determinate-nixd login token \
                --token-file /run/gh-runner/fh_token
            ''}"
          ];
        };
      }) config.gh-runner.repos
    );

    system.stateVersion = "26.11";
  };
}
