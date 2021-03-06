# This file was auto-generated by cabal2nix. Please do NOT edit manually!

{ haskellPackages ? (import <nixpkgs> {}).haskellPackages
, parClasses      ? (import ../par-classes {})
, parCollections  ? (import ../par-collections {})
}:

with haskellPackages;
cabal.mkDerivation (self: {
  pname = "lvish";
  version = "2.0.2";
  src = ./.;
  configureFlags = "--ghc-option=-j4";
  noHaddock = true;
  sha256 = "";
#  doCheck= false;
  buildDepends = [
    async atomicPrimops bitsAtomic chaselevDeque deepseq lattices missingForeign
    parClasses parCollections random threadLocalStorage transformers
    vector
  ];
  testDepends = [
    HUnit parClasses parCollections QuickCheck random testFramework
    testFrameworkHunit testFrameworkQuickcheck2 testFrameworkTh text
    time vector
  ];
  meta = {
    description = "Parallel scheduler, LVar data structures, and infrastructure to build more";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
  };
})
