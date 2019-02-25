{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}

import Database.EventStore (connect, defaultSettings, Settings(s_defaultUserCredentials), credentials, ConnectionType(Static), StreamId(StreamName), ResolveLink(ResolveLink, NoResolveLink), ResolvedEvent(resolvedEventRecord), RecordedEvent(recordedEventNumber, recordedEventId, recordedEventType, recordedEventData, recordedEventStreamId), positionEnd, streamEnd, s_loggerType, s_loggerFilter, LogLevel(LevelDebug), LoggerFilter(LoggerLevel), LogType(LogStderr), keepRetrying, s_retry, subscribe, nextEvent, Connection, readEventsBackward, ReadResult(ReadSuccess, ReadSuccess, ReadNoStream, ReadStreamDeleted, ReadNotModified, ReadError, ReadAccessDenied), Slice(Slice, SliceEndOfStream))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Monoid ((<>))
import Control.Monad (forever, when, mapM_)
import Data.Aeson (decode, Value)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Maybe (fromMaybe)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Options.Applicative (ParserInfo, Parser, subparser, command, info, progDesc, helper, (<**>), fullDesc, header, execParser, strOption, long, metavar, help, argument, str, showDefault, value, option, switch, auto, short)
import Streams (getActiveStreams, getNewStreams, getModifiedStreams)


data SubscribeArgs = SubscribeArgs { streamName :: Text }
data WhichStreams = AllStreams | NewStreams | UpdatedStreams
data ListStreamsArgs = ListStreamsArgs { count :: Int, showAll :: Bool, updated :: Bool }

data CmdArgs
    = Subscribe SubscribeArgs
    | ListStreams ListStreamsArgs

subscribeParser :: Parser CmdArgs
subscribeParser = Subscribe <$> SubscribeArgs <$> argument str
          ( metavar "STREAM_NAME"
         <> help "Name of stream to subscribe to" )

listStreamsParser :: Parser CmdArgs
listStreamsParser = ListStreams <$> (ListStreamsArgs
     <$> option auto
          ( short 'N'
         <> metavar "NUMBER"
         <> showDefault
         <> value 20
         <> help "Maximum number of stream names to output" )
     <*> switch
          ( short 'a'
         <> long "all"
         <> help "Display all streams, not just the ones that were recently created" )
     <*> switch
          ( short 'u'
         <> long "updated"
         <> help "Display updated streams, i.e. those with an event with event number > 0" ))

cmdArgsParser :: Parser CmdArgs
cmdArgsParser = subparser
    (  (command "subscribe" (info (helper <*> subscribeParser) (progDesc "Subscribe to a stream")))
    <> (command "list-streams" (info (helper <*> listStreamsParser) (progDesc "List most recent streams"))))

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
        ListStreams args -> runListStreams conn args


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

runListStreams :: Connection -> ListStreamsArgs -> IO ()
runListStreams conn args = case (showAll args, updated args) of
    (True, True)   -> error "--all and --updated cannot be supplied together"
    (True, False)  -> getActiveStreams conn (count args)   >>= mapM_ (putStrLn . T.unpack)
    (False, True)  -> getModifiedStreams conn (count args) >>= mapM_ (putStrLn . T.unpack)
    (False, False) -> getNewStreams conn (count args)      >>= mapM_ (putStrLn . T.unpack)

logRecordedEvent :: Bool -> RecordedEvent -> IO ()
logRecordedEvent ptty re = if ptty then logPretty else logCondensed
    where
        logPretty = do
            let d = recordedEventData $ re
                j = decode (fromStrict d) :: Maybe Value
            putStrLn $ fromMaybe "<invalid json>" $ (T.unpack . decodeUtf8 . toStrict . encodePretty) <$> j

        logCondensed = do
            putStrLn $ T.unpack $ decodeUtf8 $ recordedEventData $ re

