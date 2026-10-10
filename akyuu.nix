{ mkDerivation, aeson, base, base16-bytestring, bytestring, containers
, cryptohash-sha256, directory, filelock, filepath, lib
, optparse-applicative, sqlite-simple
, text, time, transformers, unix
}:
mkDerivation {
  pname = "akyuu";
  version = "0.1.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson base base16-bytestring bytestring containers cryptohash-sha256
    directory filelock filepath optparse-applicative sqlite-simple text
    time transformers unix
  ];
  executableHaskellDepends = [ base ];
  description = "akyuu";
  license = "unknown";
  mainProgram = "akyuu";
}
