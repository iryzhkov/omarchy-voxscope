# The post-process status protocol

Voxtype reports a single `transcribing` state for both speech to text and the
post-process command that runs after it, so on its own the HUD cannot tell the
two apart. A post-process script closes the gap by writing a small status file
at each step. This document describes that file. `examples/voxtype-clean`
implements it, and `postprocess.js` is the reader.

The protocol is optional. Without a script, or with a script that does not
write the file, the HUD still shows the recording and one scan while Voxtype
transcribes, and it cannot show the LLM stage or pace the typing animation.

## Where and how it is written

The file is `$XDG_RUNTIME_DIR/voxtype/postprocess.json`. The script creates
the `voxtype` directory if it is missing.

Every write replaces the whole file by rename: write the new contents to a
temporary file in the same directory (the example uses
`.postprocess.json.tmp`), then `rename(2)` it over `postprocess.json`. A
reader therefore never sees a half-written file. Because a rename replaces
the file rather than changing it, the HUD does not watch it; it re-reads it
every 100 ms while Voxtype is transcribing and while the HUD lingers
afterwards.

The contents are one JSON object in UTF-8, no larger than 64 KiB. The HUD
ignores a file that is larger, is not valid JSON, or is not an object with a
valid `stage` and `t`, and keeps the last status it read.

## Stages

A run of the script writes the file two or three times:

1. `start`, as soon as the script has read the transcript from standard
   input. Voxtype starts the post-process command when speech to text has
   finished, so this write marks the end of speech to text. It is required:
   without it the HUD does not know that speech to text has ended.
2. `llm`, just before the script sends the transcript to the LLM. It is
   written only when the LLM is actually asked; a script that skips the LLM
   goes straight from `start` to `done`.
3. `done`, after the output has been decided and just before it is written
   to standard output for Voxtype to type.

Every write carries every field reported so far in this run, not only the
new ones, because the HUD polls and can miss an intermediate write. A `done`
write therefore holds the whole run.

## Fields

Times are wall-clock milliseconds since the Unix epoch, as a number that may
have a fractional part (Python's `time.time() * 1000`, JavaScript's
`Date.now()`). The script and the HUD run on the same machine, so they share
the clock.

| Field      | Type             | Written from | Meaning |
|------------|------------------|--------------|---------|
| `stage`    | string           | every write  | `"start"`, `"llm"` or `"done"`: the step this write reports. |
| `t`        | number, ms       | every write  | When this write was made. |
| `stt_t`    | number, ms       | `start`      | When speech to text ended, which is when the script started. |
| `raw_lens` | array of integers| `start`      | Length in characters of each word of the raw transcript, split on whitespace; at most 400 entries. |
| `words_in` | integer          | `start`      | Number of words in the raw transcript. |
| `llm_t`    | number, ms       | `llm`        | When the LLM request was sent. |
| `model`    | string or null   | `llm`, `done`| The LLM model name as shown to the user, such as `qwen3:4b`. Ollama's implicit `:latest` tag is left off (`llama3.2`, not `llama3.2:latest`); any other tag is kept. `done` sets it to null when no model was used. |
| `timeout`  | number, seconds  | `llm`        | How long the script waits for the LLM before giving up. |
| `cleaned`  | boolean          | `done`       | True when the output is the LLM's cleaned text, false when it is the raw transcript. |
| `reason`   | string           | `done`       | Why the output is what it is: `"ok"` (cleaned), `"rejected"` (the LLM answered but the answer was discarded), `"loading"` (the model was not loaded yet), `"unreachable"` (no server or no model), `"disabled"` (LLM cleanup turned off). |
| `words`    | integer          | `done`       | Number of words in the output. |
| `lens`     | array of integers| `done`       | Length in characters of each word of the output; at most 400 entries. |

Only `stage` and `t` are required in every write. The HUD keeps a field only
when it has the type above and a plausible value: times from 0 to 10^15 ms,
lengths from 0 to 1000, counts up to a million, `timeout` up to an hour,
`model` as printable ASCII of at most 128 characters, and `reason` as one of
the five values above. It ignores unknown fields, so a script may add its
own. A file larger than 64 KiB is ignored whole, and so is anything that is
not a regular file of the user's own reached without a symlink: the script
should write the file itself, not link it.

## Staleness

The file outlives the run that wrote it, so the next dictation starts with
the previous status still in place. A status whose `t` is more than 250 ms
earlier than the moment the HUD saw Voxtype enter `transcribing` belongs to
an earlier dictation, and the HUD ignores it. A script should write `start`
promptly; there is no need to delete the file.

## How the HUD uses it

- `stt_t` ends the speech-to-text scan; the scan line fast-forwards to the
  end if it was behind.
- `llm_t` starts the LLM scan, whose expected length comes from `words_in`.
  `raw_lens` lays out the word blocks drawn behind the LLM scan line.
- `done` ends the LLM scan. `lens` (or `words`, when `lens` is empty) sets
  the length of the typing animation, which is paced to end when Voxtype's
  real typing does.
- The subtitle on the output stage comes from `cleaned`, `reason`, `model`
  and `words`.
- After each dictation the HUD learns from the measured durations: speech to
  text from `stt_t`, the LLM from `t - llm_t` of the `done` write (only when
  `cleaned` is true or `reason` is `"rejected"`, and the request took less
  than 95 % of `timeout`), and typing speed from the time between the `done`
  write and Voxtype going idle.

## Example

A run that cleaned 22 words with an LLM writes these three files in turn
(word lengths shortened here):

```json
{"stage": "start", "t": 1792225000120.4, "stt_t": 1792225000120.1,
 "raw_lens": [5, 3, 7], "words_in": 22}
```

```json
{"stage": "llm", "t": 1792225000160.9, "stt_t": 1792225000120.1,
 "raw_lens": [5, 3, 7], "words_in": 22,
 "model": "qwen3:4b", "timeout": 5.0, "llm_t": 1792225000160.7}
```

```json
{"stage": "done", "t": 1792225001380.2, "stt_t": 1792225000120.1,
 "raw_lens": [5, 3, 7], "words_in": 22,
 "model": "qwen3:4b", "timeout": 5.0, "llm_t": 1792225000160.7,
 "cleaned": true, "reason": "ok", "words": 20, "lens": [7, 2, 4]}
```
