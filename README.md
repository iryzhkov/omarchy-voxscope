# Voxscope

A dictation HUD for [Voxtype](https://voxtype.io) on Omarchy, built as an
`omarchy-shell` plugin. It shows the whole dictation pipeline: the live
microphone spectrum while recording, a scan line over the recording while it
is transcribed, a second pass while an LLM cleans the text up, and the words
being typed, each paced to finish with the real work.

## What it does

A themed card appears in the middle of the focused screen while Voxtype is
recording or transcribing. A stepper across the top (REC, STT, LLM, OUT) and a
progress bar along the bottom follow the pipeline, and the middle shows each
stage in its own way:

- **Listening.** A mirrored live spectrum of the microphone with held peaks,
  and indicator lights for input, voice and clipping. Meanwhile the loudness
  is recorded as a timeline.
- **Transcribing.** The recording's timeline as a soft envelope, with a scan
  line sweeping across it and rebuilding it from square cells.
- **Refining.** A second scan line over those cells, turning them into blocks
  the length of the transcript's words, while an LLM cleans the text up.
- **Typing.** The words typed out as runs of cells behind a block cursor. The
  subtitle gives the word count and whether the LLM cleaned the text.

Neither speech to text nor the LLM reports progress, so each scan runs for an
estimated time that Voxscope learns from the dictations you make, and the
typing animation is paced to end when Voxtype's real typing does. When Voxtype
goes idle the card stays a moment longer to finish its animation, never more
than a second and a half.

The card takes the colours of the active Omarchy theme, never takes keyboard
focus, and lets clicks through to whatever is underneath.

While recording it also counts down the last ten seconds before Voxtype's
recording cap (`audio.max_duration_secs`), and it can stop a recording after
ten seconds without voice (see below).

## Requirements

- Omarchy with `omarchy-shell` and its plugin system.
- Voxtype 1.0 or later, which provides the state file in
  `$XDG_RUNTIME_DIR/voxtype/` and `voxtype-audio-bridge`.

## Install

Once the repository is published:

```
omarchy plugin add https://github.com/iryzhkov/omarchy-voxscope.git --enable
```

By hand, put a copy (or a clone) of this repository in
`~/.config/omarchy/plugins/io.github.iryzhkov.voxscope/`, then:

```
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.iryzhkov.voxscope
```

The plugin is a `panel` with `keepLoaded`, like Omarchy's own OSD: once
enabled, the shell loads it at startup and keeps it loaded. It has no key
binding and nothing to summon; it appears by itself when you dictate.

### Turn off Voxtype's own OSD

Voxtype draws its own on-screen display by default, which would sit on top of
Voxscope. Its master switch is `osd.enabled` in
`~/.config/voxtype/config.toml`:

```toml
[osd]
enabled = false
```

or, equivalently:

```
voxtype config set osd.enabled false
```

The setting takes effect when the Voxtype daemon restarts, for example with
`systemctl --user restart voxtype` if it runs as a user service. With it off,
Voxtype's OSD frontends exit at launch; the daemon still writes its state
file and serves its audio socket, which is all Voxscope needs.

A recording started with `voxtype record start --no-osd` hides Voxscope too,
as it does Voxtype's own OSD: for the whole dictation, including the
transcription, and without the linger afterwards. Voxscope does not run the
audio bridge or cava for it.

### Optional: cava

Voxtype's audio bridge only carries the microphone's peak and RMS level, so
the spectrum comes from [cava](https://github.com/karlstav/cava), in the Arch
`extra` repository as `cava`. While recording, Voxscope asks PipeWire for the
default source with `pactl` (from `libpulse`), writes a cava config for it to
`$XDG_RUNTIME_DIR/voxscope/cava.conf` and runs `/usr/bin/cava`. Without cava,
or without `pactl`, the bars are synthesised from the bridge's RMS level
instead, and nothing else changes. The plugin never installs anything.

### Optional: the post-process script

Voxtype reports one `transcribing` state for both speech to text and its
post-process command, so on its own Voxscope cannot tell them apart: it shows
one scan until Voxtype is done. A post-process script that reports its stages
lets it show speech to text, the LLM cleanup and the typing separately, with
the word count and whether the text was cleaned.

`examples/voxtype-clean` is such a script. It collapses Whisper's line breaks
and, when an [Ollama](https://ollama.com) server has the cleanup model loaded,
asks it to fix punctuation and remove filler words, falling back to the plain
text on any failure. To use it, copy it somewhere on your path, make it
executable, and point Voxtype at it in `~/.config/voxtype/config.toml`:

```toml
[output.post_process]
command = "/home/you/.local/bin/voxtype-clean"
timeout_ms = 8000
```

It reads its settings from the environment of the Voxtype daemon:
`VOXTYPE_CLEAN_BASE` (the Ollama URL, default `http://localhost:11434`),
`VOXTYPE_CLEAN_MODEL` (default `qwen3:4b`; a comma-separated list picks the
first one installed), `VOXTYPE_CLEAN_TIMEOUT` (seconds, default 5) and
`VOXTYPE_CLEAN_LLM=0` to skip the LLM.

To report stages from a script of your own, see
[docs/postprocess-protocol.md](docs/postprocess-protocol.md).

### Optional: silence auto-stop

A push-to-talk recording ends when you release the key, but a toggled one runs
until you press again. Voxscope stops a toggled recording itself after ten
seconds without voice, counting down for the last five, by running
`voxtype record stop`. It only does this for recordings it knows were
toggled: the toggle binding has to stamp the time, in milliseconds, into
`$XDG_RUNTIME_DIR/voxtype/toggle-start` just before starting. For example,
bind your toggle key to a script like this instead of `voxtype record toggle`:

```bash
#!/bin/bash
dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/voxtype"
if [ "$(cat "$dir/state" 2>/dev/null)" = idle ]; then
  date +%s%3N > "$dir/toggle-start"
fi
exec voxtype record toggle
```

## Files

Voxscope keeps what it learns in `$XDG_STATE_HOME/voxscope/`
(`~/.local/state/voxscope/`), created on first start: `timing.json` holds the
learned speeds of speech to text, the LLM and typing, and `calibration.json`
the spectrum's per-band levels for your microphone and room. Deleting them
starts the learning over. Nothing is ever written to the plugin's own
directory.

## Development

`tests/harness/run.sh <scenario>` runs the HUD in a standalone Quickshell
against a scratch directory under `~/.cache/voxscope-test/`, plays a scripted
dictation into it and saves frames of the card; see the script for the
scenarios. `timing.js` holds the timing model as pure functions.

## Credits

`VoxtypeState.qml` and `VoxtypeAudio.qml` are adapted from Voxtype's
Quickshell frontend, MIT licence, copyright (c) 2025 Peter Jackson.

## Licence

MIT; see [LICENSE](LICENSE).
