{
  description = "update nixpkgs automatically";

  inputs.mmdoc.url = "github:ryantm/mmdoc";
  inputs.mmdoc.inputs.nixpkgs.follows = "nixpkgs";

  inputs.treefmt-nix.url = "github:numtide/treefmt-nix";
  inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

  inputs.runtimeDeps.url = "github:NixOS/nixpkgs/nixos-unstable-small";

  nixConfig.extra-substituters = "https://nix-community.cachix.org";
  nixConfig.extra-trusted-public-keys = "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";

  outputs = { self, nixpkgs, mmdoc, treefmt-nix, runtimeDeps } @ args:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      treefmtEval = eachSystem (pkgs: treefmt-nix.lib.evalModule pkgs {
        projectRootFile = ".git/config";
        programs.ormolu.enable = true;
      });

      buildAttrs = eachSystem (pkgs: {
        packages = import ./pkgs/default.nix (args // { inherit (pkgs) system; });
        devShell = pkgs.callPackage ./shell.nix {};
        treefmt = treefmtEval.${pkgs.system}.config.build.check self;
      });
    in
    {
      # Define checks for all systems
      checks = eachSystem (pkgs: {
        inherit (buildAttrs.${pkgs.system}) treefmt;
        devShell = buildAttrs.${pkgs.system}.devShell;
        packages = buildAttrs.${pkgs.system}.packages;
      });

      # Define packages and devShells for all systems
      packages = eachSystem (pkgs: buildAttrs.${pkgs.system}.packages);
      devShells = eachSystem (pkgs: { default = buildAttrs.${pkgs.system}.devShell; });

      # Define a formatter for all systems
      formatter = eachSystem (pkgs: treefmtEval.${pkgs.system}.config.build.wrapper);
    };
}
