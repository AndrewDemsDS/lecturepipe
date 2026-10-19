# Privacy and the GDPR

A lecture recording is personal data: the lecturer's voice and anything a student says
in the room. In the EU that puts it under the GDPR, and most universities have their own
rules on recording on top of that. lecturepipe is built so that the default run keeps
nothing that identifies a person, and so that you can honour a deletion request in one
command when you do keep something. None of this is legal advice; it describes what the
software does and the questions you need to settle yourself.

## What is stored, where, by mode

| | live (default) | record (`--keep-audio`) |
|---|---|---|
| Microphone audio | RAM only, one segment at a time (5 min by default), shredded as soon as it is transcribed. Never written to disk. | FLAC under `~/lectures/audio/<COURSE>/`, moved to the vault when filed. |
| Transcript (`.srt .txt .md`) | `~/lectures/transcripts/<COURSE>/`, then the vault | same |
| Whisper JSON (`.json`) | not produced | next to the transcript |
| Notes | inside the `.md` | same |
| Watcher log | `~/lectures/.state/watch.log`: filenames, timings, whisper's progress lines, which include transcript text in record mode | same |
| Index | `~/lectures/INDEX.md`: titles, dates, word counts | same |

Live mode refuses to run if the runtime directory is not a tmpfs, so segments cannot
land on disk by accident (`LECTURE_LIVE_ALLOW_DISK=1` overrides, loudly).

A transcript is still personal data when it contains what people said. The point of live
mode is that the most sensitive item, a voice recording, never exists outside memory.

## What leaves the machine

Nothing, unless you configure it:

- A **cloud notes engine** (Claude Code, Codex, Gemini CLI, a hosted API) receives the
  transcript, the slide text, and the outlines of sibling recordings. Those providers are
  typically outside the EU; that is an international transfer in GDPR terms, and your
  account terms with the provider govern retention and training use. Use a local engine
  (Ollama, llama.cpp, the built-in map-reduce) if that is not acceptable. With a local
  model configured, `auto` prefers it, and the tool says so when it falls back to a cloud
  CLI.
- `lecture-setup` downloads models from Hugging Face and, if you accept, sends the line
  "Reply with the word OK" through the engine you picked.

## Lawful basis, in plain terms

- **Tell people.** Recording or transcribing someone without their knowledge is the
  problem regulators and universities act on. `lecture-record` prints a
  reminder every time. Ask the lecturer once at the start of term; many will say yes to a
  transcript for personal study and no to a recording that could be shared.
- **Personal study is the narrowest footprint.** Notes for your own revision, kept on your
  own laptop, is about as far from "processing at scale" as it gets, and the GDPR's
  household exemption (Art. 2(2)(c)) is often read to cover it. Sharing transcripts, syncing
  them to a cloud, or recording other students' questions moves you out of that comfort
  zone. A Nextcloud or Obsidian sync of the vault is such a transfer: know where that server
  is.
- **Minimise.** Live mode exists for this: the transcript is what you need, the voice is
  not. If you do keep audio, set `LECTURE_AUDIO_RETENTION_DAYS` so it goes away on its own
  (`lecture-retention` runs after every watcher pass).
- **Be able to delete.** `lecture-forget <note.md>` removes the audio, every derived file,
  the symlinks and the vault copies, then rebuilds the index. `lecture-forget --course CODE`
  removes a whole course. `--audio` keeps the transcript and drops only the recording.
  If a lecturer or classmate asks you to delete something, this is the command.
- **Course glossaries are personal data too.** `courses.conf` holds lecturer names if you
  put them there (it helps Whisper spell them). It stays under `~/lectures` and is not part
  of this repository; the shipped file is an example.

## Checklist before the first lecture

1. Have you told the lecturer? Do they object to a recording, a transcript, or neither?
2. Is `LECTURE_RECORD_MODE` what you want? Live is the default; record only if you need the audio.
3. If record: is `LECTURE_AUDIO_RETENTION_DAYS` set to something you can justify?
4. Is the notes engine local, or are you fine with the transcript going to that provider?
5. Does your vault sync somewhere? If so, that server is part of your processing.
