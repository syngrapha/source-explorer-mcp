{-# LANGUAGE ScopedTypeVariables #-}

module SourceExplorer.Server
  ( runServer
  , app
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Pool (withResource)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.PostgreSQL.Simple (Connection)
import Network.HTTP.Types
import Network.Wai
import qualified Network.Wai.Handler.Warp as Warp
import Network.Wai.Handler.Warp (runSettings, setHost, setPort, defaultSettings)
import Network.Wai.Middleware.Cors
import SourceExplorer.Database
import SourceExplorer.Types

runServer :: AppConfig -> IO ()
runServer AppConfig {..} = do
  pool <- createDbPool (connectInfoFromConfig database)
  runMigrations pool "db"
  let ServerConfig {host = serverHost, port = serverPort, accessToken = token} = server
  let settings =
        setHost (fromStringHost (T.unpack serverHost)) $
          setPort serverPort defaultSettings
  putStrLn ("server listening on " <> T.unpack serverHost <> ":" <> show serverPort)
  runSettings settings (corsMiddleware (app token pool))

app :: Text -> DbPool -> Application
app token pool request respond =
  case (requestMethod request, pathInfo request) of
    ("GET", ["health"]) -> respond (jsonResponse status200 (object ["status" .= String "ok"]))
    ("GET", ["ready"]) -> authenticated request token respond $ ready pool respond
    ("GET", ["api", "repositories"]) -> authenticated request token respond $ db respond pool listRepositories
    ("GET", ["api", "repositories", repo, "branches"]) -> authenticated request token respond $ db respond pool (`listBranches` repo)
    ("GET", ["api", "repositories", repo, "commits"]) ->
      authenticated request token respond $
        db respond pool $ \conn -> listCommits conn repo (queryParam "branch" request) (intParam "limit" 100 request)
    ("GET", ["api", "repositories", repo, "commits", sha, "files"]) ->
      authenticated request token respond $
        db respond pool $ \conn -> listFiles conn repo sha (intParam "limit" 500 request)
    ("GET", ["api", "repositories", repo, "commits", sha, "files", "content"]) ->
      authenticated request token respond $
        case queryParam "path" request of
          Nothing -> respondError respond status400 "missing path query parameter"
          Just filePath -> do
            value <- withDb pool $ \conn -> getFileContent conn repo sha filePath
            maybe (respondError respond status404 "file not found") (respond . jsonResponse status200) value
    ("GET", ["api", "symbols"]) ->
      authenticated request token respond $
        db respond pool $ \conn ->
          searchSymbols
            conn
            (queryParam "repository" request)
            (queryParam "q" request)
            (queryParam "kind" request)
            (queryParam "language" request)
            (intParam "limit" 100 request)
    ("GET", ["api", "index-status"]) ->
      authenticated request token respond $
        db respond pool $ \conn -> listIndexStatus conn (queryParam "repository" request) (intParam "limit" 50 request)
    ("POST", ["mcp"]) -> authenticated request token respond $ handleMcp pool request respond
    _ -> respondError respond status404 "not found"

ready :: DbPool -> (Response -> IO ResponseReceived) -> IO ResponseReceived
ready pool respond = do
  result <- try (withDb pool (\conn -> listRepositories conn >> pure ())) :: IO (Either SomeException ())
  case result of
    Right () -> respondJson status200 (object ["status" .= String "ready"])
    Left err -> respondJson status503 (object ["status" .= String "not-ready", "error" .= show err])
  where
    respondJson status value = respond (jsonResponse status value)

db :: forall a. ToJSON a => (Response -> IO ResponseReceived) -> DbPool -> (Connection -> IO a) -> IO ResponseReceived
db respond pool action = do
  result <- try (withDb pool action) :: IO (Either SomeException a)
  case result of
    Right value -> respond (jsonResponse status200 value)
    Left err -> respond (jsonResponse status500 (object ["error" .= show err]))

handleMcp :: DbPool -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
handleMcp pool request respond = do
  body <- strictRequestBody request
  case eitherDecode body of
    Left err -> respondError respond status400 (T.pack err)
    Right mcpReq ->
      case methodName mcpReq of
        "tools/list" ->
          respondJson status200 $
            object
              [ "tools"
                  .= [ object ["name" .= String "list_repositories"]
                     , object ["name" .= String "list_branches"]
                     , object ["name" .= String "list_files"]
                     , object ["name" .= String "read_file"]
                     , object ["name" .= String "search_symbols"]
                     , object ["name" .= String "get_indexing_status"]
                     ]
              ]
        "list_repositories" -> db respond pool listRepositories
        "list_branches" ->
          case lookupText "repository" (params mcpReq) of
            Nothing -> respondError respond status400 "missing repository"
            Just repo -> db respond pool (`listBranches` repo)
        "list_files" ->
          case (lookupText "repository" (params mcpReq), lookupText "commit" (params mcpReq)) of
            (Just repo, Just sha) -> db respond pool $ \conn -> listFiles conn repo sha 100
            _ -> respondError respond status400 "missing repository or commit"
        "read_file" ->
          case (lookupText "repository" (params mcpReq), lookupText "commit" (params mcpReq), lookupText "path" (params mcpReq)) of
            (Just repo, Just sha, Just filePath) -> do
              value <- withDb pool $ \conn -> getFileContent conn repo sha filePath
              maybe (respondError respond status404 "file not found") (respondJson status200) value
            _ -> respondError respond status400 "missing repository, commit, or path"
        "search_symbols" ->
          db respond pool $ \conn ->
            searchSymbols
              conn
              (lookupText "repository" (params mcpReq))
              (lookupText "q" (params mcpReq))
              (lookupText "kind" (params mcpReq))
              (lookupText "language" (params mcpReq))
              50
        "get_indexing_status" ->
          db respond pool $ \conn -> listIndexStatus conn (lookupText "repository" (params mcpReq)) 20
        other -> respondError respond status404 ("unknown MCP method: " <> other)
  where
    respondJson status value = respond (jsonResponse status value)

data McpRequest = McpRequest
  { methodName :: Text
  , params :: Maybe Object
  }

instance FromJSON McpRequest where
  parseJSON = withObject "McpRequest" $ \o ->
    McpRequest <$> o .: "method" <*> o .:? "params"

lookupText :: Text -> Maybe Object -> Maybe Text
lookupText key maybeObj = do
  obj <- maybeObj
  case KM.lookup (Key.fromText key) obj of
    Just (String value) -> Just value
    Just value -> Just (TE.decodeUtf8 (LBS.toStrict (encode value)))
    Nothing -> Nothing

authenticated :: Request -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived -> IO ResponseReceived
authenticated request token respond action =
  if requestMethod request == "OPTIONS" || bearerToken request == Just token
    then action
    else respond (jsonResponse status401 (object ["error" .= String "unauthorized"]))

bearerToken :: Request -> Maybe Text
bearerToken request = do
  raw <- lookup hAuthorization (requestHeaders request)
  let prefix = "Bearer "
  if prefix `BS.isPrefixOf` raw
    then Just (TE.decodeUtf8 (BS.drop (BS.length prefix) raw))
    else Nothing

queryParam :: Text -> Request -> Maybe Text
queryParam key request =
  lookup (TE.encodeUtf8 key) (queryString request) >>= fmap TE.decodeUtf8

intParam :: Text -> Int -> Request -> Int
intParam key fallback request =
  fromMaybe fallback $ do
    raw <- queryParam key request
    case reads (T.unpack raw) of
      [(value, "")] -> Just value
      _ -> Nothing

respondError :: (Response -> IO ResponseReceived) -> Status -> Text -> IO ResponseReceived
respondError respond status message =
  respond (jsonResponse status (object ["error" .= message]))

jsonResponse :: ToJSON a => Status -> a -> Response
jsonResponse status value =
  responseLBS
    status
    [(hContentType, "application/json; charset=utf-8")]
    (encode value)

corsMiddleware :: Middleware
corsMiddleware =
  cors $
    const $
      Just
        simpleCorsResourcePolicy
          { corsRequestHeaders = [hAuthorization, hContentType]
          , corsMethods = ["GET", "POST", "OPTIONS"]
          }

fromStringHost :: String -> Warp.HostPreference
fromStringHost = fromString
