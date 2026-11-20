-- | A switch that turns memory off, so that a session starts with no context.
--
-- Memory is off when the variable @AKYUU_DISABLED@ is set to something other
-- than empty, @0@, @false@, @no@ or @off@, or when the file @disabled@ is in
-- the root of the store. The variable is for one shell or one session. The file
-- stays until @akyuu enable@ removes it. The variable wins: @AKYUU_DISABLED=0@
-- turns memory on again for one session, even when the file is there.
--
-- Only the start of a session ('Akyuu.CLI' @context@) and the tools of the MCP
-- server check the switch. The other commands still work, so a person can
-- read and write memories by hand.
module Akyuu.Disabled
  ( isDisabled,
    markerPath,
    setDisabled,
    disabledMessage,
  )
where

import Akyuu.Fs (ifMissing)
import Data.Char (toLower)
import System.Directory (doesFileExist, removeFile)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

-- | The file that turns memory off for every session.
markerPath :: FilePath -> FilePath
markerPath root = root </> "disabled"

-- | The text of a refusal.
disabledMessage :: String
disabledMessage = "akyuu is turned off (AKYUU_DISABLED, or the file 'disabled' in the root). Run 'akyuu enable' to turn it on."

-- | Is memory off? The variable is read first.
isDisabled :: Maybe FilePath -> IO Bool
isDisabled root = do
  v <- lookupEnv "AKYUU_DISABLED"
  case v of
    Just s | not (null s) -> pure (truthy s)
    _ -> maybe (pure False) (doesFileExist . markerPath) root
  where
    truthy s = map toLower s `notElem` ["0", "false", "no", "off"]

-- | Write or remove the file. Removing a file that is not there is not an
-- error.
setDisabled :: FilePath -> Bool -> IO ()
setDisabled root True = writeFile (markerPath root) "akyuu is turned off while this file exists. Run 'akyuu enable' to remove it.\n"
setDisabled root False = ifMissing () (removeFile (markerPath root))
