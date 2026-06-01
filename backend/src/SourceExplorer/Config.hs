module SourceExplorer.Config
  ( loadConfig
  , defaultConfigPath
  ) where

import Data.Maybe (fromMaybe)
import SourceExplorer.Types
import System.Environment (lookupEnv)
import Data.Yaml (decodeFileThrow)

defaultConfigPath :: FilePath
defaultConfigPath = "config/source-explorer.example.yaml"

loadConfig :: Maybe FilePath -> IO AppConfig
loadConfig explicitPath = do
  envPath <- lookupEnv "SOURCE_EXPLORER_CONFIG"
  decodeFileThrow (fromMaybe defaultConfigPath (explicitPath <|> envPath))

(<|>) :: Maybe a -> Maybe a -> Maybe a
(<|>) (Just x) _ = Just x
(<|>) Nothing y = y

