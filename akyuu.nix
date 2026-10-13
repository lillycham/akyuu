{ mkDerivation, aeson, base, base16-bytestring, bytestring
, containers, cryptohash-sha256, directory, file-embed, filelock
, filepath, http-types, lib, network, optparse-applicative, process
, sqlite-simple, streaming-commons, tasty, tasty-hunit
, tasty-quickcheck, text, time, transformers, unix, wai, warp
}:
mkDerivation {
  pname = "akyuu";
  version = "0.2.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson base base16-bytestring bytestring containers
    cryptohash-sha256 directory file-embed filelock filepath http-types
    network optparse-applicative process sqlite-simple
    streaming-commons text time transformers unix wai warp
  ];
  executableHaskellDepends = [ base ];
  testHaskellDepends = [
    aeson base base16-bytestring bytestring containers directory
    filelock filepath http-types optparse-applicative sqlite-simple
    tasty tasty-hunit tasty-quickcheck text time wai
  ];
  description = "akyuu";
  license = lib.meta.getLicenseFromSpdxId "MIT";
  mainProgram = "akyuu";
}
