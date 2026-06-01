module SourceExplorer.Database
  ( DbPool
  , connectInfoFromConfig
  , createDbPool
  , runMigrations
  , withDb
  , upsertRepository
  , upsertBranch
  , insertCommit
  , insertBranchCommit
  , insertFileRevision
  , ensureParseResult
  , replaceParseSymbols
  , attachOccurrences
  , startIndexJob
  , finishIndexJob
  , failIndexJob
  , listRepositories
  , listBranches
  , listCommits
  , listFiles
  , getFileContent
  , searchSymbols
  , listIndexStatus
  ) where

import Control.Monad (forM_, void, when)
import Data.Maybe (listToMaybe)
import Data.Pool (Pool, defaultPoolConfig, newPool, withResource)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Database.PostgreSQL.Simple
import SourceExplorer.Parser (ParsedSymbol (..))
import SourceExplorer.Types
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>), takeExtension)

type DbPool = Pool Connection

connectInfoFromConfig :: DatabaseConfig -> ConnectInfo
connectInfoFromConfig DatabaseConfig {..} =
  defaultConnectInfo
    { connectHost = T.unpack host
    , connectPort = fromIntegral port
    , connectUser = T.unpack user
    , connectPassword = T.unpack password
    , connectDatabase = T.unpack database
    }

createDbPool :: ConnectInfo -> IO DbPool
createDbPool info =
  newPool $
    defaultPoolConfig
      (connect info)
      close
      60
      10

withDb :: DbPool -> (Connection -> IO a) -> IO a
withDb = withResource

runMigrations :: DbPool -> FilePath -> IO ()
runMigrations pool dir = do
  exists <- doesDirectoryExist dir
  when exists $ do
    files <- filter ((== ".sql") . takeExtension) <$> listDirectory dir
    withDb pool $ \conn ->
      forM_ (map (dir </>) files) $ \file -> do
        sql <- readFile file
        void (execute_ conn (fromString sql))

upsertRepository :: Connection -> RepositoryConfig -> IO Int
upsertRepository conn RepositoryConfig {..} = do
  rows <-
    query
      conn
      "INSERT INTO repositories (name, url, default_branch, updated_at) VALUES (?, ?, ?, now()) \
      \ON CONFLICT (name) DO UPDATE SET url = EXCLUDED.url, default_branch = EXCLUDED.default_branch, updated_at = now() \
      \RETURNING id"
      (name, T.pack url, defaultBranch)
  case rows of
    [Only repoId] -> pure repoId
    _ -> fail "repository upsert did not return an id"

upsertBranch :: Connection -> Int -> Text -> Maybe Text -> Bool -> IO ()
upsertBranch conn repoId branchName headSha stale =
  void $
    execute
      conn
      "INSERT INTO branches (repository_id, name, head_sha, is_stale, updated_at) VALUES (?, ?, ?, ?, now()) \
      \ON CONFLICT (repository_id, name) DO UPDATE SET head_sha = EXCLUDED.head_sha, is_stale = EXCLUDED.is_stale, updated_at = now()"
      (repoId, branchName, headSha, stale)

insertCommit ::
  Connection ->
  Int ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  [Text] ->
  IO ()
insertCommit conn repoId sha message authorName authorEmail authorTime committerName committerEmail committerTime parents = do
  void $
    execute
      conn
      "INSERT INTO commits \
      \(repository_id, sha, message, author_name, author_email, author_time, committer_name, committer_email, committer_time) \
      \VALUES (?, ?, ?, ?, ?, ?::timestamptz, ?, ?, ?::timestamptz) \
      \ON CONFLICT (repository_id, sha) DO NOTHING"
      (repoId, sha, message, authorName, authorEmail, authorTime, committerName, committerEmail, committerTime)
  forM_ parents $ \parent ->
    void $
      execute
        conn
        "INSERT INTO commit_parents (repository_id, commit_sha, parent_sha) VALUES (?, ?, ?) ON CONFLICT DO NOTHING"
        (repoId, sha, parent)

insertBranchCommit :: Connection -> Int -> Text -> Text -> IO ()
insertBranchCommit conn repoId branchName sha =
  void $
    execute
      conn
      "INSERT INTO branch_commits (repository_id, branch_name, commit_sha) VALUES (?, ?, ?) ON CONFLICT DO NOTHING"
      (repoId, branchName, sha)

insertFileRevision ::
  Connection ->
  Int ->
  Text ->
  Text ->
  Maybe Text ->
  Text ->
  Integer ->
  Text ->
  Maybe Text ->
  Maybe Text ->
  IO Int
insertFileRevision conn repoId commitSha path language contentHash sizeBytes status errorText contentText = do
  rows <-
    query
      conn
      "INSERT INTO file_revisions \
      \(repository_id, commit_sha, path, language, content_hash, size_bytes, status, error, content, indexed_at) \
      \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, now()) \
      \ON CONFLICT (repository_id, commit_sha, path) DO UPDATE SET \
      \language = EXCLUDED.language, content_hash = EXCLUDED.content_hash, size_bytes = EXCLUDED.size_bytes, \
      \status = EXCLUDED.status, error = EXCLUDED.error, content = EXCLUDED.content, indexed_at = now() \
      \RETURNING id"
      (repoId, commitSha, path, language, contentHash, sizeBytes, status, errorText, contentText)
  case rows of
    [Only fileId] -> pure fileId
    _ -> fail "file revision insert did not return an id"

ensureParseResult :: Connection -> Text -> Text -> Text -> Text -> IO (Int, Bool)
ensureParseResult conn contentHash language parser parserVer = do
  existing <-
    query
      conn
      "SELECT id FROM parse_results WHERE content_hash = ? AND language = ? AND parser_name = ? AND parser_version = ?"
      (contentHash, language, parser, parserVer)
  case existing of
    [Only parseId] -> pure (parseId, False)
    _ -> do
      rows <-
        query
          conn
          "INSERT INTO parse_results (content_hash, language, parser_name, parser_version, status) VALUES (?, ?, ?, ?, 'parsed') RETURNING id"
          (contentHash, language, parser, parserVer)
      case rows of
        [Only parseId] -> pure (parseId, True)
        _ -> fail "parse result insert did not return an id"

replaceParseSymbols :: Connection -> Int -> [ParsedSymbol] -> IO ()
replaceParseSymbols conn parseResultId symbols = do
  void (execute conn "DELETE FROM symbols WHERE parse_result_id = ?" (Only parseResultId))
  forM_ symbols $ \ParsedSymbol {..} ->
    void $
      execute
        conn
        "INSERT INTO symbols \
        \(parse_result_id, name, kind, container, start_line, start_column, end_line, end_column, snippet) \
        \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
        ( parseResultId
        , symbolName
        , symbolKind
        , symbolContainer
        , symbolStartLine
        , symbolStartColumn
        , symbolEndLine
        , symbolEndColumn
        , Just symbolSnippet
        )

attachOccurrences :: Connection -> Int -> Text -> Int -> Int -> IO ()
attachOccurrences conn repoId commitSha fileRevisionId parseResultId = do
  void (execute conn "DELETE FROM symbol_occurrences WHERE file_revision_id = ?" (Only fileRevisionId))
  void $
    execute
      conn
      "INSERT INTO symbol_occurrences \
      \(repository_id, commit_sha, file_revision_id, symbol_id, role, name, kind, container, start_line, start_column, end_line, end_column, snippet) \
      \SELECT ?, ?, ?, id, 'definition', name, kind, container, start_line, start_column, end_line, end_column, snippet \
      \FROM symbols WHERE parse_result_id = ?"
      (repoId, commitSha, fileRevisionId, parseResultId)

startIndexJob :: Connection -> Maybe Int -> Text -> IO Int
startIndexJob conn repoId message = do
  rows <-
    query
      conn
      "INSERT INTO indexing_jobs (repository_id, status, message) VALUES (?, 'running', ?) RETURNING id"
      (repoId, Just message)
  case rows of
    [Only jobId] -> pure jobId
    _ -> fail "index job insert did not return an id"

finishIndexJob :: Connection -> Int -> Text -> IO ()
finishIndexJob conn jobId message =
  void $
    execute
      conn
      "UPDATE indexing_jobs SET status = 'succeeded', message = ?, finished_at = now() WHERE id = ?"
      (message, jobId)

failIndexJob :: Connection -> Int -> Text -> IO ()
failIndexJob conn jobId message =
  void $
    execute
      conn
      "UPDATE indexing_jobs SET status = 'failed', message = ?, finished_at = now() WHERE id = ?"
      (message, jobId)

listRepositories :: Connection -> IO [RepositorySummary]
listRepositories conn =
  query_ conn "SELECT id, name, url, default_branch FROM repositories ORDER BY name"

listBranches :: Connection -> Text -> IO [BranchSummary]
listBranches conn repoName =
  query
    conn
    "SELECT b.name, b.head_sha, b.is_stale \
    \FROM branches b JOIN repositories r ON r.id = b.repository_id \
    \WHERE r.name = ? ORDER BY b.name"
    (Only repoName)

listCommits :: Connection -> Text -> Maybe Text -> Int -> IO [CommitSummary]
listCommits conn repoName branchName limitRows =
  case branchName of
    Nothing ->
      query
        conn
        "SELECT c.sha, c.message, c.author_name, c.author_email, c.author_time, c.committer_time \
        \FROM commits c JOIN repositories r ON r.id = c.repository_id \
        \WHERE r.name = ? ORDER BY c.committer_time DESC LIMIT ?"
        (repoName, limitRows)
    Just branch ->
      query
        conn
        "SELECT c.sha, c.message, c.author_name, c.author_email, c.author_time, c.committer_time \
        \FROM commits c \
        \JOIN repositories r ON r.id = c.repository_id \
        \JOIN branch_commits bc ON bc.repository_id = r.id AND bc.commit_sha = c.sha \
        \WHERE r.name = ? AND bc.branch_name = ? ORDER BY c.committer_time DESC LIMIT ?"
        (repoName, branch, limitRows)

listFiles :: Connection -> Text -> Text -> Int -> IO [FileSummary]
listFiles conn repoName commitSha limitRows =
  query
    conn
    "SELECT f.path, f.language, f.content_hash, f.size_bytes, f.status, f.error \
    \FROM file_revisions f JOIN repositories r ON r.id = f.repository_id \
    \WHERE r.name = ? AND f.commit_sha = ? ORDER BY f.path LIMIT ?"
    (repoName, commitSha, limitRows)

getFileContent :: Connection -> Text -> Text -> Text -> IO (Maybe FileContent)
getFileContent conn repoName commitSha filePath =
  listToMaybe
    <$> query
      conn
      "SELECT f.path, f.language, COALESCE(f.content, '') \
      \FROM file_revisions f JOIN repositories r ON r.id = f.repository_id \
      \WHERE r.name = ? AND f.commit_sha = ? AND f.path = ?"
      (repoName, commitSha, filePath)

searchSymbols :: Connection -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Int -> IO [SymbolSummary]
searchSymbols conn repoName queryText kind language limitRows =
  query
    conn
    "SELECT r.name, o.commit_sha, f.path, o.name, o.kind, o.container, o.start_line, o.start_column, o.end_line, o.end_column, o.snippet \
    \FROM symbol_occurrences o \
    \JOIN repositories r ON r.id = o.repository_id \
    \JOIN file_revisions f ON f.id = o.file_revision_id \
    \WHERE (? IS NULL OR r.name = ?) \
    \AND (? IS NULL OR o.name ILIKE '%' || ? || '%') \
    \AND (? IS NULL OR o.kind = ?) \
    \AND (? IS NULL OR f.language = ?) \
    \ORDER BY o.name, f.path LIMIT ?"
    ( repoName
    , repoName
    , queryText
    , queryText
    , kind
    , kind
    , language
    , language
    , limitRows
    )

listIndexStatus :: Connection -> Maybe Text -> Int -> IO [IndexStatus]
listIndexStatus conn repoName limitRows =
  query
    conn
    "SELECT r.name, j.status, j.message, j.started_at, j.finished_at \
    \FROM indexing_jobs j LEFT JOIN repositories r ON r.id = j.repository_id \
    \WHERE (? IS NULL OR r.name = ?) ORDER BY j.started_at DESC LIMIT ?"
    (repoName, repoName, limitRows)
