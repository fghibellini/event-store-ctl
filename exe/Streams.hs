
module Streams (getActiveStreams, getModifiedStreams, getNewStreams) where

import Data.Text (Text)
import Database.EventStore (Connection, readEventsBackward, positionEnd, ResolveLink(ResolveLink), StreamId(All), RecordedEvent(recordedEventNumber, recordedEventStreamId), Slice(Slice, SliceEndOfStream), resolvedEventRecord)
import Control.Concurrent.Async (wait)
import Data.List (nub)
import Data.Maybe (catMaybes)


-- | Get streams on which any event was recently published.
-- Recently means in the last 4095 events.
-- TODO paginate until n elements are found or end of stream is reached.
getActiveStreams :: Connection -> Int -> IO [Text]
getActiveStreams conn n = (take n . f) <$> (wait =<< readEventsBackward conn All positionEnd 4095 ResolveLink Nothing)
    where
        f (Slice evts _) = (streamIds . recordedEvents) evts
        f (SliceEndOfStream) = []

        recordedEvents = catMaybes . fmap resolvedEventRecord

        streamIds = nub . fmap recordedEventStreamId

-- | Get streams which were recently created.
-- Recently means in the last 4095 events.
-- TODO paginate until n elements are found or end of stream is reached.
getNewStreams :: Connection -> Int -> IO [Text]
getNewStreams conn n = (take n . f) <$> (wait =<< readEventsBackward conn All positionEnd 4095 ResolveLink Nothing)
    where
        f (Slice evts _) = (streamIds . nonFirst . recordedEvents) evts
        f (SliceEndOfStream) = []

        recordedEvents = catMaybes . fmap resolvedEventRecord

        nonFirst = filter ((== 0) . recordedEventNumber)

        streamIds = nub . fmap recordedEventStreamId

-- | Get streams on which at least one update was recently published.
-- Recently means in the last 4095 events.
-- Update means event with event-number > 0.
-- TODO paginate until n elements are found or end of stream is reached.
getModifiedStreams :: Connection -> Int -> IO [Text]
getModifiedStreams conn n = (take n . f) <$> (wait =<< readEventsBackward conn All positionEnd 4095 ResolveLink Nothing)
    where
        f (Slice evts _) = (streamIds . nonFirst . recordedEvents) evts
        f (SliceEndOfStream) = []

        recordedEvents = catMaybes . fmap resolvedEventRecord

        nonFirst = filter ((/= 0) . recordedEventNumber)

        streamIds = nub . fmap recordedEventStreamId

