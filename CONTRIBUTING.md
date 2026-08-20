# Contributing

Thanks for wanting to improve Terminal Manager. The useful work is in matching
live `claude` / `grok` processes to transcripts and keeping the menu bar honest
after sleep, Free, and reboot.

## Setup

macOS 14+, Xcode or the Command Line Tools, Swift 6.

```sh
git clone https://github.com/ProximoBinks/terminal-manager.git
cd terminal-manager
./build.sh
open build/TerminalManager.app
```

## How to check a change

The same engine runs without the menu bar:

```sh
swift build -c release
.build/release/TerminalManager --dump
.build/release/TerminalManager --groups
.build/release/TerminalManager --sessions grok
```

`--dump` is the right first check: live PIDs, how each session was matched, RAM.

## Pull requests

- Keep the change scoped. Matching, persistence, and the menu UI are easy to
  break together — say which of those you touched.
- Match the existing Swift style: short comments that explain constraints, not
  narration.
- Do not commit `.build/` or `build/`.
- If you change matching, paste a `--dump` snippet in the PR (redact paths if
  you want).

## Issues

Bug reports that include `--dump` output (and whether the session is Claude or
Grok) are much easier to act on than screenshots alone.
