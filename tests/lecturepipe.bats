#!/usr/bin/env bats
# Run: bats tests/

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export XDG_CONFIG_HOME="$HOME/.config"
  export LECTURE_ROOT="$HOME/lectures"
  mkdir -p "$LECTURE_ROOT"
  # Never touch the real user systemd from a test: systemctl ignores HOME.
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  printf '#!/usr/bin/env bash\n[[ "$*" == *is-active* ]] && exit 3\nexit 0\n' > "$BATS_TEST_TMPDIR/stubs/systemctl"
  # Tests must not see a real recording on this machine: hide only that pgrep pattern.
  printf '#!/usr/bin/env bash\n[[ "$*" == *"ffmpeg.*-f pulse"* ]] && exit 1\nexec /usr/bin/pgrep "$@"\n' > "$BATS_TEST_TMPDIR/stubs/pgrep"
  chmod +x "$BATS_TEST_TMPDIR/stubs/systemctl" "$BATS_TEST_TMPDIR/stubs/pgrep"
  export PATH="$BATS_TEST_TMPDIR/stubs:$REPO/bin:$PATH"
  unset LECTURE_NOTES_ROOT LECTURE_NOTES_CMD LECTURE_NOTES_ENGINE LECTURE_LLM LECTURE_RECORD_MODE
}

mknote() {  # mknote path course lang words
  python3 -I "$REPO/lib/srt2md.py" --srt "$REPO/tests/fixtures/sample.srt" --out "$1" \
    --course "$2" --date 2026-10-19 --title "routing" --lang "$3" --model large \
    --duration 20 --source /tmp/x.flac >/dev/null
  # inflate the word count so the notes pass does not skip it
  sed -i "s/^words: .*/words: ${4:-500}/" "$1"
}

@test "srt2md writes frontmatter, markers and timestamped paragraphs" {
  python3 -I "$REPO/lib/srt2md.py" --srt "$REPO/tests/fixtures/sample.srt" --out "$BATS_TEST_TMPDIR/n.md" \
    --course NET301 --date 2026-10-19 --title "routing-protocols" --lang en --model turbo \
    --duration 20 --source /tmp/x.flac
  run cat "$BATS_TEST_TMPDIR/n.md"
  [[ "$output" == *"course: NET301"* ]]
  [[ "$output" == *'title: "routing protocols"'* ]]
  [[ "$output" == *"asr_model: whisper-large-v3-turbo"* ]]
  [[ "$output" == *"notes_status: pending"* ]]
  [[ "$output" == *"<!-- LECTURE-NOTES-START -->"* ]]
  [[ "$output" == *"**[00:00:00]** Good morning"* ]]
  [[ "$output" == *"**[00:00:12]** RIP counts hops"* ]]   # new paragraph after the 3.8 s pause
  [[ "$output" != *"repetition_warning"* ]]
}

@test "srt2md flags a decoder loop" {
  run python3 -I "$REPO/lib/srt2md.py" --srt "$REPO/tests/fixtures/loop.srt" --out "$BATS_TEST_TMPDIR/l.md" \
    --course X --date 2026-10-19 --title t --lang en --model large --duration 72 --source /tmp/x
  [[ "$output" == *"REPETITION LOOP"* ]]
  grep -q '^repetition_warning:' "$BATS_TEST_TMPDIR/l.md"
}

@test "courses.conf lookup: language, glossary, notes=off, DEFAULT fallback" {
  cp "$REPO/tests/fixtures/courses.conf" "$LECTURE_ROOT/courses.conf"
  source "$REPO/lib/common.sh"
  run lp_course_lookup net301
  [ "$output" = $'en\tNetworks. Terms: OSPF, BGP.\tnotes=off' ]
  run lp_course_lookup HIS101
  [ "$output" = $'de\tGeschichte, Prof. Beispiel\t' ]
  run lp_course_lookup NOPE
  [ -z "$output" ]
  run lp_course_lookup DEFAULT
  [[ "$output" == el* ]]
}

@test "config file is sourced and environment wins" {
  mkdir -p "$XDG_CONFIG_HOME/lecturepipe"
  printf 'LECTURE_MODEL=turbo\nLECTURE_MIC=mic-from-file\n' > "$XDG_CONFIG_HOME/lecturepipe/config"
  export LECTURE_MIC=mic-from-env
  source "$REPO/lib/common.sh"
  [ "$LECTURE_MODEL" = turbo ]
  [ "$LECTURE_MIC" = mic-from-env ]
}

@test "notes prompt picks the template by language and merge writes the block" {
  N="$BATS_TEST_TMPDIR/n.md"; mknote "$N" NET301 en
  python3 -I "$REPO/lib/notes.py" prompt "$N" --out "$BATS_TEST_TMPDIR/p.txt" --tag-out "$BATS_TEST_TMPDIR/tag"
  run cat "$BATS_TEST_TMPDIR/p.txt"
  [[ "$output" == *"You are a study assistant"* ]]
  [[ "$output" == *"(NET301, 2026-10-19)"* ]]
  [[ "$output" == *"[00:00:12] RIP counts hops"* ]]
  [[ "$output" != *"{{"* ]]
  [[ "$output" != *"section:"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/tag")" = cmd ]

  G="$BATS_TEST_TMPDIR/n2.md"; mknote "$G" HIS101 el
  python3 -I "$REPO/lib/notes.py" prompt "$G" --out "$BATS_TEST_TMPDIR/pg.txt"
  grep -q "Είσαι βοηθός μελέτης" "$BATS_TEST_TMPDIR/pg.txt"

  printf '```markdown\n## Notes\n\n### Summary\n- fake\n```\n' > "$BATS_TEST_TMPDIR/out.md"
  python3 -I "$REPO/lib/notes.py" merge "$N" --generated "$BATS_TEST_TMPDIR/out.md" --engine cmd
  run cat "$N"
  [[ "$output" == *"notes_status: done (cmd)"* ]]
  [[ "$output" == *$'<!-- LECTURE-NOTES-START -->\n\n## Notes\n\n### Summary\n- fake\n\n<!-- LECTURE-NOTES-END -->'* ]]
  [[ "$output" != '*```*' ]]
  [[ "$output" == *"## Transcript"* ]]
}

@test "notes prompt includes slide text with page markers" {
  command -v pdftotext >/dev/null || skip "pdftotext missing"
  N="$BATS_TEST_TMPDIR/n.md"; mknote "$N" NET301 en
  python3 -I "$REPO/lib/notes.py" prompt "$N" --out "$BATS_TEST_TMPDIR/p.txt" --tag-out "$BATS_TEST_TMPDIR/tag" --slides "$REPO/tests/fixtures/slides.pdf"
  run cat "$BATS_TEST_TMPDIR/p.txt"
  [[ "$output" == *"SLIDE TEXT"* ]]
  [[ "$output" == *"=== page 1 ==="* ]]
  [[ "$output" == *"=== page 2 ==="* ]]
  [[ "$output" == *"Slide two: BGP path vector"* ]]
  [[ "$output" == *"(slide 12)"* ]]          # slides rules were included
  [ "$(cat "$BATS_TEST_TMPDIR/tag")" = cmd+slides ]
}

@test "notes prompt finds the deck next to a filed note and lists sibling recordings" {
  command -v pdftotext >/dev/null || skip "pdftotext missing"
  export LECTURE_NOTES_ROOT="$HOME/vault"
  D="$LECTURE_NOTES_ROOT/networks_net301/lectures/07"; mkdir -p "$D"
  cp "$REPO/tests/fixtures/slides.pdf" "$D/07.pdf"
  cp "$REPO/tests/fixtures/slides.pdf" "$D/extra-reading.pdf"
  S="$D/2026-10-12_lecture-7-part-one.md"; mknote "$S" NET301 en
  printf '## Notes\n\n### Outline\n- **[00:05]** OSPF basics\n' > "$BATS_TEST_TMPDIR/sib.md"
  python3 -I "$REPO/lib/notes.py" merge "$S" --generated "$BATS_TEST_TMPDIR/sib.md" --engine cmd
  N="$D/2026-10-19_lecture-7-part-two.md"; mknote "$N" NET301 en
  python3 -I "$REPO/lib/notes.py" prompt "$N" --out "$BATS_TEST_TMPDIR/p.txt"
  run cat "$BATS_TEST_TMPDIR/p.txt"
  [[ "$output" == *"##### 07.pdf"* ]]
  [[ "$output" != *"extra-reading.pdf"* ]]
  [[ "$output" == *"OTHER RECORDINGS OF THE SAME LECTURE: there are 1 more"* ]]
  [[ "$output" == *"- **[00:05]** OSPF basics"* ]]
}

@test "lecture-notes pipes the prompt through LECTURE_NOTES_CMD" {
  N="$BATS_TEST_TMPDIR/n.md"; mknote "$N" NET301 en
  export LECTURE_NOTES_CMD="sed -n '1p' >/dev/null; printf '## Notes\n\n### Summary\n- from fake engine\n'"
  run lecture-notes "$N"
  [ "$status" -eq 0 ]
  grep -q "from fake engine" "$N"
  grep -q "notes_status: done (cmd)" "$N"
  run lecture-notes "$N"
  [[ "$output" == *"already written"* ]]
}

@test "lecture-notes with no engine keeps the transcript and exits 0" {
  N="$BATS_TEST_TMPDIR/n.md"; mknote "$N" NET301 en
  export LECTURE_NOTES_ENGINE=off
  run lecture-notes "$N"
  [ "$status" -eq 0 ]
  [[ "$output" == *"transcript only"* ]]
  grep -q "notes_status: pending" "$N"
}

@test "lecture-notes skips short transcripts" {
  N="$BATS_TEST_TMPDIR/n.md"; mknote "$N" NET301 en 50
  export LECTURE_NOTES_CMD="false"
  run lecture-notes "$N"
  [ "$status" -eq 0 ]
  [[ "$output" == *"too short"* ]]
}

@test "lecture-file moves into the vault and leaves symlinks" {
  export LECTURE_NOTES_ROOT="$HOME/vault"
  mkdir -p "$LECTURE_NOTES_ROOT/networks_net301" "$LECTURE_ROOT/transcripts/NET301" "$LECTURE_ROOT/audio/NET301"
  N="$LECTURE_ROOT/transcripts/NET301/2026-10-19_lecture-7-routing.md"
  mknote "$N" NET301 en
  : > "$LECTURE_ROOT/transcripts/NET301/2026-10-19_lecture-7-routing.srt"
  : > "$LECTURE_ROOT/audio/NET301/rec.flac"
  sed -i "s|^audio:.*|audio: \"$LECTURE_ROOT/audio/NET301/rec.flac\"|" "$N"
  run lecture-file "$N"
  [ "$status" -eq 0 ]
  D="$LECTURE_NOTES_ROOT/networks_net301/lectures/07"
  [ -f "$D/2026-10-19_lecture-7-routing.md" ]
  [ -f "$D/2026-10-19_lecture-7-routing.srt" ]
  [ -f "$D/rec.flac" ]
  [ -L "$N" ]
  [ -L "$LECTURE_ROOT/audio/NET301/rec.flac" ]
  grep -q "audio: \"$D/rec.flac\"" "$D/2026-10-19_lecture-7-routing.md"
  run lecture-file "$N"
  [[ "$output" == *"already filed"* ]]
}

@test "lecture-file without a vault is a no-op" {
  N="$BATS_TEST_TMPDIR/n.md"; mknote "$N" NET301 en
  run lecture-file "$N"
  [ "$status" -eq 0 ]
  [ ! -L "$N" ]
}

@test "lecture-index builds INDEX.md" {
  mkdir -p "$LECTURE_ROOT/transcripts/NET301"
  mknote "$LECTURE_ROOT/transcripts/NET301/2026-10-19_routing.md" NET301 en
  run lecture-index
  [ "$status" -eq 0 ]
  grep -q "## NET301" "$LECTURE_ROOT/INDEX.md"
  grep -q "| 2026-10-19 | \[routing\]" "$LECTURE_ROOT/INDEX.md"
}

@test "lecture-record names the file from course and topic" {
  # fake ffmpeg that writes a byte to the output path
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  cat > "$BATS_TEST_TMPDIR/fakebin/ffmpeg" <<'SH'
#!/usr/bin/env bash
out="${@: -1}"; printf 'x' > "$out"
SH
  chmod +x "$BATS_TEST_TMPDIR/fakebin/ffmpeg"
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run lecture-record --keep-audio net301 "Routing Protocols: OSPF & BGP"
  [ "$status" -eq 0 ]
  [ -f "$LECTURE_ROOT/inbox/NET301_$(date +%F)_routing-protocols-ospf-bgp.flac" ]
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run lecture-record --keep-audio net301 "Routing Protocols: OSPF & BGP"
  [ -f "$LECTURE_ROOT/inbox/NET301_$(date +%F)_routing-protocols-ospf-bgp-2.flac" ]
}

@test "install.sh links commands and units into a fresh HOME" {
  run "$REPO/install.sh" --no-setup
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/bin/lecture-record" ]
  [ -L "$HOME/.local/bin/lecture-setup" ]
  [ -f "$XDG_CONFIG_HOME/systemd/user/lecture-watch.path" ]
  grep -q "Environment=PATH=$HOME/.local/bin:" "$XDG_CONFIG_HOME/systemd/user/lecture-watch.service"
  run "$REPO/uninstall.sh"
  [ ! -e "$HOME/.local/bin/lecture-record" ]
  [ ! -e "$XDG_CONFIG_HOME/systemd/user/lecture-watch.path" ]
}

@test "lecture-setup --defaults writes a config and courses.conf without asking" {
  export WHISPER_MODELS="$HOME/models"
  mkdir -p "$WHISPER_MODELS"; printf x > "$WHISPER_MODELS/ggml-large-v3-turbo.bin"   # pretend it is there
  run lecture-setup --defaults </dev/null
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/lecturepipe/config" ]
  grep -q "^LECTURE_ROOT=$HOME/lectures" "$XDG_CONFIG_HOME/lecturepipe/config"
  grep -q "^LECTURE_MODEL=turbo" "$XDG_CONFIG_HOME/lecturepipe/config"
  grep -q "^LECTURE_RECORD_MODE=live" "$XDG_CONFIG_HOME/lecturepipe/config"
  grep -q "^DEFAULT | en" "$LECTURE_ROOT/courses.conf"
  [ -d "$LECTURE_ROOT/inbox" ]
  # re-running keeps values and does not duplicate rows
  run lecture-setup --defaults </dev/null
  [ "$status" -eq 0 ]
  [ "$(grep -c '^CS101' "$LECTURE_ROOT/courses.conf")" -eq 1 ]
}

@test "lecture-transcribe derives course, date and slug from the filename" {
  # fake whisper-cli/ffmpeg/ffprobe so only the naming logic runs
  mkdir -p "$BATS_TEST_TMPDIR/fakebin" "$BATS_TEST_TMPDIR/models"
  printf x > "$BATS_TEST_TMPDIR/models/ggml-large-v3.bin"
  cat > "$BATS_TEST_TMPDIR/fakebin/ffmpeg" <<'SH'
#!/usr/bin/env bash
printf x > "${@: -1}"
SH
  cat > "$BATS_TEST_TMPDIR/fakebin/ffprobe" <<'SH'
#!/usr/bin/env bash
echo 20
SH
  cat > "$BATS_TEST_TMPDIR/fakebin/whisper-cli" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do [[ "$1" == -of ]] && OF="$2"; shift; done
cp "$REPO_FIXTURES/sample.srt" "$OF.srt"; : > "$OF.txt"; : > "$OF.json"
SH
  chmod +x "$BATS_TEST_TMPDIR/fakebin/"*
  export REPO_FIXTURES="$REPO/tests/fixtures" WHISPER_MODELS="$BATS_TEST_TMPDIR/models" LECTURE_NOTES_ENGINE=off
  mkdir -p "$LECTURE_ROOT/inbox"
  printf x > "$LECTURE_ROOT/inbox/TEST_2026-10-19_pipeline-check.flac"
  printf x > "$LECTURE_ROOT/inbox/cs101 intro.m4a"
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run lecture-transcribe "$LECTURE_ROOT/inbox/TEST_2026-10-19_pipeline-check.flac"
  [ "$status" -eq 0 ]
  [ -f "$LECTURE_ROOT/transcripts/TEST/2026-10-19_pipeline-check.md" ]
  [ -f "$LECTURE_ROOT/audio/TEST/TEST_2026-10-19_pipeline-check.flac" ]
  [ ! -e "$LECTURE_ROOT/inbox/TEST_2026-10-19_pipeline-check.flac" ]
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run lecture-transcribe "$LECTURE_ROOT/inbox/cs101 intro.m4a"
  [ "$status" -eq 0 ]
  ls "$LECTURE_ROOT/transcripts/CS101/"*_intro.md
}

@test "lecture-forget erases audio, derived files, symlinks and vault copies" {
  export LECTURE_NOTES_ROOT="$HOME/vault"
  mkdir -p "$LECTURE_NOTES_ROOT/networks_net301" "$LECTURE_ROOT/transcripts/NET301" "$LECTURE_ROOT/audio/NET301"
  N="$LECTURE_ROOT/transcripts/NET301/2026-10-19_lecture-7-routing.md"; mknote "$N" NET301 en
  : > "${N%.md}.srt"; : > "${N%.md}.json"
  printf audio > "$LECTURE_ROOT/audio/NET301/rec.flac"
  sed -i "s|^audio:.*|audio: \"$LECTURE_ROOT/audio/NET301/rec.flac\"|" "$N"
  lecture-file "$N" >/dev/null
  D="$LECTURE_NOTES_ROOT/networks_net301/lectures/07"
  [ -f "$D/rec.flac" ]
  run lecture-forget "$N" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$D/rec.flac" ]; [ ! -e "$D/2026-10-19_lecture-7-routing.md" ]; [ ! -e "$D/2026-10-19_lecture-7-routing.srt" ]
  [ ! -e "$N" ]; [ ! -L "$N" ]; [ ! -L "$LECTURE_ROOT/audio/NET301/rec.flac" ]
  [ ! -d "$D" ]
}

@test "lecture-forget --audio keeps the transcript" {
  mkdir -p "$LECTURE_ROOT/transcripts/NET301" "$LECTURE_ROOT/audio/NET301"
  N="$LECTURE_ROOT/transcripts/NET301/2026-10-19_x.md"; mknote "$N" NET301 en
  printf audio > "$LECTURE_ROOT/audio/NET301/rec.flac"
  sed -i "s|^audio:.*|audio: \"$LECTURE_ROOT/audio/NET301/rec.flac\"|" "$N"
  run lecture-forget --audio "$N" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$LECTURE_ROOT/audio/NET301/rec.flac" ]
  [ -f "$N" ]
  grep -q '^audio: "deleted"' "$N"
}

@test "lecture-retention deletes only audio older than the limit" {
  mkdir -p "$LECTURE_ROOT/transcripts/NET301" "$LECTURE_ROOT/audio/NET301"
  OLD="$LECTURE_ROOT/transcripts/NET301/2025-01-10_old.md"; mknote "$OLD" NET301 en
  NEW="$LECTURE_ROOT/transcripts/NET301/$(date +%F)_new.md"; mknote "$NEW" NET301 en
  sed -i "s/^date: .*/date: 2025-01-10/" "$OLD"
  sed -i "s/^date: .*/date: $(date +%F)/" "$NEW"
  printf a > "$LECTURE_ROOT/audio/NET301/old.flac"; printf b > "$LECTURE_ROOT/audio/NET301/new.flac"
  sed -i "s|^audio:.*|audio: \"$LECTURE_ROOT/audio/NET301/old.flac\"|" "$OLD"
  sed -i "s|^audio:.*|audio: \"$LECTURE_ROOT/audio/NET301/new.flac\"|" "$NEW"
  run lecture-retention --dry-run --days 30
  [[ "$output" == *"would delete"*"old.flac"* ]]
  [ -f "$LECTURE_ROOT/audio/NET301/old.flac" ]
  export LECTURE_AUDIO_RETENTION_DAYS=30
  run lecture-retention
  [ "$status" -eq 0 ]
  [ ! -e "$LECTURE_ROOT/audio/NET301/old.flac" ]
  [ -f "$LECTURE_ROOT/audio/NET301/new.flac" ]
  grep -q 'audio: "deleted (retention 30d)"' "$OLD"
  unset LECTURE_AUDIO_RETENTION_DAYS
  run lecture-retention
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "srtshift appends with an offset and renumbers" {
  python3 -I "$REPO/lib/srtshift.py" "$REPO/tests/fixtures/sample.srt" --append "$BATS_TEST_TMPDIR/c.srt"
  python3 -I "$REPO/lib/srtshift.py" "$REPO/tests/fixtures/sample.srt" --offset 300 --append "$BATS_TEST_TMPDIR/c.srt"
  run cat "$BATS_TEST_TMPDIR/c.srt"
  [[ "$output" == *$'\n5\n00:05:00,000 --> 00:05:03,500\nGood morning'* ]]
  [[ "$output" == *$'\n8\n00:05:15,100 --> 00:05:19,900'* ]]
}

@test "live mode transcribes segments from RAM and keeps no audio" {
  mkdir -p "$BATS_TEST_TMPDIR/fakebin" "$BATS_TEST_TMPDIR/models" "$BATS_TEST_TMPDIR/run"
  printf x > "$BATS_TEST_TMPDIR/models/ggml-large-v3.bin"
  # fake ffmpeg: writes two "segments", then waits for SIGINT like the real one
  cat > "$BATS_TEST_TMPDIR/fakebin/ffmpeg" <<'SH'
#!/usr/bin/env bash
# convert call (-f s16le -i raw wav): write a fake wav. capture call: stream
# 2.5 segments of 60 s x 32000 B raw PCM to stdout, then wait for TERM.
if [[ "$*" == *"-i "*".raw"* ]]; then printf 'wav' > "${@: -1}"; exit 0; fi
trap 'exit 0' TERM
head -c $((60*32000)) /dev/zero; sleep 0.3
head -c $((60*32000)) /dev/zero; sleep 0.3
head -c $((30*32000)) /dev/zero
while :; do sleep 0.2; done
SH
  cat > "$BATS_TEST_TMPDIR/fakebin/whisper-cli" <<'SH'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do [[ "$1" == -of ]] && OF="$2"; shift; done
cp "$REPO_FIXTURES/sample.srt" "$OF.srt"; echo "Good morning everyone." > "$OF.txt"
SH
  cat > "$BATS_TEST_TMPDIR/fakebin/findmnt" <<'SH'
#!/usr/bin/env bash
echo tmpfs
SH
  chmod +x "$BATS_TEST_TMPDIR/fakebin/"*
  export REPO_FIXTURES="$REPO/tests/fixtures" WHISPER_MODELS="$BATS_TEST_TMPDIR/models" LECTURE_NOTES_ENGINE=off
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" LECTURE_LIVE_SEGMENT=60
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" lecture-record net301 "live check" > "$BATS_TEST_TMPDIR/live.out" 2>&1 &
  pid=$!
  sleep 2
  # A job started with & in a non-interactive shell has SIGINT ignored, and bash
  # cannot trap a signal ignored on entry. Ctrl-C in a terminal works. Here the test uses TERM.
  kill -TERM "$pid"
  wait "$pid"; status=$?
  pkill -f "$BATS_TEST_TMPDIR/fakebin/ffmpeg" 2>/dev/null || true
  cat "$BATS_TEST_TMPDIR/live.out"
  [ "$status" -eq 0 ]
  M="$LECTURE_ROOT/transcripts/NET301/$(date +%F)_live-check.md"
  [ -f "$M" ]
  grep -q '^audio: "none (live, not recorded)"' "$M"
  grep -q '00:02:00,000 -->' "${M%.md}.srt"          # third segment shifted by 2 x 60 s
  [ ! -d "$LECTURE_ROOT/audio" ] || [ -z "$(ls -A "$LECTURE_ROOT/audio")" ]
  [ -z "$(find "$XDG_RUNTIME_DIR" -name '*.wav' -o -name '*.raw')" ]
  [ -z "$(find "$XDG_RUNTIME_DIR" -mindepth 2 -type d)" ]
  grep -q "no audio kept" "$BATS_TEST_TMPDIR/live.out"
}

@test "record mode still writes a FLAC to the inbox" {
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  cat > "$BATS_TEST_TMPDIR/fakebin/ffmpeg" <<'SH'
#!/usr/bin/env bash
printf 'x' > "${@: -1}"
SH
  chmod +x "$BATS_TEST_TMPDIR/fakebin/ffmpeg"
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run lecture-record --keep-audio net301 "kept"
  [ "$status" -eq 0 ]
  [ -f "$LECTURE_ROOT/inbox/NET301_$(date +%F)_kept.flac" ]
  export LECTURE_RECORD_MODE=record
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run lecture-record net301 "kept"
  [ -f "$LECTURE_ROOT/inbox/NET301_$(date +%F)_kept-2.flac" ]
}

@test "lp_file_busy sees a file held open for writing" {
  source "$REPO/lib/common.sh"
  F="$BATS_TEST_TMPDIR/busy.flac"; : > "$F"
  run lp_file_busy "$F"; [ "$status" -eq 1 ]
  exec 7>>"$F"
  run lp_file_busy "$F"; [ "$status" -eq 0 ]
  exec 7>&-
  run lp_file_busy "$F"; [ "$status" -eq 1 ]
}

@test "lecture-pending finds pending notes in the vault and runs the engine" {
  export LECTURE_NOTES_ROOT="$HOME/vault"
  D="$LECTURE_NOTES_ROOT/networks_net301/lectures/07"; mkdir -p "$D" "$LECTURE_ROOT/transcripts"
  P="$D/2026-10-19_from-phone.md"; mknote "$P" NET301 en
  S="$D/2026-10-12_short.md"; mknote "$S" NET301 en 50
  run lecture-pending --list
  [[ "$output" == *"from-phone.md"* ]]
  [[ "$output" != *"short.md"* ]]
  [[ "$output" == *"1 pending"* ]]
  export LECTURE_NOTES_CMD="printf '## Notes\n\n- phone lecture\n'"
  run lecture-pending
  [ "$status" -eq 0 ]
  grep -q "notes_status: done (cmd)" "$P"
  grep -q "phone lecture" "$P"
  run lecture-pending --list
  [[ "$output" == *"0 pending"* ]]
}
