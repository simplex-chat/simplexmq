{
  description = "simplexmq";

  inputs = {
    # Nix Inputs
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    aeson-src = {
      url = "github:JonathanLorimer/aeson/b6634ea9c8960d2dab4dc0e1ab76bbfe23fba928";
      flake = false;
    };
    hs-socks-src = {
      url = "github:simplex-chat/hs-socks/a30cc7a79a08d8108316094f8f2f82a0c5e1ac51";
      flake = false;
    };
    http2-src = {
      url = "github:kazu-yamamoto/http2/b5a1b7200cf5bc7044af34ba325284271f6dff25";
      flake = false;
    };
    direct-sqlcipher-src = {
      url = "github:simplex-chat/direct-sqlcipher/34309410eb2069b029b8fc1872deb1e0db123294";
      flake = false;
    };
    sqlcipher-simple-src = {
      url = "github:simplex-chat/sqlcipher-simple/5e154a2aeccc33ead6c243ec07195ab673137221";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    aeson-src,
    hs-socks-src,
    http2-src,
    direct-sqlcipher-src,
    sqlcipher-simple-src
  }: 
    let
      forAllSystems = function:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ] (system: function rec {
          inherit system;
          compilerVersion = "ghc94";
          pkgs = nixpkgs.legacyPackages.${system};
          
          hsPkgs = pkgs.haskell.packages.${compilerVersion}.override {
            overrides = hfinal: hprev: with pkgs.haskell.lib; {
              simplexmq = hfinal.callCabal2nix "simplexmq" ./. {};
              aeson = dontCheck (hfinal.callCabal2nix "aeson" "${aeson-src}" {});
              hs-socks = hfinal.callCabal2nix "hs-socks" "${hs-socks-src}" {};
              http2 = hfinal.callCabal2nix "http2" "${http2-src}" {};
              direct-sqlcipher = dontCheck (hfinal.callCabal2nix "direct-sqlcipher" "${direct-sqlcipher-src}" {});
              sqlcipher-simple = dontCheck (hfinal.callCabal2nix "sqlcipher-simple" "${sqlcipher-simple-src}" {});
            };
          };
        });
    in
    {
      # nix fmt
      formatter = forAllSystems ({pkgs, ...}: pkgs.alejandra);

      # nix develop
      devShells = forAllSystems ({hsPkgs, pkgs, system, ...}: {
        default = 
          hsPkgs.shellFor {
            packages = p: [
              p.simplexmq
            ];
            buildInputs = with pkgs;
              [
                hsPkgs.haskell-language-server
                haskellPackages.cabal-install
                hpack
                # cabal2nix
                haskellPackages.ghcid
              ];
        };
      });

      # nix build
      packages = forAllSystems ({hsPkgs, ...}: {
          simplexmq = hsPkgs.simplexmq;
          default = hsPkgs.simplexmq;
      });

      # You can't build the cfg package as a check because of IFD in cabal2nix
      checks = {};

      # nix run
      apps = forAllSystems ({system, ...}: {
        #TODO: add all the different bins here
      });
    };
}
