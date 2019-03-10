
#### Examples

##### JSON

```
event-store-ctl send-event <<EOF
{
  "stream": "child#1",
  "type": "first-steps",
  "payload": {
    "numberOfSteps": 3,
    "durationInSeconds": 7.2
  }
}
EOF
```

```
WriteResult {writeNextExpectedVersion = 3, writePosition = Position {positionCommit = 2715108, positionPrepare = 2715108}}
```

##### Binary

```
$ event-store-ctl send-event -b <<EOF
child#1:first-steps:(numberOfSteps,3):(durationInSeconds:7.2)
EOF
```

```
WriteResult {writeNextExpectedVersion = 3, writePosition = Position {positionCommit = 2715108, positionPrepare = 2715108}}
```

##### Binary as argument

```
$ event-store-ctl send-event -b -d 'child#1:first-steps:(numberOfSteps,3):(durationInSeconds:7.2)'
```

```
WriteResult {writeNextExpectedVersion = 3, writePosition = Position {positionCommit = 2715108, positionPrepare = 2715108}}
```
