# lecturepipe: design

Date: 2026-10-19. Status: agreed.

## Purpose

Turn a shell pipeline that lived in one user's `~/.local/bin` into a project other
people can install: record a lecture, drop it in an inbox, get a transcript and study
notes back, filed next to the slides. Everything except the optional notes pass runs on
the laptop.

## Decisions

- Name `lecturepipe`, licence GPL-3.0-or-later, published at github.com/AndrewDemsDS.
- Command names stay `lecture-*`. Existing users (one) keep working after `install.sh`
  with no changes to `~/lectures` or `courses.conf`.
- The notes pass is agent agnostic. `LECTURE_NOTES_CMD` is any command that reads the
  prompt on stdin and writes Markdown to stdout. The repo ships recipes for Claude
  Code, Codex, Gemini CLI, Ollama, llama.cpp and plain HTTP. With no command set, the
  first CLI found is used; with none found, the local llama-server map-reduce engine
  runs; with no model either, notes are skipped and the transcript is kept.
- Prompts are files under `lib/prompts/`, chosen by the course language (`el`, `en`,
  fallback `en`). The Greek prompt is the one in production today.
- All personal data moves to `~/.config/lecturepipe/config` (shell syntax, sourced).
  Environment variables override the file. The repo holds an example only.
- `lecture-setup` is an interactive wizard that writes that config: dependencies,
  directories, Whisper models (with download), microphone, notes engine (with a live
  test), courses, systemd unit. `--defaults` answers everything non-interactively.
- `lecture-quiet` stays but is AMD-only and says so; the card path is configurable.
- RNNoise models are dropped: measured to hurt accuracy, never wired in.

## Layout

```
bin/        lecture-setup record watch transcribe notes notes-local file index status later quiet
lib/        common.sh  srt2md.py  notes.py (prompt + merge)  notes_local.py  prompts/
systemd/    lecture-watch.path  lecture-watch.service
examples/   config  courses.conf
tests/      bats suite + fixtures, shellcheck
install.sh  uninstall.sh
```

## Interfaces

- `courses.conf`: `CODE | lang | glossary [| notes=off]`, unchanged.
- Note file: YAML frontmatter, `LECTURE-NOTES` markers, `## Transcript`, unchanged.
- Config keys: `LECTURE_ROOT`, `LECTURE_NOTES_ROOT`, `WHISPER_MODELS`, `LECTURE_MODEL`,
  `LECTURE_MIC`, `LECTURE_NOTES_ENGINE` (auto|cmd|local|off), `LECTURE_NOTES_CMD`,
  `LECTURE_LLM`, `LECTURE_THREADS`, `LECTURE_GPU_CARD`.

## Testing

shellcheck on every script; bats: srt2md on a fixture, repetition warning, courses.conf
lookup, notes prompt build and merge with a fake engine (`cat` of a canned answer),
install into a temp HOME, wizard `--defaults` into a temp HOME. Then a real 30 s
recording on the reference laptop through the watcher.

## Out of scope

Live transcription, a GUI, Windows or macOS, speaker diarisation.
