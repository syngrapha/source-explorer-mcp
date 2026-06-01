module SourceExplorer.Git
  ( CommitInfo (..)
  , ensureClone
  , listRemoteBranches
  , branchHead
  , listBranchCommits
  , commitInfo
  , listCommitFiles
  , readCommitFile
  ) where

import Control.Exception (throwIO)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readCreateProcessWithExitCode, proc)

data CommitInfo = CommitInfo
  { commitSha :: Text
  , commitParents :: [Text]
  , commitMessage :: Text
  , commitAuthorName :: Text
  , commitAuthorEmail :: Text
  , commitAuthorTime :: Text
  , commitCommitterName :: Text
  , commitCommitterEmail :: Text
  , commitCommitterTime :: Text
  }
  deriving stock (Show, Eq)

ensureClone :: FilePath -> Text -> FilePath -> IO FilePath
ensureClone cloneRoot repoName url = do
  createDirectoryIfMissing True cloneRoot
  let target = cloneRoot </> safeRepoDir repoName
  exists <- doesDirectoryExist (target </> ".git")
  if exists
    then do
      _ <- git target ["fetch", "--all", "--prune"]
      pure target
    else do
      _ <- run "git" ["clone", T.pack url, T.pack target]
      pure target

listRemoteBranches :: FilePath -> IO [Text]
listRemoteBranches repoPath = do
  output <- git repoPath ["branch", "-r", "--format=%(refname:short)"]
  pure
    [ fromMaybe branch (T.stripPrefix "origin/" branch)
    | raw <- T.lines output
    , let branch = T.strip raw
    , not (T.null branch)
    , branch /= "origin/HEAD"
    , "origin/HEAD" `T.isPrefixOf` branch == False
    ]

branchHead :: FilePath -> Text -> IO (Maybe Text)
branchHead repoPath branch = do
  result <- tryGit repoPath ["rev-parse", "origin/" <> branch]
  pure (T.strip <$> result)

listBranchCommits :: FilePath -> Text -> IO [Text]
listBranchCommits repoPath branch =
  T.lines <$> git repoPath ["rev-list", "origin/" <> branch]

commitInfo :: FilePath -> Text -> IO CommitInfo
commitInfo repoPath sha = do
  output <-
    git
      repoPath
      [ "show"
      , "-s"
      , "--date=iso-strict"
      , "--format=%H%x1f%P%x1f%B%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI"
      , sha
      ]
  case T.splitOn "\x1f" output of
    commitSha : parents : message : authorName : authorEmail : authorTime : committerName : committerEmail : committerTime : _ ->
      pure
        CommitInfo
          { commitSha = T.strip commitSha
          , commitParents = filter (not . T.null) (T.words parents)
          , commitMessage = T.strip message
          , commitAuthorName = T.strip authorName
          , commitAuthorEmail = T.strip authorEmail
          , commitAuthorTime = T.strip authorTime
          , commitCommitterName = T.strip committerName
          , commitCommitterEmail = T.strip committerEmail
          , commitCommitterTime = T.strip committerTime
          }
    _ -> fail ("could not parse git commit metadata for " <> T.unpack sha)

listCommitFiles :: FilePath -> Text -> IO [FilePath]
listCommitFiles repoPath sha =
  map T.unpack . T.lines <$> git repoPath ["ls-tree", "-r", "--name-only", sha]

readCommitFile :: FilePath -> Text -> FilePath -> IO Text
readCommitFile repoPath sha path =
  git repoPath ["show", sha <> ":" <> T.pack path]

git :: FilePath -> [Text] -> IO Text
git repoPath args =
  run "git" (["-C", T.pack repoPath] <> args)

tryGit :: FilePath -> [Text] -> IO (Maybe Text)
tryGit repoPath args = do
  (code, stdoutText, _) <- runRaw "git" (["-C", T.pack repoPath] <> args)
  pure $ case code of
    ExitSuccess -> Just stdoutText
    ExitFailure _ -> Nothing

run :: Text -> [Text] -> IO Text
run executable args = do
  (code, stdoutText, stderrText) <- runRaw executable args
  case code of
    ExitSuccess -> pure stdoutText
    ExitFailure _ ->
      throwIO (userError (T.unpack executable <> " failed: " <> T.unpack stderrText))

runRaw :: Text -> [Text] -> IO (ExitCode, Text, Text)
runRaw executable args = do
  (code, stdoutRaw, stderrRaw) <-
    readCreateProcessWithExitCode
      (proc (T.unpack executable) (map T.unpack args))
      ""
  pure (code, T.pack stdoutRaw, T.pack stderrRaw)

safeRepoDir :: Text -> FilePath
safeRepoDir =
  T.unpack . T.map replace
  where
    replace c
      | c == '-' || c == '_' || c == '.' = c
      | c >= 'a' && c <= 'z' = c
      | c >= 'A' && c <= 'Z' = c
      | c >= '0' && c <= '9' = c
      | otherwise = '_'

fromMaybe :: a -> Maybe a -> a
fromMaybe fallback Nothing = fallback
fromMaybe _ (Just value) = value
