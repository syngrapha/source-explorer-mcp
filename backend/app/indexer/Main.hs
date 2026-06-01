module Main (main) where

import Options.Applicative
import SourceExplorer.Config
import SourceExplorer.Indexer

main :: IO ()
main = do
  configPath <- execParser parserInfo
  loadConfig configPath >>= runIndexer

parserInfo :: ParserInfo (Maybe FilePath)
parserInfo =
  info
    (optional (strOption (long "config" <> metavar "PATH" <> help "Path to source-explorer YAML config")) <**> helper)
    (fullDesc <> progDesc "Run the Source Explorer indexer")

