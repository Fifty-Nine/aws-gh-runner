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
    };
}
