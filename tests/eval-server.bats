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

@test "GET / serves the eval UI" {
  run curl -sf "http://127.0.0.1:$PORT/"
  [[ "$output" == *"Reroll whole pack"* ]]
  [[ "$output" == *"Approve pack"* ]]
}

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

@test "concurrent reroll POSTs: exactly one 202, rest 409, one job file" {
  # NOTE: wait on the explicit PIDs, not a bare `wait` — a bare `wait` blocks on
  # every background job in this shell, including setup()'s long-lived SERVER_PID
  # (eval-server.py runs serve_forever() until SIGTERM), which would hang forever.
  pids=()
  for i in $(seq 1 10); do
    curl -s -o "$TMP/body_$i.txt" -w "%{http_code}" -X POST \
        -d '{"scope":"pack","caption":"softer"}' \
        "http://127.0.0.1:$PORT/api/reroll" > "$TMP/code_$i.txt" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  count_202=0
  count_409=0
  for i in $(seq 1 10); do
    code="$(cat "$TMP/code_$i.txt")"
    [ "$code" = "202" ] && count_202=$((count_202 + 1))
    [ "$code" = "409" ] && count_409=$((count_409 + 1))
  done
  [ "$count_202" -eq 1 ]
  [ "$count_409" -eq 9 ]
  for _ in $(seq 1 50); do [ -d "$DRAFT/jobs" ] && [ -n "$(ls -A "$DRAFT/jobs" 2>/dev/null)" ] && break; sleep 0.1; done
  job_count="$(ls "$DRAFT/jobs" | grep -c '\.json$')"
  [ "$job_count" -eq 1 ]
}

@test "SIGTERM during a job terminates the running claude process tree" {
  cat > "$TMP/slow-claude" <<'EOF'
#!/usr/bin/env bash
echo $$ > "$SLOW_PID_FILE"
sleep 30
EOF
  chmod +x "$TMP/slow-claude"
  SLOW_PID_FILE="$TMP/slow.pid" python3 "$BATS_TEST_DIRNAME/../scripts/eval-server.py" \
      --draft "$DRAFT" --claude-bin "$TMP/slow-claude" --no-open --print-port > "$TMP/port3.txt" &
  SERVER_PID3=$!
  for _ in $(seq 1 50); do grep -q PORT= "$TMP/port3.txt" 2>/dev/null && break; sleep 0.1; done
  PORT3="$(sed -n 's/^PORT=//p' "$TMP/port3.txt")"
  run curl -sf -X POST -d '{"scope":"pack","caption":"x"}' "http://127.0.0.1:$PORT3/api/reroll"
  [[ "$output" == *'"job"'* ]]
  for _ in $(seq 1 50); do [ -f "$TMP/slow.pid" ] && break; sleep 0.1; done
  SLOW_PID="$(cat "$TMP/slow.pid")"
  kill -0 "$SLOW_PID"   # sanity: it's actually running
  kill -TERM "$SERVER_PID3"
  for _ in $(seq 1 20); do kill -0 "$SLOW_PID" 2>/dev/null || break; sleep 0.1; done
  run kill -0 "$SLOW_PID"
  [ "$status" -ne 0 ]
  kill "$SERVER_PID3" 2>/dev/null || true
}

@test "approve strips stamp, moves pack, shuts down" {
  APPROVED="$TMP/approved"
  echo '[{"job":"seed"}]' > "$DRAFT/eval-log.json"
  # PEON_APPROVED_DIR must be in the SERVER's env, not just the test's — start a
  # dedicated server instance, following the pattern the failed-claude test uses.
  PEON_APPROVED_DIR="$APPROVED" python3 "$BATS_TEST_DIRNAME/../scripts/eval-server.py" \
      --draft "$DRAFT" --claude-bin "$TMP/fake-claude" --no-open --print-port > "$TMP/port4.txt" &
  SERVER_PID4=$!
  for _ in $(seq 1 50); do grep -q PORT= "$TMP/port4.txt" 2>/dev/null && break; sleep 0.1; done
  PORT4="$(sed -n 's/^PORT=//p' "$TMP/port4.txt")"
  run curl -sf -X POST -d '{"install":false}' "http://127.0.0.1:$PORT4/api/approve"
  [[ "$output" == *'"approved"'* ]]
  [[ "$output" == *'"installed": false'* ]]
  [ -f "$APPROVED/testpack/openpeon.json" ]
  ! grep -q x_openpeon_draft "$APPROVED/testpack/openpeon.json"
  [ ! -d "$APPROVED/testpack/jobs" ]
  [ ! -f "$APPROVED/testpack/.eval-server.json" ]
  [ -f "$APPROVED/testpack/eval-log.json" ]
  grep -q '"job":"seed"' "$APPROVED/testpack/eval-log.json"
  [ ! -d "$DRAFT" ] || [ ! -f "$DRAFT/openpeon.json" ]
  sleep 1.5
  run curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:$PORT4/api/pack"
  [[ "$output" != "200" ]]
  kill "$SERVER_PID4" 2>/dev/null || true
}

@test "approve with install:true copies the pack into PEON_DIR" {
  APPROVED="$TMP/approved"
  INSTALLED="$TMP/installed"
  PEON_APPROVED_DIR="$APPROVED" PEON_DIR="$INSTALLED" \
      python3 "$BATS_TEST_DIRNAME/../scripts/eval-server.py" \
      --draft "$DRAFT" --claude-bin "$TMP/fake-claude" --no-open --print-port > "$TMP/port5.txt" &
  SERVER_PID5=$!
  for _ in $(seq 1 50); do grep -q PORT= "$TMP/port5.txt" 2>/dev/null && break; sleep 0.1; done
  PORT5="$(sed -n 's/^PORT=//p' "$TMP/port5.txt")"
  run curl -sf -X POST -d '{"install":true}' "http://127.0.0.1:$PORT5/api/approve"
  [[ "$output" == *'"approved"'* ]]
  [[ "$output" == *'"installed": true'* ]]
  [ -f "$APPROVED/testpack/openpeon.json" ]
  [ -f "$INSTALLED/packs/testpack/openpeon.json" ]
  ! grep -q x_openpeon_draft "$INSTALLED/packs/testpack/openpeon.json"
  kill "$SERVER_PID5" 2>/dev/null || true
}

@test "approve returns 409 exists when the target already exists" {
  APPROVED="$TMP/approved"
  mkdir -p "$APPROVED/testpack"
  PEON_APPROVED_DIR="$APPROVED" python3 "$BATS_TEST_DIRNAME/../scripts/eval-server.py" \
      --draft "$DRAFT" --claude-bin "$TMP/fake-claude" --no-open --print-port > "$TMP/port6.txt" &
  SERVER_PID6=$!
  for _ in $(seq 1 50); do grep -q PORT= "$TMP/port6.txt" 2>/dev/null && break; sleep 0.1; done
  PORT6="$(sed -n 's/^PORT=//p' "$TMP/port6.txt")"
  run curl -s -o "$TMP/approve-exists.json" -w "%{http_code}" -X POST -d '{"install":false}' \
      "http://127.0.0.1:$PORT6/api/approve"
  [[ "$output" == "409" ]]
  grep -q '"error": "exists"' "$TMP/approve-exists.json"
  [ -d "$DRAFT" ]
  # short-circuited before any mutation — draft's manifest and lockfile are untouched
  grep -q x_openpeon_draft "$DRAFT/openpeon.json"
  [ -f "$DRAFT/.eval-server.json" ]
  # server is still alive (not the shutdown path) — a normal GET still works
  run curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT6/api/pack"
  [[ "$output" == "200" ]]
  kill "$SERVER_PID6" 2>/dev/null || true
}

@test "approve returns 409 busy while a reroll job is in flight" {
  APPROVED="$TMP/approved"
  PEON_APPROVED_DIR="$APPROVED" python3 "$BATS_TEST_DIRNAME/../scripts/eval-server.py" \
      --draft "$DRAFT" --claude-bin "$TMP/fake-claude" --no-open --print-port > "$TMP/port7.txt" &
  SERVER_PID7=$!
  for _ in $(seq 1 50); do grep -q PORT= "$TMP/port7.txt" 2>/dev/null && break; sleep 0.1; done
  PORT7="$(sed -n 's/^PORT=//p' "$TMP/port7.txt")"
  curl -sf -N "http://127.0.0.1:$PORT7/api/events" > "$TMP/sse7.txt" &
  SSE_PID7=$!
  sleep 0.2
  run curl -sf -X POST -d '{"scope":"pack","caption":"softer"}' \
      "http://127.0.0.1:$PORT7/api/reroll"
  [[ "$output" == *'"job"'* ]]
  for _ in $(seq 1 50); do grep -q '"started"' "$TMP/sse7.txt" 2>/dev/null && break; sleep 0.1; done
  run curl -s -o /dev/null -w "%{http_code}" -X POST -d '{"install":false}' \
      "http://127.0.0.1:$PORT7/api/approve"
  [[ "$output" == "409" ]]
  [ -d "$DRAFT" ]
  for _ in $(seq 1 50); do grep -q '"done"' "$TMP/sse7.txt" 2>/dev/null && break; sleep 0.1; done
  kill "$SSE_PID7" 2>/dev/null || true
  kill "$SERVER_PID7" 2>/dev/null || true
}
