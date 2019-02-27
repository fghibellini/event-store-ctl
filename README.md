
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
Usage: event-store-ctl send-event STREAM_NAME EVENT_TYPE DATA
  Creates an event

Available options:
  -h,--help                Show this help text
  STREAM_NAME              Name of stream to send the event to
  EVENT_TYPE               Event type
  DATA                     Event data
```
