# Voxscope

A dictation HUD for [Voxtype](https://voxtype.io) on Omarchy, built as an
`omarchy-shell` plugin. It shows the whole dictation pipeline: the live
microphone spectrum while recording, a scan line over the recording while it
is transcribed, a second pass while an LLM cleans the text up, and the words
being typed, each paced to finish with the real work.

Work in progress. `reference/` holds the prototype this plugin is ported
from: a Voxtype Quickshell style package and the post-process script that
reports pipeline stages to it. It is removed once the port is complete.
