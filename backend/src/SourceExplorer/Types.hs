module SourceExplorer.Types
  ( AppConfig (..)
  , DatabaseConfig (..)
  , IndexerConfig (..)
  , ServerConfig (..)
  , RepositoryConfig (..)
  , IndexerMode (..)
  , RepositorySummary (..)
  , BranchSummary (..)
  , CommitSummary (..)
  , FileSummary (..)
  , SymbolSummary (..)
  , IndexStatus (..)
  , SymbolDef (..)
  , FileContent (..)
  , SymbolKind
  , Language
  ) where

import Data.Aeson
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

type SymbolKind = Text
type Language = Text

data AppConfig = AppConfig
  { server :: ServerConfig
  , database :: DatabaseConfig
  , indexer :: IndexerConfig
  , repositories :: [RepositoryConfig]
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON AppConfig

data ServerConfig = ServerConfig
  { host :: Text
  , port :: Int
  , accessToken :: Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON ServerConfig

data DatabaseConfig = DatabaseConfig
  { host :: Text
  , port :: Int
  , user :: Text
  , password :: Text
  , database :: Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON DatabaseConfig

data IndexerMode = Continuous | Once
  deriving stock (Show, Eq, Generic)

instance FromJSON IndexerMode where
  parseJSON = withText "IndexerMode" $ \case
    "continuous" -> pure Continuous
    "once" -> pure Once
    "batch" -> pure Once
    other -> fail ("unsupported indexer mode: " <> show other)

data IndexerConfig = IndexerConfig
  { mode :: IndexerMode
  , cloneDir :: FilePath
  , defaultPollingIntervalSeconds :: Int
  , maxFileBytes :: Integer
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON IndexerConfig

data RepositoryConfig = RepositoryConfig
  { name :: Text
  , url :: FilePath
  , defaultBranch :: Text
  , includeBranches :: [Text]
  , excludeBranches :: [Text]
  , includePaths :: [FilePath]
  , excludePaths :: [FilePath]
  , pollingIntervalSeconds :: Maybe Int
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON RepositoryConfig where
  parseJSON = withObject "RepositoryConfig" $ \o ->
    RepositoryConfig
      <$> o .: "name"
      <*> o .: "url"
      <*> o .: "defaultBranch"
      <*> o .:? "includeBranches" .!= []
      <*> o .:? "excludeBranches" .!= []
      <*> o .:? "includePaths" .!= []
      <*> o .:? "excludePaths" .!= []
      <*> o .:? "pollingIntervalSeconds"

data RepositorySummary = RepositorySummary
  { id :: Int
  , name :: Text
  , url :: Text
  , defaultBranch :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)

data BranchSummary = BranchSummary
  { name :: Text
  , headSha :: Maybe Text
  , isStale :: Bool
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)

data CommitSummary = CommitSummary
  { sha :: Text
  , message :: Text
  , authorName :: Text
  , authorEmail :: Text
  , authorTime :: UTCTime
  , committerTime :: UTCTime
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)

data FileSummary = FileSummary
  { path :: Text
  , language :: Maybe Text
  , contentHash :: Text
  , sizeBytes :: Integer
  , status :: Text
  , error :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)

data FileContent = FileContent
  { path :: Text
  , language :: Maybe Text
  , content :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)

data SymbolSummary = SymbolSummary
  { repository :: Text
  , commitSha :: Text
  , filePath :: Text
  , name :: Text
  , kind :: Text
  , container :: Maybe Text
  , startLine :: Int
  , startColumn :: Int
  , endLine :: Int
  , endColumn :: Int
  , snippet :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)

data SymbolDef = SymbolDef
  { symbol :: SymbolSummary
  , role :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)

data IndexStatus = IndexStatus
  { repository :: Maybe Text
  , status :: Text
  , message :: Maybe Text
  , startedAt :: UTCTime
  , finishedAt :: Maybe UTCTime
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON)

