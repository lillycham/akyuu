{ mkDerivation, base, base16-bytestring, bytestring, containers
, cryptohash-sha256, directory, filepath, lib, sqlite-simple
, text, time, unix
}:
mkDerivation {
  pname = "akyuu";
  version = "0.1.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    base base16-bytestring bytestring containers cryptohash-sha256
    directory filepath sqlite-simple text time unix
  ];
  executableHaskellDepends = [ base ];
  description = "akyuu";
  license = "unknown";
  mainProgram = "akyuu";
}
