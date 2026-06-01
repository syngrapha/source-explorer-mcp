module SourceExplorer.Hash
  ( sha256Text
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T

sha256Text :: BS.ByteString -> Text
sha256Text bytes =
  T.pack (show (hash bytes :: Digest SHA256))
