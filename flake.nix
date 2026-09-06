{
  description = "NixOS configuration for on-demand AWS GitHub Actions runners";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
  };

  outputs =
    {
      self,
      nixpkgs,
      determinate,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      nixosModules.gh-runner = import ./gh-runner.nix;

      nixosConfigurations.gh-runner = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
          determinate.nixosModules.default
          self.nixosModules.gh-runner
        ];
      };

      devShells = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              awscli2
              opentofu
              infracost
              gh
              tflint
              jq
            ];
          };
        }
      );
    };
}
