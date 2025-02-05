module Moskstraumen.Runtime2 (module Moskstraumen.Runtime2) where

import qualified Data.ByteString.Char8 as BS8
import qualified Data.Text.IO as Text
import Data.Time
import System.IO
import System.Timeout (timeout)

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.Prelude

------------------------------------------------------------------------

type Microseconds = Int

data Runtime m = Runtime
  { receive :: m [Message]
  , send :: Message -> m ()
  , log :: Text -> m ()
  , timeout :: Microseconds -> m [Message] -> m (Maybe [Message])
  , getCurrentTime :: m UTCTime
  , shutdown :: m ()
  }

consoleRuntime :: Codec -> IO (Runtime IO)
consoleRuntime codec = do
  hSetBuffering stdin LineBuffering
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  return
    Runtime
      { receive = consoleReceive
      , send = consoleSend
      , log = \text -> Text.hPutStrLn stderr text
      , -- NOTE: `timeout 0` times out immediately while negative values
        -- don't, hence the `max 0`.
        timeout = \micros -> System.Timeout.timeout (max 0 micros)
      , getCurrentTime = Data.Time.getCurrentTime
      , shutdown = return ()
      }
  where
    consoleReceive :: IO [Message]
    consoleReceive = do
      -- XXX: Batch and read several lines?
      line <- BS8.hGetLine stdin
      if BS8.null line
        then return []
        else do
          BS8.hPutStrLn stderr ("recieve: " <> line)
          case codec.decode line of
            Right message -> return [message]
            Left err ->
              -- XXX: Log and keep stats instead of error.
              error
                $ "consoleReceive: failed to decode message: "
                ++ show err
                ++ "\nline: "
                ++ show line

    consoleSend :: Message -> IO ()
    consoleSend message = do
      BS8.hPutStrLn stderr ("send: " <> codec.encode message)
      BS8.hPutStrLn stdout (codec.encode message)
