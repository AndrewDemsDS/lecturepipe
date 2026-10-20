# shellcheck shell=bash
# Shared setup for every lecture-* command. Source, do not execute.
#
# Resolution order for every setting: environment variable, then
# ~/.config/lecturepipe/config, then the default below.

LECTUREPIPE_LIB="${LECTUREPIPE_LIB:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}"
LECTUREPIPE_CONFIG="${LECTUREPIPE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/lecturepipe/config}"

# Remember what the environment set, source the file, then let the environment win.
_lp_env_keys=(LECTURE_ROOT LECTURE_NOTES_ROOT WHISPER_MODELS LECTURE_MODEL LECTURE_MIC
  LECTURE_NOTES_ENGINE LECTURE_NOTES_CMD LECTURE_LLM LECTURE_LLM_CTX LECTURE_THREADS
  LECTURE_GPU_CARD LECTURE_NOTES_SLIDES LECTURE_SLIDES_MAX_PAGES LECTURE_SLIDES_MAX_BYTES
  LECTURE_AUDIO_RETENTION_DAYS LECTURE_RECORD_MODE LECTURE_LIVE_SEGMENT)
declare -A _lp_env=()
for _k in "${_lp_env_keys[@]}"; do
  [[ -n "${!_k+x}" ]] && _lp_env[$_k]="${!_k}"
done
if [[ -f "$LECTUREPIPE_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$LECTUREPIPE_CONFIG"
fi
for _k in "${!_lp_env[@]}"; do
  printf -v "$_k" '%s' "${_lp_env[$_k]}"
done
unset _k _lp_env _lp_env_keys

LECTURE_ROOT="${LECTURE_ROOT:-$HOME/lectures}"
LECTURE_NOTES_ROOT="${LECTURE_NOTES_ROOT:-}"            # empty: never file into a vault
WHISPER_MODELS="${WHISPER_MODELS:-$HOME/.local/share/whisper-models}"
LECTURE_MODEL="${LECTURE_MODEL:-large}"                 # large | turbo
LECTURE_RECORD_MODE="${LECTURE_RECORD_MODE:-live}"      # live (no audio kept) | record (FLAC to inbox)
LECTURE_LIVE_SEGMENT="${LECTURE_LIVE_SEGMENT:-300}"     # seconds of audio held in RAM per live segment
LECTURE_MIC="${LECTURE_MIC:-}"                          # pactl source name, empty = default
LECTURE_NOTES_ENGINE="${LECTURE_NOTES_ENGINE:-auto}"    # auto | cmd | local | off
LECTURE_NOTES_CMD="${LECTURE_NOTES_CMD:-}"              # reads prompt on stdin, markdown on stdout
LECTURE_LLM="${LECTURE_LLM:-}"                          # GGUF for the local engine
LECTURE_LLM_CTX="${LECTURE_LLM_CTX:-16384}"
LECTURE_THREADS="${LECTURE_THREADS:-$(nproc 2>/dev/null || echo 4)}"
LECTURE_GPU_CARD="${LECTURE_GPU_CARD:-}"
LECTURE_AUDIO_RETENTION_DAYS="${LECTURE_AUDIO_RETENTION_DAYS:-}"   # empty: keep audio
LECTURE_NOTES_SLIDES="${LECTURE_NOTES_SLIDES:-on}"
LECTURE_SLIDES_MAX_PAGES="${LECTURE_SLIDES_MAX_PAGES:-150}"
LECTURE_SLIDES_MAX_BYTES="${LECTURE_SLIDES_MAX_BYTES:-300000}"
export LECTURE_ROOT LECTURE_NOTES_ROOT WHISPER_MODELS LECTURE_MODEL LECTURE_MIC \
  LECTURE_NOTES_ENGINE LECTURE_NOTES_CMD LECTURE_LLM LECTURE_LLM_CTX LECTURE_THREADS \
  LECTURE_GPU_CARD LECTURE_NOTES_SLIDES LECTURE_SLIDES_MAX_PAGES LECTURE_SLIDES_MAX_BYTES \
  LECTURE_AUDIO_RETENTION_DAYS LECTURE_RECORD_MODE LECTURE_LIVE_SEGMENT LECTUREPIPE_LIB

# The commands call each other by name; make sure the repo's own bin/ wins.
case ":$PATH:" in *":$LECTUREPIPE_LIB/../bin:"*) ;; *) export PATH="$LECTUREPIPE_LIB/../bin:$PATH" ;; esac

lp_courses_conf() { printf '%s\n' "$LECTURE_ROOT/courses.conf"; }

# lp_course_lookup CODE -> "lang<TAB>glossary<TAB>opts" or nothing.
lp_course_lookup() {
  local conf; conf="$(lp_courses_conf)"
  [[ -f "$conf" ]] || return 0
  awk -F'|' -v c="$1" '
    /^[[:space:]]*#/ || NF < 3 { next }
    { code=$1; gsub(/^[ \t]+|[ \t]+$/,"",code)
      if (toupper(code) != toupper(c)) next
      lang=$2; gsub(/^[ \t]+|[ \t]+$/,"",lang)
      last=$NF; gsub(/^[ \t]+|[ \t]+$/,"",last)
      opts=""; hi=NF
      if (NF >= 4 && last ~ /^notes=/) { opts=last; hi=NF-1 }
      prompt=$3; for(i=4;i<=hi;i++) prompt=prompt "|" $i
      gsub(/^[ \t]+|[ \t]+$/,"",prompt)
      print lang "\t" prompt "\t" opts; exit }' "$conf"
}

# Lecture number from a file stem: "lecture-7-awk" -> 7. Empty when absent.
lp_lecture_number() {
  printf '%s' "$1" | grep -oiE '(lecture|lec|dialexi)[-_ ]?[0-9]{1,2}' | grep -oE '[0-9]+$' | head -1 || true
}

# The vault folder for COURSE: the single ~/notes/*_<course> directory, or nothing.
lp_vault_course_dir() {
  [[ -n "$LECTURE_NOTES_ROOT" ]] || return 0
  local course="${1,,}" dirs
  shopt -s nullglob
  dirs=("$LECTURE_NOTES_ROOT"/*_"$course")
  shopt -u nullglob
  [[ -d "$LECTURE_NOTES_ROOT/$course" ]] && dirs+=("$LECTURE_NOTES_ROOT/$course")
  [[ ${#dirs[@]} -eq 1 ]] && printf '%s\n' "${dirs[0]}"
  return 0
}

# Is some process holding FILE open for writing? Reads /proc directly, so it needs
# no lsof or fuser and sees only this user's processes, which is who records.
lp_file_busy() {
  local target fd
  target="$(readlink -f "$1")" || return 1
  for fd in /proc/[0-9]*/fd/*; do
    [[ "$(readlink "$fd" 2>/dev/null)" == "$target" ]] || continue
    # fdinfo flags: octal, O_WRONLY=01 or O_RDWR=02 in the low bits
    local flags; flags="$(awk '/^flags:/{print $2}' "${fd/fd\//fdinfo/}" 2>/dev/null)"
    [[ -n "$flags" && $(( 8#$flags & 3 )) -ne 0 ]] && return 0
  done
  return 1
}

# A recording is an ffmpeg process capturing from PulseAudio/PipeWire. Match the
# process name first: `pgrep -f` alone also matches any shell whose command line
# merely contains the pattern (a terminal running `pgrep ...`, an editor, a script).
lp_recorder_args() { pgrep -a -x ffmpeg 2>/dev/null | grep -- '-f pulse'; }
lp_recording_running() { [[ -n "$(lp_recorder_args)" ]]; }

# Which notes engine would run right now: cmd, local or off. Sets LECTURE_NOTES_CMD
# when a CLI is auto-detected.
# shellcheck disable=SC2034  # LP_AUTO_CLOUD is read by lecture-notes and lecture-status
lp_resolve_notes_engine() {
  case "$LECTURE_NOTES_ENGINE" in
    off)   echo off; return ;;
    local) echo local; return ;;
    cmd)   [[ -n "$LECTURE_NOTES_CMD" ]] && { echo cmd; return; }
           echo off; return ;;
  esac
  if [[ -n "$LECTURE_NOTES_CMD" ]]; then echo cmd; return; fi
  # A configured local model wins over any cloud CLI: nothing leaves the machine unless asked.
  if [[ -n "$LECTURE_LLM" && -f "$LECTURE_LLM" ]] && command -v llama-server >/dev/null 2>&1; then echo local; return; fi
  if command -v claude >/dev/null 2>&1; then LECTURE_NOTES_CMD="claude -p --permission-mode plan"; LP_AUTO_CLOUD=1; echo cmd; return; fi
  if command -v codex  >/dev/null 2>&1; then LECTURE_NOTES_CMD="codex exec -"; LP_AUTO_CLOUD=1; echo cmd; return; fi
  if command -v gemini >/dev/null 2>&1; then LECTURE_NOTES_CMD="gemini -p \"\$(cat)\""; LP_AUTO_CLOUD=1; echo cmd; return; fi
  echo off
}
