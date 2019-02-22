{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

import Database.EventStore (connect, defaultSettings, Settings(s_defaultUserCredentials), credentials, ConnectionType(Static), StreamId(StreamName), ResolveLink(ResolveLink), ResolvedEvent(resolvedEventRecord), RecordedEvent(recordedEventId, recordedEventType, recordedEventData), streamEnd, s_loggerType, s_loggerFilter, LogLevel(LevelDebug), LoggerFilter(LoggerLevel), LogType(LogStderr), keepRetrying, s_retry, subscribe, nextEvent, Connection)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Monoid ((<>))
import Control.Monad (forever, when)
import Data.Aeson (decode, Value)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Maybe (fromMaybe)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Options.Applicative (ParserInfo, Parser, subparser, command, info, progDesc, helper, (<**>), fullDesc, header, execParser, strOption, long, metavar, help, argument, str, showDefault, value, option, switch, auto, short)

data SubscribeArgs = SubscribeArgs { streamName :: Text }

data CmdArgs = Subscribe SubscribeArgs

subscribeParser :: Parser CmdArgs
subscribeParser = Subscribe <$> SubscribeArgs <$> argument str
          ( metavar "STREAM_NAME"
         <> help "Name of stream to subscribe to" )

cmdArgsParser :: Parser CmdArgs
cmdArgsParser = subparser (command "subscribe" (info subscribeParser (progDesc "Subscribe to a stream")))

data Opts
    = Opts
    { cmdArgs :: CmdArgs
    , host :: String
    , port :: Int
    , pretty :: Bool
    , verbose :: Bool
    }

optsParser :: ParserInfo Opts
optsParser
    = let opts
              = Opts
              <$> cmdArgsParser
              <*> (strOption
                      ( long "host"
                     <> metavar "HOST_NAME"
                     <> showDefault
                     <> value "localhost"
                     <> help "Server hostname or IP"))
              <*> (option auto
                      ( long "port"
                     <> metavar "PORT"
                     <> showDefault
                     <> value 1113
                     <> help "Server port number"))
              <*> (switch
                      ( long "pretty"
                     <> help "Pretty print JSON"))
              <*> (switch
                      ( short 'v'
                     <> long "verbose"
                     <> help "Print steps taken"))

      in info
            (opts <**> helper)
            (  fullDesc
            <> progDesc "CLI utility to interact with Event Store"
            <> header "event-store-ctl - Event Store CLI")

main :: IO ()
main = do
    opts <- execParser optsParser

    let h = host opts
        p = port opts
    when (verbose opts) $ putStrLn $ "Connecting to: " <> h <> ":" <> show p
    conn <- connect
        (defaultSettings
            { s_defaultUserCredentials = Just (credentials "admin" "changeit")
            --, s_retry = keepRetrying
            --, s_loggerType = LogStderr 0
            --, s_loggerFilter = LoggerLevel LevelDebug
            })
        (Static h p)

    case cmdArgs opts of
        Subscribe args -> runSubscribe conn (verbose opts) (pretty opts) args


runSubscribe :: Connection -> Bool -> Bool -> SubscribeArgs -> IO ()
runSubscribe conn verbse ptty args = do

    sub <- subscribe
              conn
              (StreamName (streamName args))
              ResolveLink
              Nothing

    let handleEvent (evt :: ResolvedEvent) = do
        let (Just re) = resolvedEventRecord evt
        putStrLn $ "Event<" <> (T.unpack $ recordedEventType $ re) <> "> #" <> (show $ recordedEventId re)
        logRecordedEvent ptty re
        putStrLn $ ""

    when verbse $ putStrLn $ "Subscribing to stream: " <> (T.unpack $ streamName args)
    _ <- forever $ nextEvent sub >>= handleEvent
    pure ()


logRecordedEvent :: Bool -> RecordedEvent -> IO ()
logRecordedEvent ptty re = if ptty then logPretty else logCondensed
    where
        logPretty = do
            let d = recordedEventData $ re
                j = decode (fromStrict d) :: Maybe Value
            putStrLn $ fromMaybe "<invalid json>" $ (T.unpack . decodeUtf8 . toStrict . encodePretty) <$> j

        logCondensed = do
            putStrLn $ T.unpack $ decodeUtf8 $ recordedEventData $ re

