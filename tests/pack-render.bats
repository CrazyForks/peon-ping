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

@test "unparseable volumedetect output is exit 1, not silent default" {
  # Create a fake ffmpeg that exits 0 with no volumedetect output
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/ffmpeg" <<'FFMPEG'
#!/bin/bash
# Fake ffmpeg that ignores volumedetect and emits nothing
exit 0
FFMPEG
  chmod +x "$TMP/bin/ffmpeg"

  # Create a dummy wav file for testing
  python3 << PYTHON
import wave, struct, math
w = wave.open("$TMP/dummy.wav", 'wb')
w.setnchannels(1)
w.setsampwidth(2)
w.setframerate(44100)
frames = int(44100 * 0.5)
w.writeframes(b"".join(
    struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 44100)))
    for i in range(frames)))
w.close()
PYTHON

  # Test peak_db in isolation with fake ffmpeg on PATH, using importlib to load module
  PATH="$TMP/bin:$PATH" run python3 << PYTHON
import sys
import importlib.util
spec = importlib.util.spec_from_file_location("pack_render", "scripts/pack-render.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
exited_loudly = False
try:
    result = m.peak_db("$TMP/dummy.wav")
except SystemExit as e:
    exited_loudly = (e.code == 1)
if not exited_loudly:
    sys.stderr.write("peak_db did not exit 1 on unparseable volumedetect\n")
    sys.exit(1)
PYTHON
  [ "$status" -eq 0 ]
}

@test "B4: a failed ffmpeg conversion leaves the previous good WAV untouched" {
  # Regression test for the proven bug: ffmpeg truncate-then-fail used to leave
  # a 0-byte file where a good take had been, because to_wav() rendered
  # straight into `out`. Fix: render into a same-dir temp file and os.replace()
  # only on success.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/ffmpeg" <<'FFMPEG'
#!/bin/bash
# Simulate the proven failure mode: truncate whatever output path it was given
# (as real ffmpeg does immediately on invocation with -y), then fail.
out="${@: -1}"
: > "$out"
exit 1
FFMPEG
  chmod +x "$TMP/bin/ffmpeg"

  OUT="$TMP/good-take.wav"
  printf 'GOOD-PREVIOUS-TAKE-88KB-STAND-IN' > "$OUT"
  BEFORE_SHA="$(shasum "$OUT" | awk '{print $1}')"

  cat > "$TMP/job.json" <<EOF
{"type":"sfx","prompt":"a soft chime","out":"$OUT"}
EOF

  PATH="$TMP/bin:$PATH" run python3 - "$TMP/job.json" <<'PYTHON'
import importlib.util, json, sys
job_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("pack_render", "scripts/pack-render.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.read_api_key = lambda: "fake-key"
m.fetch_mp3 = lambda job, key, prompt_suffix="": b"not-really-an-mp3"
sys.argv = ["pack-render.py", "--job", job_path]
m.main()
PYTHON
  [ "$status" -eq 1 ]
  [[ "$output" == *"ffmpeg conversion failed"* ]]

  # The out path must be byte-identical to the pre-existing good take — never
  # truncated, never touched by the failed conversion.
  AFTER_SHA="$(shasum "$OUT" | awk '{print $1}')"
  [ "$BEFORE_SHA" = "$AFTER_SHA" ]
  [ "$(wc -c < "$OUT")" -gt 0 ]

  # No leftover .wav temp file beside it either.
  leftover="$(find "$TMP" -maxdepth 1 -name '*.wav' ! -name 'good-take.wav')"
  [ -z "$leftover" ]
}
