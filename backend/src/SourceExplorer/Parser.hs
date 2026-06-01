module SourceExplorer.Parser
  ( ParsedSymbol (..)
  , detectLanguage
  , parseSymbols
  , parserName
  , parserVersion
  ) where

import Data.Char (isAlphaNum)
import Data.List (find)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (takeExtension)

data ParsedSymbol = ParsedSymbol
  { symbolName :: Text
  , symbolKind :: Text
  , symbolContainer :: Maybe Text
  , symbolStartLine :: Int
  , symbolStartColumn :: Int
  , symbolEndLine :: Int
  , symbolEndColumn :: Int
  , symbolSnippet :: Text
  }
  deriving stock (Show, Eq)

parserName :: Text
parserName = "source-explorer-lightweight"

parserVersion :: Text
parserVersion = "1"

detectLanguage :: FilePath -> Maybe Text
detectLanguage path =
  case takeExtension path of
    ".cs" -> Just "csharp"
    ".js" -> Just "javascript"
    ".jsx" -> Just "javascript"
    ".ts" -> Just "typescript"
    ".tsx" -> Just "typescript"
    _ -> Nothing

parseSymbols :: Text -> Text -> [ParsedSymbol]
parseSymbols language content =
  concatMap parseLine (zip [1 ..] (T.lines content))
  where
    parseLine (lineNo, line) =
      case language of
        "csharp" -> parseCSharp lineNo line
        "javascript" -> parseJsTs lineNo line
        "typescript" -> parseJsTs lineNo line
        _ -> []

parseCSharp :: Int -> Text -> [ParsedSymbol]
parseCSharp lineNo line =
  mapMaybe (matchPrefix lineNo line)
    [ ("class ", "class")
    , ("interface ", "interface")
    , ("enum ", "enum")
    , ("struct ", "type")
    , ("record ", "type")
    ]
    <> maybeToList (parseCSharpMethod lineNo line)

parseJsTs :: Int -> Text -> [ParsedSymbol]
parseJsTs lineNo line =
  mapMaybe (matchPrefix lineNo line)
    [ ("class ", "class")
    , ("interface ", "interface")
    , ("type ", "type")
    , ("enum ", "enum")
    , ("const ", "constant")
    , ("let ", "variable")
    , ("var ", "variable")
    ]
    <> mapMaybe (matchPrefix lineNo cleaned)
      [ ("export class ", "class")
      , ("export interface ", "interface")
      , ("export type ", "type")
      , ("export enum ", "enum")
      , ("export const ", "constant")
      , ("export function ", "function")
      , ("function ", "function")
      ]
    <> maybeToList (parseArrowFunction lineNo line)
  where
    cleaned = T.strip line

matchPrefix :: Int -> Text -> (Text, Text) -> Maybe ParsedSymbol
matchPrefix lineNo line (prefix, kind) =
  let stripped = T.stripStart line
      leading = T.length line - T.length stripped
   in if prefix `T.isPrefixOf` stripped
        then mkSymbol lineNo line kind leading prefix stripped
        else Nothing

mkSymbol :: Int -> Text -> Text -> Int -> Text -> Text -> Maybe ParsedSymbol
mkSymbol lineNo original kind leading prefix stripped =
  case T.takeWhile isIdentChar (T.dropWhile (not . isIdentStart) (T.drop (T.length prefix) stripped)) of
    "" -> Nothing
    name ->
      let startCol = leading + fromMaybe 0 (T.findIndex (== T.head name) stripped) + 1
       in Just ParsedSymbol
            { symbolName = name
            , symbolKind = kind
            , symbolContainer = Nothing
            , symbolStartLine = lineNo
            , symbolStartColumn = startCol
            , symbolEndLine = lineNo
            , symbolEndColumn = startCol + T.length name
            , symbolSnippet = T.strip original
            }

parseArrowFunction :: Int -> Text -> Maybe ParsedSymbol
parseArrowFunction lineNo line =
  let stripped = T.stripStart line
      leading = T.length line - T.length stripped
      prefixes = ["const ", "let ", "var "]
   in do
        prefix <- find (`T.isPrefixOf` stripped) prefixes
        let rest = T.drop (T.length prefix) stripped
            name = T.takeWhile isIdentChar rest
        if T.null name || not ("=>" `T.isInfixOf` rest)
          then Nothing
          else
            let startCol = leading + T.length prefix + 1
             in Just ParsedSymbol
                  { symbolName = name
                  , symbolKind = "function"
                  , symbolContainer = Nothing
                  , symbolStartLine = lineNo
                  , symbolStartColumn = startCol
                  , symbolEndLine = lineNo
                  , symbolEndColumn = startCol + T.length name
                  , symbolSnippet = T.strip line
                  }

parseCSharpMethod :: Int -> Text -> Maybe ParsedSymbol
parseCSharpMethod lineNo line =
  let stripped = T.strip line
   in if "(" `T.isInfixOf` stripped
        && ")" `T.isInfixOf` stripped
        && "=>" `T.isInfixOf` stripped || "{" `T.isSuffixOf` stripped
        && notAnyPrefix ["if ", "for ", "foreach ", "while ", "switch ", "catch "] stripped
        then
          case reverse (T.words (T.takeWhile (/= '(') stripped)) of
            name : _ | T.all isIdentChar name ->
              let startCol = fromMaybe 0 (T.findIndex (== T.head name) line) + 1
               in Just ParsedSymbol
                    { symbolName = name
                    , symbolKind = "method"
                    , symbolContainer = Nothing
                    , symbolStartLine = lineNo
                    , symbolStartColumn = startCol
                    , symbolEndLine = lineNo
                    , symbolEndColumn = startCol + T.length name
                    , symbolSnippet = stripped
                    }
            _ -> Nothing
        else Nothing

notAnyPrefix :: [Text] -> Text -> Bool
notAnyPrefix prefixes value = not (any (`T.isPrefixOf` value) prefixes)

isIdentStart :: Char -> Bool
isIdentStart c = c == '_' || c == '$' || c == '@' || c `elem` ['A' .. 'Z'] || c `elem` ['a' .. 'z']

isIdentChar :: Char -> Bool
isIdentChar c = isIdentStart c || isAlphaNum c

maybeToList :: Maybe a -> [a]
maybeToList Nothing = []
maybeToList (Just x) = [x]

fromMaybe :: a -> Maybe a -> a
fromMaybe x Nothing = x
fromMaybe _ (Just y) = y
