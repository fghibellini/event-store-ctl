{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}

import Database.EventStore (connect, defaultSettings, Settings(s_defaultUserCredentials), credentials, ConnectionType(Static), StreamId(StreamName), ResolveLink(ResolveLink, NoResolveLink), ResolvedEvent(resolvedEventRecord), RecordedEvent(recordedEventNumber, recordedEventId, recordedEventType, recordedEventData, recordedEventStreamId), positionEnd, streamEnd, s_loggerType, s_loggerFilter, LogLevel(LevelDebug), LoggerFilter(LoggerLevel), LogType(LogStderr), keepRetrying, s_retry, subscribe, nextEvent, Connection, readEventsBackward, ReadResult(ReadSuccess, ReadSuccess, ReadNoStream, ReadStreamDeleted, ReadNotModified, ReadError, ReadAccessDenied), Slice(Slice, SliceEndOfStream), subscribeFrom, eventNumber, Subscription, EventNumber, sendEvent, anyVersion, createEvent, EventType(UserDefined), withJson, withBinary)
import Numeric.Natural (Natural)
import Data.Int (Int32)
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Monoid ((<>))
import Control.Monad (forever, when, mapM_, void)
import Data.Aeson (decode, Value)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Maybe (fromMaybe)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Options.Applicative (ParserInfo, Parser, subparser, command, info, progDesc, helper, (<**>), fullDesc, header, execParser, strOption, long, metavar, help, argument, str, showDefault, value, option, switch, auto, short, optional)
import Streams (getActiveStreams, getNewStreams, getModifiedStreams)
import Control.Concurrent.Async (wait)
import GHC.IO.Handle.FD (stdin)
import GHC.IO.Handle (hSetBinaryMode)
import qualified Data.ByteString.Streaming as BSS
import qualified Data.ByteString.Streaming.Aeson as AES
--import Data.Functor.Of (Of((:>)))
import Streaming.Prelude (Of((:>)))
import Streaming (iterT)

data SubscribeArgs = SubscribeArgs { subscribeArgsStreamName :: Text, subscribeArgsFromEvent :: Maybe Natural, subscribeArgsChunkSize :: Maybe Int32 }
data ListStreamsArgs = ListStreamsArgs { listStreamArgsCount :: Int, listStreamsShowAll :: Bool, listStreamsUpdated :: Bool }
data SendEventArgs = SendEventArgs { sendEventArgsStreamName :: Text, sendEventArgsEventType :: Text, sendEventArgsJsonData :: Maybe ByteString, sendEventArgsBinaryData :: Maybe ByteString }
data SendEventsArgs = SendEventsArgs

data CmdArgs
    = Subscribe SubscribeArgs
    | ListStreams ListStreamsArgs
    | SendEvent SendEventArgs
    | SendEvents SendEventsArgs

subscribeParser :: Parser CmdArgs
subscribeParser = Subscribe <$> (SubscribeArgs
      <$> argument str
          ( metavar "STREAM_NAME"
         <> help "Name of stream to subscribe to" )
      <*> (optional $ option auto
          ( short 'e'
         <> long "from-event"
         <> metavar "EVENT_NUMBER"
         <> help "this will create a catch-up subscription starting from the event-number passed" ))
      <*> (optional $ option auto
          ( short 'c'
         <> long "chunk-size"
         <> metavar "EVENT_COUNT"
         <> help "how many events to fetch at a time" )))

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
         <> long "listStreamsUpdated"
         <> help "Display listStreamsUpdated streams, i.e. those with an event with event number > 0" ))

createEventParser :: Parser CmdArgs
createEventParser = SendEvent <$> (SendEventArgs
     <$> argument str
          ( metavar "STREAM_NAME"
         <> help "Name of stream to send the event to" )
     <*> argument str
          ( metavar "EVENT_TYPE"
         <> help "Event type" )
     <*> optional (strOption
          ( short 'j'
         <> long "json-data"
         <> metavar "JSON"
         <> help "Event data in JSON format" ))
     <*> optional (strOption
          ( short 'b'
         <> long "binary-data"
         <> metavar "DATA"
         <> help "Event data" )))

sendEventsParser :: Parser CmdArgs
sendEventsParser = pure $ SendEvents SendEventsArgs

cmdArgsParser :: Parser CmdArgs
cmdArgsParser = subparser
    (  (command "subscribe" (info (helper <*> subscribeParser) (progDesc "Subscribe to a stream")))
    <> (command "list-streams" (info (helper <*> listStreamsParser) (progDesc "List most recent streams")))
    <> (command "send-event" (info (helper <*> createEventParser) (progDesc "Creates an event")))
    <> (command "send-events" (info (helper <*> sendEventsParser) (progDesc "Sends events incrementally"))))

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
        SendEvent args -> runSendEvent conn args
        SendEvents args -> runSendEvents conn args


runSubscribe :: Connection -> Bool -> Bool -> SubscribeArgs -> IO ()
runSubscribe conn verbse ptty args =

    case subscribeArgsFromEvent args of
        Just e -> withSub =<< subscribeFrom
              conn
              (StreamName (subscribeArgsStreamName args))
              ResolveLink
              (Just $ eventNumber e)
              (subscribeArgsChunkSize args)
              Nothing
        Nothing -> withSub =<< subscribe
              conn
              (StreamName (subscribeArgsStreamName args))
              ResolveLink
              Nothing

    where
        withSub :: Subscription s => s -> IO ()
        withSub sub = do
            let handleEvent (evt :: ResolvedEvent) = do
                let (Just re) = resolvedEventRecord evt
                putStrLn $ "Event<" <> (T.unpack $ recordedEventType $ re) <> "> #" <> (show $ recordedEventId re)
                logRecordedEvent ptty re
                putStrLn $ ""

            when verbse $ putStrLn $ "Subscribing to stream: " <> (T.unpack $ subscribeArgsStreamName args)
            void $ forever $ nextEvent sub >>= handleEvent

runListStreams :: Connection -> ListStreamsArgs -> IO ()
runListStreams conn args = case (listStreamsShowAll args, listStreamsUpdated args) of
    (True, True)   -> error "--all and --listStreamsUpdated cannot be supplied together"
    (True, False)  -> getActiveStreams conn (listStreamArgsCount args)   >>= mapM_ (putStrLn . T.unpack)
    (False, True)  -> getModifiedStreams conn (listStreamArgsCount args) >>= mapM_ (putStrLn . T.unpack)
    (False, False) -> getNewStreams conn (listStreamArgsCount args)      >>= mapM_ (putStrLn . T.unpack)

runSendEvent :: Connection -> SendEventArgs -> IO ()
runSendEvent conn args = do
    case (sendEventArgsJsonData args, sendEventArgsBinaryData args) of
        (Just _, Just _) -> error "-b and -j cannot be supplied together"
        (Nothing, Nothing) -> error "Either -b or -j must be supplied"
        (Just j, Nothing) ->
              case decode j of
                  Nothing -> error "Invalid json data"
                  Just (d :: Value) -> do
                      send $ createEvent
                                    (UserDefined $ sendEventArgsEventType args)
                                    Nothing
                                    (withJson d)
        (Nothing, Just d) ->
              send $ createEvent
                            (UserDefined $ sendEventArgsEventType args)
                            Nothing
                            (withBinary $ toStrict d)


    where
        send evt = print =<< wait =<< sendEvent
                              conn
                              (StreamName $ sendEventArgsStreamName args)
                              anyVersion
                              evt
                              Nothing

runSendEvents :: Connection -> SendEventsArgs -> IO ()
runSendEvents conn args = do
    hSetBinaryMode stdin True
    let input = BSS.hGetContents stdin
    let stream = AES.decoded input
    void $ iterT (\((x :: Value) :> m) ->
        (send $ createEvent
            (UserDefined $ "streamed-event")
            Nothing
            (withJson x)) >> m) stream

    where
        send evt = print =<< wait =<< sendEvent
                              conn
                              (StreamName $ "filippo-streaming-test")
                              anyVersion
                              evt
                              Nothing

logRecordedEvent :: Bool -> RecordedEvent -> IO ()
logRecordedEvent ptty re = if ptty then logPretty else logCondensed
    where
        logPretty = do
            let d = recordedEventData $ re
                j = decode (fromStrict d) :: Maybe Value
            putStrLn $ fromMaybe "<invalid json>" $ (T.unpack . decodeUtf8 . toStrict . encodePretty) <$> j

        logCondensed = do
            putStrLn $ T.unpack $ decodeUtf8 $ recordedEventData $ re

