module SourceExplorer.Indexer
  ( runIndexer
  , indexOnce
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import SourceExplorer.Database
import SourceExplorer.Git
import SourceExplorer.Hash
import SourceExplorer.Parser
import SourceExplorer.Types

runIndexer :: AppConfig -> IO ()
runIndexer config@AppConfig {..} = do
  pool <- createDbPool (connectInfoFromConfig database)
  runMigrations pool "db"
  case mode indexer of
    Once -> indexOnce pool config
    Continuous -> foreverPoll pool config

foreverPoll :: DbPool -> AppConfig -> IO ()
foreverPoll pool config@AppConfig {..} = do
  indexOnce pool config
  let waitSeconds = max 1 (defaultPollingIntervalSeconds indexer)
  putStrLn ("indexer sleeping for " <> show waitSeconds <> " seconds")
  threadDelay (waitSeconds * 1000000)
  foreverPoll pool config

indexOnce :: DbPool -> AppConfig -> IO ()
indexOnce pool AppConfig {..} =
  forM_ repositories $ \repo -> do
    repoId <- withDb pool (`upsertRepository` repo)
    jobId <- withDb pool $ \conn -> startIndexJob conn (Just repoId) "indexing repository"
    result <- try (indexRepository pool indexer repoId repo) :: IO (Either SomeException ())
    case result of
      Right () -> withDb pool $ \conn -> finishIndexJob conn jobId "indexing completed"
      Left err -> withDb pool $ \conn -> failIndexJob conn jobId (T.pack (show err))

indexRepository :: DbPool -> IndexerConfig -> Int -> RepositoryConfig -> IO ()
indexRepository pool indexerConfig repoId repo@RepositoryConfig {..} = do
  repoPath <- ensureClone (cloneDir indexerConfig) name url
  branches <- filterBranches repo <$> listRemoteBranches repoPath
  forM_ branches $ \branch -> do
    headSha <- branchHead repoPath branch
    withDb pool $ \conn -> upsertBranch conn repoId branch headSha False
    commits <- listBranchCommits repoPath branch
    forM_ commits $ \sha -> do
      info <- commitInfo repoPath sha
      withDb pool $ \conn -> do
        insertCommit
          conn
          repoId
          sha
          (commitMessage info)
          (commitAuthorName info)
          (commitAuthorEmail info)
          (commitAuthorTime info)
          (commitCommitterName info)
          (commitCommitterEmail info)
          (commitCommitterTime info)
          (commitParents info)
        insertBranchCommit conn repoId branch sha
      files <- filter (pathAllowed repo) <$> listCommitFiles repoPath sha
      forM_ files $ indexFile pool indexerConfig repoId repoPath sha

filterBranches :: RepositoryConfig -> [Text] -> [Text]
filterBranches RepositoryConfig {..} =
  filter included . filter excluded
  where
    included branch = null includeBranches || branch `elem` includeBranches
    excluded branch = branch `notElem` excludeBranches

pathAllowed :: RepositoryConfig -> FilePath -> Bool
pathAllowed RepositoryConfig {..} path =
  included && not excluded
  where
    included = null includePaths || any (`isPrefixOf` path) includePaths
    excluded = any (`isPrefixOf` path) excludePaths

indexFile :: DbPool -> IndexerConfig -> Int -> FilePath -> Text -> FilePath -> IO ()
indexFile pool IndexerConfig {..} repoId repoPath sha path = do
  let language = detectLanguage path
  content <- readCommitFile repoPath sha path
  let bytes = TE.encodeUtf8 content
      sizeBytes = fromIntegral (BS.length bytes)
      contentHash = sha256Text bytes
      pathText = T.pack path
  if sizeBytes > maxFileBytes
    then do
      _ <- withDb pool $ \conn ->
        insertFileRevision conn repoId sha pathText language contentHash sizeBytes "skipped" (Just "file exceeds configured maxFileBytes") Nothing
      pure ()
    else case language of
      Nothing -> do
        _ <- withDb pool $ \conn ->
          insertFileRevision conn repoId sha pathText Nothing contentHash sizeBytes "skipped" (Just "unsupported language") Nothing
        pure ()
      Just lang -> do
        fileId <- withDb pool $ \conn ->
          insertFileRevision conn repoId sha pathText (Just lang) contentHash sizeBytes "parsed" Nothing (Just content)
        (parseResultId, isNew) <- withDb pool $ \conn ->
          ensureParseResult conn contentHash lang parserName parserVersion
        when isNew $
          withDb pool $ \conn ->
            replaceParseSymbols conn parseResultId (parseSymbols lang content)
        withDb pool $ \conn -> attachOccurrences conn repoId sha fileId parseResultId
