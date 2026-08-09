#!/usr/bin/env bats

setup() { TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

@test "mock render writes an audible wav" {
  cat > "$TMP/job.json" <<EOF
{"type":"sfx","prompt":"a soft chime","out":"$TMP/x.wav"}
EOF
  run python3 "$BATS_TEST_DIRNAME/../scripts/pack-render.py" --job "$TMP/job.json" --mock
  [ "$status" -eq 0 ]
  [ -f "$TMP/x.wav" ]
  # RIFF header + non-trivial size (1.5s of 44.1kHz mono 16-bit ≈ 132kB)
  head -c4 "$TMP/x.wav" | grep -q RIFF
  [ "$(wc -c < "$TMP/x.wav")" -gt 100000 ]
}

@test "missing key is exit 2 with guidance, key never printed" {
  cat > "$TMP/job.json" <<EOF
{"type":"sfx","prompt":"a soft chime","out":"$TMP/x.wav"}
EOF
  HOME="$TMP" ELEVENLABS_API_KEY="" run python3 "$BATS_TEST_DIRNAME/../scripts/pack-render.py" --job "$TMP/job.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"credentials"* ]]
  [[ "$output" == *"elevenlabs.io"* ]]
}

@test "malformed job is exit 1" {
  echo '{"type":"nope"}' > "$TMP/job.json"
  run python3 "$BATS_TEST_DIRNAME/../scripts/pack-render.py" --job "$TMP/job.json" --mock
  [ "$status" -eq 1 ]
}
