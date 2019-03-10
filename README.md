
<div align="center">
  <img src="https://eventstore.org/images/ouro-full.svg" width="100">
</div>

&nbsp;
&nbsp;
&nbsp;

```
event-store-ctl - Event Store CLI

Usage: event-store-ctl COMMAND [--host HOST_NAME] [--port PORT] [--pretty]
                       [-v|--verbose]
  CLI utility to interact with Event Store

Available options:
  --host HOST_NAME         Server hostname or IP (default: "localhost")
  --port PORT              Server port number (default: 1113)
  --pretty                 Pretty print JSON
  -v,--verbose             Print steps taken
  -h,--help                Show this help text

Available commands:
  subscribe                Subscribe to a stream
  list-streams             List most recent streams
  send-event               Creates an event
  send-events              Sends events incrementally
```

## Commands

### `subscribe`

```
Usage: event-store-ctl subscribe STREAM_NAME (-e|--from-event EVENT_NUMBER)
                                 (-c|--chunk-size EVENT_COUNT)
  Subscribe to a stream

Available options:
  -h,--help                Show this help text
  STREAM_NAME              Name of stream to subscribe to
  -e,--from-event EVENT_NUMBER
                           this will create a catch-up subscription starting
                           from the event-number passed
  -c,--chunk-size EVENT_COUNT
                           how many events to fetch at a time
```

### `list-streams`

```
Usage: event-store-ctl list-streams [-N NUMBER] [-a|--all] [-u|--updated]
  List most recent streams

Available options:
  -h,--help                Show this help text
  -N NUMBER                Maximum number of stream names to
                           output (default: 20)
  -a,--all                 Display all streams, not just the ones that were
                           recently created
  -u,--updated             Display updated streams, i.e. those with an event
                           with event number > 0
```

### `send-event`

```
Usage: event-store-ctl send-event [-s|--stream STREAM_NAME]
                                  [-t|--type EVENT_TYPE] [-p|--payload DATA]
                                  [-b|--binary] [--output-template]
  Creates an event

Available options:
  -h,--help                Show this help text
  -s,--stream STREAM_NAME  Name of stream to send the event to
  -t,--type EVENT_TYPE     Event type
  -p,--payload DATA        Event data passed as argument instead of STDIN
  -b,--binary              Payload is binary data
  --output-template        Output a template of an expected JSON input
```

### `send-events`

```
Usage: event-store-ctl send-events [-s|--stream STREAM_NAME]
                                   [-t|--type EVENT_TYPE] [-b|--binary ARG]
  Sends events incrementally

Available options:
  -h,--help                Show this help text
  -s,--stream STREAM_NAME  Name of stream to send the event to
  -t,--type EVENT_TYPE     Event type
  -b,--binary ARG          Signals that inputs will be binary data and the
                           argument whould be used as separator (currently a
                           number is interpreted as ASCII value - use 10 as
                           newline - TODO accept multibyte bytestrings)
```

