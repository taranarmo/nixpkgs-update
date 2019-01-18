{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module Check
  ( result
  ) where

import OurPrelude

import Control.Applicative (many)
import Data.Char (isSpace)
import qualified Data.Text as T
import Prelude hiding (FilePath)
import qualified Shell
import Shelly
import qualified Text.Regex.Applicative.Text as RE
import Text.Regex.Applicative.Text (RE', (=~))
import Utils (Options(..), UpdateEnv(..), Version)

default (T.Text)

data BinaryCheck = BinaryCheck
  { filePath :: FilePath
  , zeroExitCode :: Bool
  , versionPresent :: Bool
  }

-- | Construct regex: [^\.]*${version}\.*\s*
versionRegex :: Text -> RE' ()
versionRegex version =
  (\_ _ _ _ -> ()) <$> many (RE.psym (/= '.')) <*> RE.string version <*>
  many (RE.sym '.') <*>
  many (RE.psym isSpace)

-- | Run a program with provided argument and report whether the output
-- mentions the expected version
checkBinary :: Text -> Version -> FilePath -> Sh BinaryCheck
checkBinary argument expectedVersion program =
  catchany_sh
    (do stdout <- Shell.canFail $ cmd "timeout" "-k" "2" "1" program argument
        code <- lastExitCode
        stderr <- lastStderr
        let hasVersion =
              isJust $
              (T.unwords . T.lines $ stdout <> "\n" <> stderr) =~
              versionRegex expectedVersion
        return $ BinaryCheck program (code == 0) hasVersion)
    (\_ -> return $ BinaryCheck program False False)

checks :: [Version -> FilePath -> Sh BinaryCheck]
checks =
  [ checkBinary ""
  , checkBinary "-V"
  , checkBinary "-v"
  , checkBinary "--version"
  , checkBinary "version"
  , checkBinary "-h"
  , checkBinary "--help"
  , checkBinary "help"
  ]

someChecks :: BinaryCheck -> [Sh BinaryCheck] -> Sh BinaryCheck
someChecks best [] = return best
someChecks best (c:rest) = do
  current <- c
  let nb = newBest current
  case nb of
    BinaryCheck _ True True -> return nb
    _ -> someChecks nb rest
  where
    newBest :: BinaryCheck -> BinaryCheck
    newBest (BinaryCheck _ currentExit currentVersionPresent) =
      BinaryCheck
        (filePath best)
        (zeroExitCode best || currentExit)
        (versionPresent best || currentVersionPresent)

-- | Run a program with various version or help flags and report
-- when they succeded
runChecks :: Version -> FilePath -> Sh BinaryCheck
runChecks expectedVersion program =
  someChecks (BinaryCheck program False False) checks'
  where
    checks' = map (\c -> c expectedVersion program) checks

checkReport :: BinaryCheck -> Text
checkReport (BinaryCheck p False False) =
  "- Warning: no invocation of " <> toTextIgnore p <>
  " had a zero exit code or showed the expected version"
checkReport (BinaryCheck p _ _) =
  "- " <> toTextIgnore p <> " passed the binary check."

result :: UpdateEnv -> FilePath -> Sh Text
result updateEnv resultPath = do
  let expectedVersion = newVersion updateEnv
  home <- get_env_text "HOME"
  let logFile = workingDir (options updateEnv) </> "check-result-log.tmp"
  setenv "EDITOR" "echo"
  setenv "HOME" "/homeless-shelter"
  let addToReport input = appendfile logFile (input <> "\n")
  tempdir <- fromText . T.strip <$> cmd "mktemp" "-d"
  chdir tempdir $ do
    rm_f logFile
    let binaryDir = resultPath </> "bin"
    binExists <- test_d binaryDir
    binaries <-
      if binExists
        then findWhen test_f (resultPath </> "bin")
        else return []
    checks' <- forM binaries $ \binary -> runChecks expectedVersion binary
    addToReport (T.intercalate "\n" (map checkReport checks'))
    let passedZeroExitCode =
          (T.pack . show)
            (foldl
               (\acc c ->
                  if zeroExitCode c
                    then acc + 1
                    else acc)
               0
               checks' :: Int)
        passedVersionPresent =
          (T.pack . show)
            (foldl
               (\acc c ->
                  if versionPresent c
                    then acc + 1
                    else acc)
               0
               checks' :: Int)
        numBinaries = (T.pack . show) (length binaries)
    addToReport
      ("- " <> passedZeroExitCode <> " of " <> numBinaries <>
       " passed binary check by having a zero exit code.")
    addToReport
      ("- " <> passedVersionPresent <> " of " <> numBinaries <>
       " passed binary check by having the new version present in output.")
    _ <- Shell.canFail $ cmd "grep" "-r" expectedVersion resultPath
    whenM ((== 0) <$> lastExitCode) $
      addToReport $
      "- found " <> expectedVersion <> " with grep in " <>
      toTextIgnore resultPath
    whenM
      (null <$>
       findWhen
         (\p -> ((expectedVersion `T.isInfixOf` toTextIgnore p) &&) <$> test_f p)
         resultPath) $
      addToReport $
      "- found " <> expectedVersion <> " in filename of file in " <>
      toTextIgnore resultPath
    setenv "HOME" home
    gist1 <- cmd "tree" resultPath -|- cmd "gist"
    unless (T.null gist1) $
      addToReport $ "- directory tree listing: " <> T.strip gist1
    gist2 <- cmd "du" "-h" resultPath -|- cmd "gist"
    unless (T.null gist2) $ addToReport $ "- du listing: " <> T.strip gist2
  Shell.canFail $ readfile logFile
