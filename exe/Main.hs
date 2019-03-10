{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}

import Database.EventStore (connect, defaultSettings, Settings(s_defaultUserCredentials), credentials, ConnectionType(Static), StreamId(StreamName), ResolveLink(ResolveLink, NoResolveLink), ResolvedEvent(resolvedEventRecord), RecordedEvent(recordedEventNumber, recordedEventId, recordedEventType, recordedEventData, recordedEventStreamId), positionEnd, streamEnd, s_loggerType, s_loggerFilter, LogLevel(LevelDebug), LoggerFilter(LoggerLevel), LogType(LogStderr), keepRetrying, s_retry, subscribe, nextEvent, Connection, readEventsBackward, ReadResult(ReadSuccess, ReadSuccess, ReadNoStream, ReadStreamDeleted, ReadNotModified, ReadError, ReadAccessDenied), Slice(Slice, SliceEndOfStream), subscribeFrom, eventNumber, Subscription, EventNumber, sendEvent, anyVersion, createEvent, EventType(UserDefined), withJson, withBinary, Event)
import Numeric.Natural (Natural)
import Data.Int (Int32)
import Data.ByteString.Lazy (ByteString, hGetContents)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Monoid ((<>))
import Control.Monad (forever, when, mapM_, void)
import Data.Aeson (decode, Value, FromJSON(parseJSON), withObject, (.:), (.:?))
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString as BS
import Data.ByteString.Lazy (toStrict, fromStrict)
import Options.Applicative (ParserInfo, Parser, subparser, command, info, progDesc, helper, (<**>), fullDesc, header, execParser, strOption, long, metavar, help, argument, str, showDefault, value, option, switch, auto, short, optional)
import Streams (getActiveStreams, getNewStreams, getModifiedStreams)
import Control.Concurrent.Async (wait)
import GHC.IO.Handle.FD (stdin)
import GHC.IO.Handle (hSetBinaryMode)
import qualified Data.ByteString.Streaming as BSS
import qualified Data.ByteString.Streaming.Aeson as AES
import Streaming.Prelude (Of((:>)), mapped)
import qualified Streaming.Prelude as SP
import Streaming (iterT, maps, Stream)
import Data.Word (Word8)

data SubscribeArgs = SubscribeArgs { subscribeArgsStreamName :: Text, subscribeArgsFromEvent :: Maybe Natural, subscribeArgsChunkSize :: Maybe Int32 }
data ListStreamsArgs = ListStreamsArgs { listStreamArgsCount :: Int, listStreamsShowAll :: Bool, listStreamsUpdated :: Bool }
data SendEventArgs = SendEventArgs { sendEventArgsStreamName :: Maybe Text, sendEventArgsEventType :: Maybe Text, sendEventArgsPayload :: Maybe ByteString, sendEventArgsBinary :: Bool, sendEventArgsOutputTemplate :: Bool }
data SendEventsArgs = SendEventsArgs { sendEventsArgsStreamName :: Maybe Text, sendEventsArgsEventType :: Maybe Text, sendEventsArgsBinary :: Maybe Word8 }

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
     <$> optional (strOption
          ( short 's'
         <> long "stream"
         <> metavar "STREAM_NAME"
         <> help "Name of stream to send the event to" ))
     <*> optional (strOption
          ( short 't'
         <> long "type"
         <> metavar "EVENT_TYPE"
         <> help "Event type" ))
     <*> optional (strOption
          ( short 'p'
         <> long "payload"
         <> metavar "DATA"
         <> help "Event data passed as argument instead of STDIN" ))
     <*> switch
          ( short 'b'
         <> long "binary"
         <> help "Payload is binary data" )
     <*> switch
          ( long "output-template"
         <> help "Output a template of an expected JSON input"))

sendEventsParser :: Parser CmdArgs
sendEventsParser = SendEvents <$> (SendEventsArgs
     <$> optional (strOption
          ( short 's'
         <> long "stream"
         <> metavar "STREAM_NAME"
         <> help "Name of stream to send the event to" ))
     <*> optional (strOption
          ( short 't'
         <> long "type"
         <> metavar "EVENT_TYPE"
         <> help "Event type" ))
     <*> optional (option auto
          ( short 'b'
         <> long "binary"
         <> help "Signals that inputs will be binary data and the argument whould be used as separator (currently a number is interpreted as ASCII value - use 10 as newline - TODO accept multibyte bytestrings)" )))

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
runSendEvent conn args | sendEventArgsOutputTemplate args = putStrLn (T.unpack eventTemplate)
runSendEvent conn args | otherwise = do

    -- 1. fetch input ByteString
    d <- case sendEventArgsPayload args of
        Just p -> pure p
        Nothing -> readPayloadStdIn

    -- 2. create an event from the input
    let (stream, evt) = case sendEventArgsBinary args of
                                True -> case sendEventArgsEventType args of
                                              Nothing -> error "Event type not specified"
                                              Just evtType ->
                                                  let evt = createEvent
                                                              (UserDefined $ evtType)
                                                              Nothing
                                                              (withBinary $ toStrict d)
                                                  in (Nothing, evt)
                                False ->
                                      case decode d of
                                          Nothing -> error "Invalid input (couldn't parse JSON see --output-template)"
                                          Just (d :: InputEvent) ->
                                              let evtType = case (sendEventArgsEventType args, inputEventEventName d) of
                                                                    (Nothing, Nothing) -> error "Event type not specified"
                                                                    (_, Just x) -> x
                                                                    (Just x, Nothing) -> x
                                                  evt = createEvent
                                                            (UserDefined evtType)
                                                            Nothing
                                                            (withJson $ inputEventData d)
                                              in (inputEventStream d, evt)

    let sname = case (defaultStream, stream) of
                (Nothing, Nothing) -> error "Stream name not specified"
                (_, Just x) -> x
                (Just x, Nothing) -> x

    -- 3. send the event
    send sname evt

    where
        defaultStream = sendEventArgsStreamName args

        send :: Text -> Event -> IO ()
        send stream evt = do
            print =<< wait =<< sendEvent
                                  conn
                                  (StreamName stream)
                                  anyVersion
                                  evt
                                  Nothing

data InputEvent = InputEvent { inputEventStream :: Maybe Text, inputEventEventName :: Maybe Text, inputEventData :: Value }

instance FromJSON InputEvent where
    parseJSON = withObject "Event" $ \v -> InputEvent
        <$> v .:? "stream"
        <*> v .:? "type"
        <*> v .:  "payload"

runSendEvents :: Connection -> SendEventsArgs -> IO ()
runSendEvents conn args = do
    hSetBinaryMode stdin True
    let input = BSS.hGetContents stdin

    case sendEventsArgsBinary args of
        Just delimiter -> do
            let stream = mapped BSS.toStrict $ BSS.denull $ BSS.splitWith (==delimiter) $ input
            let (Just sname) = sendEventsArgsStreamName args
            let (Just evtName) = sendEventsArgsEventType args
            let mkEvt payload = createEvent
                                    (UserDefined evtName)
                                    Nothing
                                    (withBinary payload)
            void $ SP.mapM_ (send sname . mkEvt) stream
        Nothing -> do
            let stream = AES.decoded input
            void $ SP.mapM_ handleRecord stream

    where
        evtNm dft (Just x) = x
        evtNm (Just x) Nothing = x
        evtNm Nothing Nothing = error "Event type not specified"

        evtStrm dft (Just x) = x
        evtStrm (Just x) Nothing = x
        evtStrm Nothing Nothing = error "Event stream not specified"

        handleRecord :: InputEvent -> IO ()
        handleRecord evt = send (evtStrm (sendEventsArgsStreamName args) (inputEventStream evt)) $ createEvent
            (UserDefined $ evtNm (sendEventsArgsEventType args) (inputEventEventName evt))
            Nothing
            (withJson $ inputEventData evt)

        send streamName evt = print =<< wait =<< sendEvent
                              conn
                              (StreamName $ streamName)
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

eventTemplate :: Text
eventTemplate = T.intercalate "\n"
    [ "{"
    ,  "  \"stream\": \"<stream_name>\","
    ,  "  \"type\": \"<event_type>\","
    ,  "  \"payload\": {"
    ,  "    \"prop1\": \"val1\","
    ,  "    \"prop2\": \"val2\""
    ,  "  }"
    ,  "}"
    ]

readPayloadStdIn :: IO ByteString
readPayloadStdIn = do
    hSetBinaryMode stdin True
    hGetContents stdin
