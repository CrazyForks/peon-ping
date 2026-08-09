---
name: peon-ping-remix
description: 'Execute one PeonPing reroll job — invoked headlessly by the peon eval server as: "Use the peon-ping-remix skill to execute the reroll job at <path>". Reads the job JSON (scope, category, index, caption), rewrites the affected sound prompt(s) to honor the caption, re-renders via scripts/pack-render.py, and logs the change to eval-log.json.'
---

# peon-ping-remix

You are executing ONE reroll job for a draft PeonPing pack. Work only inside
the job's `draft_dir`. Do not touch any other directory, do not install
anything, do not commit anything.

## Procedure

1. Read the job JSON at the path you were given: `scope` ("sound" or
   "pack"), `category`, `index`, `caption`, `draft_dir`.
2. Read `<draft_dir>/openpeon.json` and `<draft_dir>/prompts.json`. If
   `prompts.json` is missing, fail with a clear message — you cannot reroll
   without the current prompts.
3. Determine the target sound files: scope "sound" → the one file at
   `categories[category].sounds[index].file`; scope "pack" → every file in
   every category.
4. For each target, author a NEW render input honoring the caption:
   - Keep the pack's established aesthetic (read the other prompts for
     context). The caption is a correction, not a reset: "too harsh, want
     softer" means adjust intensity, keep the instrument palette unless the
     caption says otherwise.
   - sfx entries: rewrite `prompt`. tts entries: rewrite `text` (keep
     `voice_id` — never change a pack's voice in a reroll).
   - If the caption is empty, produce a fresh variation of the same idea.
5. Render each target: write the new input as a job file and run
   `python3 <peon-ping>/scripts/pack-render.py --job <file>` with `out` set
   to the target WAV path (overwrite in place). The renderer exits nonzero
   on silent/failed renders — if it fails, STOP and exit nonzero yourself
   with its stderr; do not half-update the log.
   (Resolve `<peon-ping>` as the scripts directory next to the running peon
   install: `$PEON_DIR/scripts` when present, else the repo checkout you
   were invoked from.)
6. After ALL targets render successfully: update `prompts.json` with the new
   inputs, and append one entry per rendered sound to
   `<draft_dir>/eval-log.json` (create as `[]` if missing):
   `{"ts": "<ISO8601>", "scope", "category", "index", "caption",
     "old_prompt", "new_prompt", "file"}`.
7. Print a one-line summary per rendered sound. Exit 0.

## Hard rules

- NEVER write outside `draft_dir`.
- NEVER print or log the ElevenLabs key.
- A failed render leaves the previous WAV in place — pack-render.py writes
  to the out path only on success; do not delete a WAV before rendering.
- Captions are the user's judgment. Honor them literally before creatively.
