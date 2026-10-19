# lecturepipe

Record a lecture, close the laptop, open a finished study note later. Everything runs
on the machine: ffmpeg records, whisper.cpp transcribes, a small set of shell scripts
files the result next to your slides. The one optional step that can leave the machine
is the notes pass, and you choose what runs it.

```
lecture-record NET301 "routing protocols"      Ctrl-C when the lecture ends
          │
          ▼
    inbox/  ──►  systemd path unit  ──►  whisper.cpp  ──►  notes engine  ──►  vault/<course>/lectures/NN/
                 (idle priority)         (large-v3)        (your choice)      .md .srt .txt .json .flac
```

Built for Greek lectures full of English jargon on a laptop with an integrated AMD GPU,
and used daily for a semester. Nothing in it is specific to that.

## What you get

One Markdown file per lecture:

1. **Frontmatter**: course, date, length, word count, language, model, where the audio is.
2. **Notes**: summary, outline with timestamps, key concepts as the lecturer defined them,
   commands and code, examples, announcements and deadlines, likely exam questions. When
   the slide deck is next to the note, every point carries its slide number and the notes
   list the slides that were skipped.
3. **Transcript**: everything said, in paragraphs stamped `[HH:MM:SS]` so you can jump back
   to the audio. Obsidian reads the file as is.

Plus `.srt`, `.txt` and `.json` from Whisper, the FLAC itself, and an `INDEX.md` across
all courses.

## Install

Needs Linux with systemd (user session), PipeWire or PulseAudio, `ffmpeg`, `python3`,
and `whisper-cli` from [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (Arch:
`pacman -S whisper-cpp ggml-vulkan`; elsewhere build it with your GPU backend).
Optional: `pdftotext` and `pdfinfo` from poppler for slides in the notes.

```sh
git clone https://github.com/AndrewDemsDS/lecturepipe
cd lecturepipe && ./install.sh
```

`install.sh` symlinks the commands into `~/.local/bin`, installs the systemd units, and
runs `lecture-setup`. The wizard checks the dependencies, asks for directories, offers to
download the Whisper models (3.1 GB for `large-v3`, 1.6 GB for `turbo`), lists your
microphones and records a three second level test, finds installed LLM CLIs and sends a
test prompt through the one you pick, writes `courses.conf`, and arms the watcher. Re-run
it any time, current values are the defaults. `lecture-setup --defaults` answers everything
without asking.

The result is a plain shell file at `~/.config/lecturepipe/config`
([example](examples/config)). Environment variables with the same names override it.

## In the classroom

```sh
lecture-record NET301 "routing protocols"
```

First word is the course code, second the topic. Put the laptop where it hears the
lecturer, leave the terminal open, press Ctrl-C at the end. You will see `✔ saved`.
Transcription starts on its own at idle priority, survives suspend, and does not fight you
for the laptop.

```sh
lecture-status            # recording? queued? transcribing? which engine? last 5 lectures
```

Not recorded by you? Drop any file ffmpeg reads into `~/lectures/inbox/`, named
`COURSE_YYYY-MM-DD_topic.ext`. Course and date come from the name, with sensible fallbacks.

Online lecture? Record what the laptop plays instead of the room: `lecture-setup` lists
the `.monitor` sources, or set `LECTURE_MIC` to one for a single run.

## Courses: the accuracy lever

`~/lectures/courses.conf`, one line per course ([example](examples/courses.conf)):

```
NET301 | en | Computer Networks, Prof. Example. Terms: TCP, UDP, OSPF, BGP, NAT, MTU.
HIS210 | de | Neuere Geschichte | notes=off
DEFAULT | en | University lecture.
```

The language is pinned on purpose. Whisper detects language once per file and commits, so
`auto` on a Greek lecture with English terms can turn the whole transcript into an English
translation. Pin it and the local language carries the sentence while the English terms are
recognised in place.

The glossary is passed to Whisper as its prompt and carried through the entire recording.
Lecturer names, tool names and acronyms the lecturer uses belong there. Keep it
under about 40 terms, the prompt is capped at 224 tokens.

## Notes engine

`lecture-notes` builds a prompt and pipes it to any command that reads stdin and prints
Markdown. Claude Code, Codex, Gemini CLI, Ollama, llama.cpp, a curl to an
OpenAI-compatible server, or the built-in offline map-reduce over `llama-server`. The wizard
detects what is installed. Recipes and the fallback order are in
[docs/notes-engines.md](docs/notes-engines.md).

Prompts live in `lib/prompts/notes.<lang>.md` and are chosen by the course language
(Greek and English shipped). They tell the model that the transcript has recognition errors,
to recover terms from context instead of inventing them, and to prefer the slides for
spelling, numbers and code.

Notes are a separate pass. The transcript is never at risk, and you can redo the notes with
another engine by deleting the `notes_status` line and running `lecture-notes` on the file.

## Filing into a notes vault

With a vault configured, a finished lecture moves to
`<vault>/<anything>_<course>/lectures/NN/` and symlinks are left behind so the index and
status keep working. `NN` comes from `lecture-N` in the recording name; without one, the
lecture goes under `lectures/<date>/` for you to sort. Slide PDFs already in that folder are
used by the notes pass, so download the deck before the recording ends. A PDF named after
the folder (`07/07.pdf`) is taken as the deck and other PDFs are treated as extra reading.

## Commands

| Command | Does |
|---|---|
| `lecture-setup` | Configuration wizard. `--defaults` for scripts. |
| `lecture-record COURSE ["topic"]` | Record into the inbox. Ctrl-C to stop. |
| `lecture-transcribe FILE [-m turbo] [--no-notes]` | Process one file by hand. |
| `lecture-notes NOTE.md [slides.pdf ...]` | Run or redo the notes pass. |
| `lecture-watch` | Drain the inbox now. |
| `lecture-file NOTE.md [NN]` | File into the vault by hand, or fix a lecture number. |
| `lecture-index` | Rebuild `INDEX.md`. |
| `lecture-status` | What is happening. |
| `lecture-later [--quiet] CMD...` | Run a job once no recording is in progress. |
| `lecture-quiet CMD...` | Run a job with GPU clocks capped (AMD, needs polkit). |

Watcher: `systemctl --user status lecture-watch.path`, log in `~/lectures/.state/watch.log`.

## Design notes, measured

- **Batch, not live.** Streaming forces a small model and short context and cannot revise a
  word once emitted, which is exactly what hurts when a sentence mixes two languages.
  `large-v3` after the fact ran at 2.4x realtime on a Radeon 780M over Vulkan, `turbo` at
  7.5x. A two hour lecture is 50 minutes of background work you do not notice.
- **`-mc 0` is load-bearing.** Whisper conditions each window on its own previous output, so
  one repeated sentence can reinforce itself into an endless loop. That cost an hour of a real
  lecture once. `srt2md.py` also measures repetition and stamps `repetition_warning:` in the
  frontmatter rather than filing silent garbage.
- **No noise suppression.** On a real take, RNNoise made the audio measurably cleaner and the
  transcript measurably worse (a dropped clause, two word errors). Whisper is trained on noisy
  speech. The chain is `adeclip`, a highpass at 80 Hz and `loudnorm`, nothing else. Fix noise
  at the microphone: a cheap clip-on mic at the front of the room beats any model upgrade.
- **Check your gain.** The reference laptop shipped with +24 dB mic boost stacked on a loud
  PipeWire volume and clipped 1,791 samples in 76 seconds. `lecture-setup` records a level
  test; speech should sit between roughly -35 and -15 dB RMS. To check a recording,
  `Peak count` near zero is what you want:

  ```sh
  ffmpeg -i FILE -af astats=metadata=1:reset=0 -f null /dev/null 2>&1 | grep -E "Peak count|RMS level"
  ```

- **Small local models repeat errors as fact.** A 12B model invented a tool out of transcript
  noise and never worked out that "Basics" meant `base64`. Larger models repair those. Read the
  first few sets of notes against the transcript, whatever you use.

## Known issues

- `ffmpeg` may print `non monotonically increasing dts to muxer` mid-recording. Cosmetic:
  the capture source handed it packets with timestamps going backwards, a few milliseconds
  are lost, the file is fine.
- Closing the lid freezes ffmpeg; after resume it keeps appending room audio until Ctrl-C.
  Trim with `ffmpeg -t` to the lecturer's sign-off and drop the file back in the inbox.
- A recording cut off hard leaves a FLAC without a duration. Re-encode it with ffmpeg first.
- When re-queueing a file, stop `lecture-watch.path` before `lecture-watch.service` and swap
  files only while the path unit is stopped, or the watcher re-transcribes the old file.

## Tests

```sh
tests/run.sh      # shellcheck, py_compile, bats
```

## AI assistance

This project was developed with AI assistance (Claude Code), working from a pipeline the
author had built and used for a semester, and from measurements on the reference laptop.
The scripts, prompts and this README were reviewed and the pipeline was run end to end on a
real recording before publishing.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
