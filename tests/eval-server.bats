#!/usr/bin/env bats

setup() {
  TMP="$(mktemp -d)"
  DRAFT="$TMP/draft"
  mkdir -p "$DRAFT/sounds"
  cat > "$DRAFT/openpeon.json" <<'EOF'
{"cesp_version":"1.0","name":"testpack","display_name":"Test Pack","version":"0.0.1","x_openpeon_draft":true,
 "categories":{"task.complete":{"sounds":[{"file":"sounds/done.wav","label":"Done"}]}}}
EOF
  python3 - "$DRAFT/sounds/done.wav" <<'PY'
import sys, wave, struct, math
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
    w.writeframes(b"".join(struct.pack("<h", int(9000*math.sin(i/20.0))) for i in range(44100)))
PY
  cat > "$TMP/fake-claude" <<'EOF'
#!/usr/bin/env bash
# fake claude -p: succeed if FAKE_CLAUDE_FAIL unset; simulate a reroll by touching the wav
[ -n "$FAKE_CLAUDE_FAIL" ] && { echo "boom" >&2; exit 1; }
exit 0
EOF
  chmod +x "$TMP/fake-claude"
  python3 "$BATS_TEST_DIRNAME/../scripts/eval-server.py" --draft "$DRAFT" --claude-bin "$TMP/fake-claude" --no-open --print-port > "$TMP/port.txt" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do grep -q PORT= "$TMP/port.txt" 2>/dev/null && break; sleep 0.1; done
  PORT="$(sed -n 's/^PORT=//p' "$TMP/port.txt")"
}

teardown() { kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"; }

@test "GET /api/pack returns manifest summary" {
  run curl -sf "http://127.0.0.1:$PORT/api/pack"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name": "testpack"'* ]]
  [[ "$output" == *'"draft": true'* ]]
  [[ "$output" == *'task.complete'* ]]
}

@test "GET /sounds serves wav bytes and blocks traversal" {
  run curl -sf -o "$TMP/got.wav" "http://127.0.0.1:$PORT/sounds/done.wav"
  [ "$status" -eq 0 ]
  head -c4 "$TMP/got.wav" | grep -q RIFF
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/sounds/../openpeon.json"
  [[ "$output" == "404" ]]
}

@test "lockfile records port and pid" {
  run cat "$DRAFT/.eval-server.json"
  [[ "$output" == *"\"port\": $PORT"* ]]
}

@test "GET /sounds blocks symlink escape" {
  ln -s /tmp/.outside-secret.txt "$DRAFT/sounds/escape.wav"
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/sounds/escape.wav"
  [[ "$output" == "404" ]]
}

@test "lockfile is removed on SIGTERM" {
  kill -TERM "$SERVER_PID"
  sleep 0.5
  [ ! -f "$DRAFT/.eval-server.json" ]
}

@test "reroll spawns claude, writes job file, emits done" {
  curl -sf -N "http://127.0.0.1:$PORT/api/events" > "$TMP/sse.txt" &
  SSE_PID=$!
  sleep 0.2
  run curl -sf -X POST -d '{"scope":"sound","category":"task.complete","index":0,"caption":"warmer"}' \
      "http://127.0.0.1:$PORT/api/reroll"
  [[ "$output" == *'"job"'* ]]
  for _ in $(seq 1 50); do grep -q '"done"' "$TMP/sse.txt" 2>/dev/null && break; sleep 0.1; done
  kill "$SSE_PID" 2>/dev/null || true
  grep -q '"started"' "$TMP/sse.txt"
  grep -q '"done"' "$TMP/sse.txt"
  ls "$DRAFT/jobs/" | grep -q '.json'
  grep -q '"caption": "warmer"' "$DRAFT"/jobs/*.json
}

@test "reroll requires known category and in-range index for scope=sound" {
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
      -d '{"scope":"sound","category":"no.such.category","index":0,"caption":"x"}' \
      "http://127.0.0.1:$PORT/api/reroll"
  [[ "$output" == "400" ]]
  run curl -s -o /dev/null -w "%{http_code}" -X POST \
      -d '{"scope":"sound","category":"task.complete","index":99,"caption":"x"}' \
      "http://127.0.0.1:$PORT/api/reroll"
  [[ "$output" == "400" ]]
}

@test "reroll returns 409 while a job is busy" {
  curl -sf -N "http://127.0.0.1:$PORT/api/events" > "$TMP/sse.txt" &
  SSE_PID=$!
  sleep 0.2
  run curl -sf -X POST -d '{"scope":"pack","caption":"softer"}' \
      "http://127.0.0.1:$PORT/api/reroll"
  [[ "$output" == *'"job"'* ]]
  for _ in $(seq 1 50); do grep -q '"started"' "$TMP/sse.txt" 2>/dev/null && break; sleep 0.1; done
  run curl -s -o /dev/null -w "%{http_code}" -X POST -d '{"scope":"pack","caption":"softer again"}' \
      "http://127.0.0.1:$PORT/api/reroll"
  [[ "$output" == "409" ]]
  for _ in $(seq 1 50); do grep -q '"done"' "$TMP/sse.txt" 2>/dev/null && break; sleep 0.1; done
  kill "$SSE_PID" 2>/dev/null || true
}

@test "failed claude run emits failed with detail" {
  FAKE_CLAUDE_FAIL=1 python3 "$BATS_TEST_DIRNAME/../scripts/eval-server.py" \
      --draft "$DRAFT" --claude-bin "$TMP/fake-claude" --no-open --print-port > "$TMP/port2.txt" &
  SERVER_PID2=$!
  for _ in $(seq 1 50); do grep -q PORT= "$TMP/port2.txt" 2>/dev/null && break; sleep 0.1; done
  PORT2="$(sed -n 's/^PORT=//p' "$TMP/port2.txt")"
  curl -sf -N "http://127.0.0.1:$PORT2/api/events" > "$TMP/sse2.txt" &
  SSE_PID2=$!
  sleep 0.2
  run curl -sf -X POST -d '{"scope":"pack","caption":"all softer"}' \
      "http://127.0.0.1:$PORT2/api/reroll"
  [[ "$output" == *'"job"'* ]]
  for _ in $(seq 1 50); do grep -q '"failed"' "$TMP/sse2.txt" 2>/dev/null && break; sleep 0.1; done
  kill "$SSE_PID2" 2>/dev/null || true
  kill "$SERVER_PID2" 2>/dev/null || true
  grep -q '"failed"' "$TMP/sse2.txt"
  grep -q 'boom' "$TMP/sse2.txt"
}
