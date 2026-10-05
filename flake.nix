{
  description = "akyuu";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        # akyuu.nix comes from `cabal2nix . > akyuu.nix`. 
        # Rerun it when akyuu.cabal changes.
        # Avoids IFD problem w/flake show.
        default = pkgs.haskellPackages.callPackage ./akyuu.nix { };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.haskellPackages.shellFor {
          packages = _: [ self.packages.${pkgs.stdenv.hostPlatform.system}.default ];
          nativeBuildInputs = with pkgs.haskellPackages; [
            cabal-install
            haskell-language-server
          ];
        };
      });
    };
}