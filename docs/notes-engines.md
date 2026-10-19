# Notes engines

After a lecture is transcribed, `lecture-notes` builds one plain-text prompt (the
transcript, the slide text when a PDF sits next to the note, and the outlines of other
recordings of the same lecture) and pipes it into `LECTURE_NOTES_CMD`. That command
reads stdin and prints Markdown on stdout. The exit code decides success. Anything
that fits that shape works.

Set it in `~/.config/lecturepipe/config` (or let `lecture-setup` pick one):

```sh
LECTURE_NOTES_ENGINE="cmd"
LECTURE_NOTES_CMD="..."
```

Try a command before trusting it with a two-hour lecture:

```sh
echo "Reply with the word OK." | bash -c "$LECTURE_NOTES_CMD"
```

## Recipes

| Engine | `LECTURE_NOTES_CMD` | Notes |
|---|---|---|
| Claude Code | `claude -p --permission-mode plan` | Plan mode blocks tool use. Transcript leaves the machine. |
| Codex CLI | `codex exec -` | `-` reads the prompt from stdin. |
| Gemini CLI | `gemini -p "$(cat)"` | Gemini takes the prompt as an argument, so wrap stdin. |
| Ollama | `ollama run gemma3:12b` | Local. Pick a model that handles your lecture language. |
| llama.cpp | `llama-cli -m model.gguf -c 32768 -n 2500 --no-display-prompt -f /dev/stdin` | Local. Context must fit the whole transcript. |
| Any OpenAI-compatible server | see below | LM Studio, vLLM, llama-server, OpenRouter, ... |
| Local map-reduce | `LECTURE_NOTES_ENGINE="local"` and `LECTURE_LLM=/path/model.gguf` | Built in. Starts `llama-server` itself, chunks the transcript, works offline on small context windows. |

OpenAI-compatible HTTP, as a small script you point the command at:

```sh
#!/usr/bin/env bash
# ~/.local/bin/notes-via-http: LECTURE_NOTES_CMD="notes-via-http"
set -euo pipefail
URL="${LLM_URL:-http://127.0.0.1:1234/v1/chat/completions}"
MODEL="${LLM_MODEL:-local-model}"
jq -Rs --arg m "$MODEL" '{model:$m, temperature:0.2, messages:[{role:"user",content:.}]}' \
  | curl -sS --fail -H "Content-Type: application/json" -H "Authorization: Bearer ${LLM_KEY:-none}" \
      -d @- "$URL" \
  | jq -r '.choices[0].message.content'
```

## Order of resolution

With `LECTURE_NOTES_ENGINE="auto"` (the default):

1. `LECTURE_NOTES_CMD`, if set.
2. The first of `claude`, `codex`, `gemini` found on PATH.
3. The local map-reduce engine, if `LECTURE_LLM` points at a model and `llama-server` exists.
4. Otherwise notes are skipped. The transcript is complete without them.

If the command fails and a local model is configured, the local engine runs as a fallback.

## What the engine must do well

A lecture-hall transcript is full of recognition errors. The prompt asks the model to
recover real terms from context and to drop what it cannot recognise, rather than
repeat garbage as fact. Small local models tend to fail that test: in one measured case a
12B model invented a tool out of noise and never worked out that "Basics" meant
`base64`, the main topic of the lecture. Larger models repair those. Whatever you use,
read the first few sets of notes against the transcript before trusting them.

## Prompts

`lib/prompts/notes.<lang>.md` is chosen by the course language (`el`, `en`, fallback
`en`). Copy one to add a language. Placeholders: `{{COURSE}}`, `{{DATE}}`,
`{{TRANSCRIPT}}`, and the `<!-- section:... -->` blocks that are only included when
slides or sibling recordings exist.
