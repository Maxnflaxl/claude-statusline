# claude-statusline

A colorful three-line statusline for [Claude Code](https://claude.com/claude-code) — git state, model, cost, rate-limit bars, context usage, live token throughput, and a working-tree diff, all in one bash script with no dependencies beyond `jq`.

```
claude-statusline │ master ✚1 │ 󰚩 Opus 4.8 (high) │ $3.42 │ 1h15m │ 5h ⣿⣿⣿⣀⣀⣀⣀⣀ 42% │ 7d ⣿⣿⣿⣿⣿⣿⣿⣀ 88% ↻2d4h
370k (37%) 󰏫 ◈85% │ @ 1.2K t/s │ ↓ in 4.1M   ↑ out 82.4K
+184 -31 (+153) │ 󰏫 +412 -97 (+315)
```

## What each line shows

**Line 1 — session at a glance**

| Segment | Meaning |
|---|---|
| `claude-statusline` | Current directory basename |
| `master ✚1` | Branch, plus counts: `●` staged, `✚` unstaged, `?` untracked, `✓` when clean. Orange when clean, red when dirty. `↑2 ↓1` for ahead/behind the upstream. |
| `󰚩 Opus 4.8 (high)` | Model and reasoning effort |
| `$3.42` | Session cost |
| `1h15m` | Session wall-clock duration |
| `5h ⣿⣿⣿⣀⣀⣀⣀⣀ 42%` | Rate-limit usage as a dot-matrix bar — blue under 70%, yellow past it, red at 100%. Once it's not blue, `↻2h10m` shows the time to reset. The `7d` bar is hidden when its reset is under 6h away. |

**Line 2 — context and throughput**

| Segment | Meaning |
|---|---|
| `370k (37%)` | Context window used — blue with headroom, yellow past 60%, red past 85% |
| `󰏫` | What Claude is doing right now, derived from the transcript: an icon per tool (bash, read, edit, search, web, subagent, todo, skill, MCP…), `✻` while it's thinking |
| `◈85%` | Share of the current window served from the prompt cache |
| `@ 1.2K t/s` | Token throughput over the last 60s |
| `↓ in 4.1M ↑ out 82.4K` | Cumulative session tokens, deduplicated by message id. The arrow lights up when that counter grew in the last 10s. |

**Line 3 — lines changed**

| Segment | Meaning |
|---|---|
| `+184 -31 (+153)` | Working-tree diff against `HEAD`, **including untracked files** |
| `󰏫 +412 -97 (+315)` | Lines Claude added/removed this session |

Every segment disappears cleanly when its data isn't available, so this works the same in a non-git directory, without `jq`, or on a plan that doesn't report rate limits.

## Requirements

- **bash** — 3.2 works, so stock macOS is fine
- **jq** — `brew install jq` / `apt install jq`. Without it the statusline still renders, but drops everything that comes from the status JSON and the transcript.
- **A [Nerd Font](https://www.nerdfonts.com/)** for the tool and model glyphs. Without one you'll see tofu boxes where `󰚩 󰏫 󰈔` should be; the rest (braille bars, sparkline blocks, arrows) is plain Unicode and renders anywhere.
- A terminal with 256-color support.

## Install

```sh
git clone https://github.com/maxnflaxl/claude-statusline.git
cd claude-statusline
./install.sh
```

The installer symlinks the script into your Claude config directory and points `statusLine` at it in `settings.json`, backing up anything it replaces. Restart Claude Code (or start a new session) to see it.

<details>
<summary>Manual install</summary>

Copy `statusline-command.sh` somewhere, then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /absolute/path/to/statusline-command.sh"
  }
}
```
</details>

## Notes

- **It never touches your index.** Counting untracked files in the diff needs `git add -N`, which would otherwise stage deletions and plant intent-to-add entries into a commit you're in the middle of writing. The script copies the index to a temp file and runs against that instead.
- **Token totals are cached** on transcript byte-size under `$CLAUDE_CONFIG_DIR/statusline-usage-cache/`, keyed by session id — the statusline redraws far more often than new tokens actually land, so the transcript is only re-parsed when the file grows. Entries untouched for a day are pruned on the next cache miss, so the directory holds live sessions only.
- **Rate samples** live in `$CLAUDE_CONFIG_DIR/statusline-token-rate.log`, garbage-collected to a 300-second window on every render.
- `CLAUDE_CONFIG_DIR` is honored for both, falling back to `~/.claude`.

## Customizing

Colors are 256-color ANSI escapes declared together near the top (`C_MODEL`, `C_DIR`, `C_GIT`, …) — change them there and every use follows. The activity glyphs are a single `case` statement over tool names. To drop a segment entirely, remove its line from the assembler at the bottom of the script.

## License

MIT — see [LICENSE](LICENSE).
