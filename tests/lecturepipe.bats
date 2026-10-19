#!/usr/bin/env bats
# Run: bats tests/

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export XDG_CONFIG_HOME="$HOME/.config"
  export LECTURE_ROOT="$HOME/lectures"
  mkdir -p "$LECTURE_ROOT"
  export PATH="$REPO/bin:$PATH"
  unset LECTURE_NOTES_ROOT LECTURE_NOTES_CMD LECTURE_NOTES_ENGINE LECTURE_LLM
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
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run lecture-record net301 "Routing Protocols: OSPF & BGP"
  [ "$status" -eq 0 ]
  [ -f "$LECTURE_ROOT/inbox/NET301_$(date +%F)_routing-protocols-ospf-bgp.flac" ]
  PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" run lecture-record net301 "Routing Protocols: OSPF & BGP"
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
