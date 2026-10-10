{ mkDerivation, aeson, base, base16-bytestring, bytestring, containers
, cryptohash-sha256, directory, file-embed, filelock, filepath
, http-types, lib, network, optparse-applicative, sqlite-simple
, streaming-commons, text, time, transformers, unix, wai, warp
}:
mkDerivation {
  pname = "akyuu";
  version = "0.1.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson base base16-bytestring bytestring containers cryptohash-sha256
    directory file-embed filelock filepath http-types network
    optparse-applicative sqlite-simple streaming-commons text time
    transformers unix wai warp
  ];
  executableHaskellDepends = [ base ];
  description = "akyuu";
  license = "unknown";
  mainProgram = "akyuu";
}
