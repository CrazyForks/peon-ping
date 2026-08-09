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
  python3 "$BATS_TEST_DIRNAME/../scripts/eval-server.py" --draft "$DRAFT" --no-open --print-port > "$TMP/port.txt" &
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
