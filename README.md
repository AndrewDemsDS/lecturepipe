# lecturepipe

Record a lecture, close the laptop, open a finished study note later. Everything runs
on the machine: ffmpeg records, whisper.cpp transcribes, a small set of shell scripts
files the result next to your slides. The one optional step that can leave the machine
is the notes pass, and you choose what runs it.

```
lecture-record NET301 "routing protocols"          Ctrl-C when the lecture ends
          │
          ├─ live (default)  mic ──► 5 min segments in RAM ──► whisper.cpp ──► text; audio shredded
          │
          └─ --keep-audio    mic ──► inbox/*.flac ──► systemd path unit ──► whisper.cpp
                                                        (idle priority)
                                                                 │
                                                                 ▼
                                             notes engine (your choice) ──► vault/<course>/lectures/NN/
```

By default no audio is ever written to disk: the microphone is transcribed in five minute
segments held in memory, each shredded the moment its text exists. Keeping a recording is
an explicit opt-in. See [docs/privacy.md](docs/privacy.md) for what is stored where and
what that means under the GDPR.

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
lecturer, leave the terminal open, press Ctrl-C at the end. In live mode the text scrolls
by as each segment is transcribed, and at Ctrl-C the note, notes pass and filing run at
once. The GPU works during the lecture, so expect some fan noise; `turbo` keeps it short.

```sh
lecture-record --keep-audio NET301 "routing protocols"
```

saves a FLAC to the inbox instead and transcribes afterwards at idle priority. You keep
the audio to re-listen or re-transcribe, and you take on keeping it: set
`LECTURE_AUDIO_RETENTION_DAYS` so it expires, and `lecture-forget` erases a lecture with
everything derived from it. `LECTURE_RECORD_MODE="record"` in the config makes this the
default.

```sh
lecture-status            # recording? queued? transcribing? which engine? last 5 lectures
```

Labs and recitations go through the same pipeline and are filed in their own folders:

```sh
lecture-record --lab 3 NET301 "sockets"           # NET301_<date>_lab-03-sockets
lecture-record --recitation 2 NET301              # NET301_<date>_recitation-02
```

The number is optional (`--lab NET301`), and `--lecture 7` numbers a lecture the same way.

Not recorded by you? Drop any file ffmpeg reads into `~/lectures/inbox/`, named
`COURSE_YYYY-MM-DD_topic.ext`. Course and date come from the name, with sensible fallbacks.
Put `lab-3` or `recitation-3` in the topic to mark the kind (see
[Filing](#filing-into-a-notes-vault)).

Two recordings with the same name (two unnumbered labs on one day, say) never overwrite
each other: the second is called `<name>-take2`, the next `-take3`. The phone app uses the
same suffix. A `-take<N>` at the end of a name is not a session number, so `lab-take2`
is an unnumbered lab and `lab-2` is still lab 2.

A recording can bring an info file with the same name, `<name>.json`. The phone app
uploads one before the audio. When the audio is taken from the inbox, its `course`,
`kind` and `number` win over the name, `topic` becomes the title (Greek is fine) and
`language` wins over `courses.conf` for that run. The info file goes away with the audio.
A broken one is noted in `watch.log` and the name is used instead.

Online lecture? Record what the laptop plays instead of the room: `lecture-setup` lists
the `.monitor` sources, or set `LECTURE_MIC` to one for a single run.

## Courses: the accuracy lever

`~/lectures/courses.conf`, one line per course ([example](examples/courses.conf)):

```
NET301 | en | Computer Networks, Prof. Example. Terms: TCP, UDP, OSPF, BGP, NAT, MTU.
HIS210 | de | Neuere Geschichte | notes=off
DEFAULT | en | University lecture.
```

A course code starts with a letter and has 2 to 12 ASCII letters, digits or hyphens in
all: `NET301` and `CS-101` work, `X`, `ΜΑΘ101` and `NET_301` do not. Case does not
matter: codes are stored in upper case. The phone app checks codes against the same rule. A recording
name starts with the code and a `_`, so the code itself never contains one.

`notes=off` at the end of a line means no notes for that course, from any command:
`lecture-transcribe`, `lecture-notes` and `lecture-pending` all leave its transcripts alone.

The language is pinned on purpose. Whisper detects language once per file and commits, so
`auto` on a Greek lecture with English terms can turn the whole transcript into an English
translation. Pin it and the local language carries the sentence while the English terms are
recognised in place.

The glossary is passed to Whisper as its prompt and carried through the entire recording.
Lecturer names, tool names and acronyms the lecturer uses belong there. Keep it
under about 40 terms. Whisper's context is capped at 224 tokens, so the glossary gets at
most 223 and Whisper keeps the end of a longer one. Each glossary's token count is
measured once, by `lecture-setup` or by the first run that uses it, and cached in
`~/lectures/.state/prompt-ctx.cache`.

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

## Privacy

Live mode keeps no audio. Record mode keeps a FLAC you can expire with a retention
setting or erase with `lecture-forget`. Full data map and GDPR notes:
[docs/privacy.md](docs/privacy.md).

Recording, transcription, filing and indexing never open a network connection. The
things that can:

- **The notes pass**, when the engine you chose is a cloud service (Claude Code, Codex,
  Gemini CLI, a hosted API). It receives the full transcript, the slide text, and the
  outlines of sibling recordings. Ollama, llama.cpp and the built-in local engine keep it
  on the machine. With a local model configured, `auto` prefers it over any cloud CLI;
  when `auto` falls back to a cloud CLI, `lecture-notes` and `lecture-status` say so.
- **`lecture-setup`**, when you accept a model download (Hugging Face) or the one-line
  engine test ("Reply with OK").

Audio, transcripts and `courses.conf` stay under `~/lectures` and your vault. Lecturer
names and course codes in `courses.conf` are yours alone; the repo ships an example.

## Filing into a notes vault

With a vault configured, a finished lecture moves to
`<vault>/<CODE Title>/lectures/NN/` (for example `NET301 Computer Networks/lectures/07/`, older
`<title>_<code>` folders still match) and symlinks are left behind so the index and
status keep working. `NN` comes from `lecture-N` in the recording name; without one, the
lecture goes under `lectures/<date>/` for you to sort.

Labs and recitations work the same way in `labs/NN/` and `recitations/NN/`, numbered
separately. The kind comes from the first of these words in the recording name, upper or
lower case, with an optional `-`, `_` or space before a 1 or 2 digit number:

| Kind | Words | Folder |
|---|---|---|
| lecture | `lecture`, `lec`, `dialexi` | `lectures/NN/` |
| lab | `lab`, `ergastirio` | `labs/NN/` |
| recitation | `recitation`, `frontistirio` | `recitations/NN/` |

A word only counts on its own: `syllabus` or `collaboration` is not a lab. A name with none
of them is a lecture, so older names file as before. The number is the first one written
after a word of the same kind, so `routing-lab-4-lecture-5` is lab 4. The notes pass is told
the kind and asks for steps, commands and setup in a lab, and for the worked problems and
their solutions in a recitation. Slide PDFs already in that folder are
used by the notes pass, so download the deck before the recording ends. A PDF named after
the folder (`07/07.pdf`) is taken as the deck and other PDFs are treated as extra reading.

If the folder already holds a file with the same name (the phone app filed that session
already, say), the new one is filed as `<name>-take2`. `lecture-file` only says `filed`
when the note really moved. Otherwise it exits with an error and leaves the files where
they are.

The phone app puts a note in `<vault>/_unfiled/<date>/` when no single course folder
matches. `lecture-pending` writes notes for those too and lists them with the folder they
belong in, so you can move them. A note the phone kept for its own notes engine
(`notes_status: queued (phone)`) is handed to the laptop's engine once it is a day old.

## Duplicate recordings

A recording that reaches the inbox twice, say the phone app uploading one file under two
names, is transcribed once. `lecture-transcribe` hashes every recording (sha256 of the
bytes as they arrived) before it spends GPU time on it and lists it in
`~/lectures/.state/audio-sha256.tsv` with its name, the intake time and the note it
became. A recording whose hash is already listed is moved to `~/lectures/.state/duplicates/`
(never deleted), and `watch.log` gets a `dup:` line naming the earlier recording. A run
that fails takes its row out again, so a fixed file can go back in the inbox.

Only byte-identical files match. A FLAC made from the same WAV, or a trimmed copy, is a
new recording. To count audio you already have, hash the archive once (symlinks into the
vault are followed):

```sh
lecture-dedup --backfill
```

To transcribe a listed recording again on purpose, run `lecture-transcribe --force FILE`,
or drop it from the list with `lecture-dedup --forget FILE` and queue it as usual.
`LECTURE_DEDUP=off` turns the check off.

## Commands

| Command | Does |
|---|---|
| `lecture-setup` | Configuration wizard. `--defaults` for scripts. |
| `lecture-record COURSE ["topic"]` | Live transcription, no audio kept. Ctrl-C to stop. |
| `lecture-record --keep-audio COURSE ["topic"]` | Record a FLAC into the inbox for later. |
| `lecture-record --lab [NN] \| --recitation [NN] COURSE ["topic"]` | Mark a lab or a recitation. Combines with the options above. |
| `lecture-forget NOTE.md \| --course CODE [--audio]` | Erase a lecture and everything derived from it. |
| `lecture-retention [--dry-run]` | Delete audio older than `LECTURE_AUDIO_RETENTION_DAYS`. |
| `lecture-transcribe FILE [-m turbo] [--no-notes] [--force]` | Process one file by hand. `--force` transcribes a duplicate anyway. |
| `lecture-notes NOTE.md [slides.pdf ...]` | Run or redo the notes pass. |
| `lecture-watch` | Drain the inbox now. |
| `lecture-pending [--list]` | Notes for transcripts that arrived without them (phone app, failed runs, phone-queued notes older than a day). Lists notes in `_unfiled/`. Also moves finished recordings the phone app uploaded to `.lecturepipe-inbox/` in the notes vault into `inbox/`, with their info files. Runs every 15 min from a timer. |
| `lecture-dedup FILE \| --backfill \| --forget FILE \| --list` | Was this recording taken in before; hash the archive once; let a file be queued again. |
| `lecture-file NOTE.md [NN]` | File into the vault by hand, or fix a lecture, lab or recitation number. |
| `lecture-index` | Rebuild `INDEX.md`. |
| `lecture-status` | What is happening. |
| `lecture-later [--quiet] CMD...` | Run a job once no recording is in progress. |
| `lecture-quiet CMD...` | Run a job with GPU clocks capped (AMD, needs polkit). |

Watcher: `systemctl --user status lecture-watch.path`, log in `~/lectures/.state/watch.log`.

## Design notes, measured

- **Segments, not streaming.** Word-by-word streaming forces a small model and a short
  context and cannot revise a word once emitted, which is exactly what hurts when a
  sentence mixes two languages. Live mode instead runs the full `large-v3` on five minute
  segments, so quality matches a batch run except at the segment edges. `large-v3` ran at
  2.4x realtime on a Radeon 780M over Vulkan, `turbo` at 7.5x: a segment is done well
  before the next one closes.
- **Zero rolling context is load-bearing.** Whisper conditions each window on its own previous
  output, so one repeated sentence can reinforce itself into an endless loop. That cost an hour
  of a real lecture once. Plain `-mc 0` prevents that but also drops the glossary, because
  whisper.cpp then builds no prompt at all. So `-mc` is set to the glossary's token count + 1:
  the glossary takes all of it but one slot, and the rolling text gets nothing. On a 5 minute
  Greek clip that raised glossary terms spelled as listed from 6 to 9, with no loop.
  `srt2md.py` also measures repetition and stamps `repetition_warning:` in the frontmatter
  rather than filing silent garbage.
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
  A file with the same bytes as one already transcribed is set aside as a duplicate: run
  `lecture-dedup --forget FILE` before putting it back, or use `lecture-transcribe --force FILE`.

## Tests

```sh
tests/run.sh      # shellcheck, py_compile, bats
```

## AI assistance

This project was developed with AI assistance, working from a pipeline the author had
built and used for a semester, and from measurements on the reference laptop. The
scripts, prompts and this README were reviewed and the pipeline was run end to end on a
real recording before publishing.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
