#!/usr/bin/env bats
# End-to-end: create -> draft on disk -> eval server serves it -> approve finalizes.

setup() {
  TMP="$(mktemp -d)"; export HOME="$TMP"
  cat > "$TMP/fake-claude" <<EOF
#!/usr/bin/env bash
# stands in for 'claude -p <create prompt>': author a 1-category draft via the real renderer in mock mode
D="\$HOME/.peon-ping/drafts/calmtest"
mkdir -p "\$D/sounds"
cat > "\$D/openpeon.json" <<'EOJ'
{"cesp_version":"1.0","name":"calmtest","version":"0.0.1","x_openpeon_draft":true,
 "categories":{"task.complete":{"sounds":[{"file":"sounds/task_complete_0.wav","label":"Done"}]}}}
EOJ
cat > "\$D/prompts.json" <<'EOJ'
{"sounds/task_complete_0.wav":{"type":"sfx","prompt":"two gentle bells"}}
EOJ
echo '{"type":"sfx","prompt":"two gentle bells","out":"'"\$D"'/sounds/task_complete_0.wav"}' > "\$D/j.json"
python3 "$BATS_TEST_DIRNAME/../scripts/pack-render.py" --job "\$D/j.json" --mock
EOF
  chmod +x "$TMP/fake-claude"
}
teardown() { rm -rf "$TMP"; }

@test "create -> eval -> approve pipeline (all mock, no network)" {
  PEON_CLAUDE_BIN="$TMP/fake-claude" PEON_EVAL_NO_OPEN=1 PEON_EVAL_DRY_RUN=1 \
    run bash "$BATS_TEST_DIRNAME/../peon.sh" create --name calmtest --flavor sfx --vibe "calm bells"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.peon-ping/drafts/calmtest/sounds/task_complete_0.wav" ]
  grep -q x_openpeon_draft "$HOME/.peon-ping/drafts/calmtest/openpeon.json"

  # now really serve it and approve
  PEON_APPROVED_DIR="$HOME/.peon-ping/packs" python3 "$BATS_TEST_DIRNAME/../scripts/eval-server.py" \
    --draft "$HOME/.peon-ping/drafts/calmtest" --no-open --print-port --claude-bin /usr/bin/true > "$TMP/port.txt" &
  for _ in $(seq 1 50); do grep -q PORT= "$TMP/port.txt" 2>/dev/null && break; sleep 0.1; done
  PORT="$(sed -n 's/^PORT=//p' "$TMP/port.txt")"
  run curl -sf -X POST -d '{"install":false}' "http://127.0.0.1:$PORT/api/approve"
  [ -f "$HOME/.peon-ping/packs/calmtest/openpeon.json" ]
  ! grep -q x_openpeon_draft "$HOME/.peon-ping/packs/calmtest/openpeon.json"
}
