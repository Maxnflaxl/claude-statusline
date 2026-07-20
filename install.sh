#!/usr/bin/env bash
# Symlink statusline-command.sh into the Claude config dir and register it as
# the statusLine command in settings.json. Idempotent — re-running is a no-op.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline-command.sh"
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dest="$config_dir/statusline-command.sh"
settings="$config_dir/settings.json"

[ -f "$src" ] || { echo "error: $src not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required (brew install jq / apt install jq)" >&2; exit 1; }

mkdir -p "$config_dir"
chmod +x "$src"

# ---- link the script ------------------------------------------------------
if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
  echo "✓ $dest already links here"
else
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    backup="$dest.backup.$(date +%Y%m%d%H%M%S)"
    mv "$dest" "$backup"
    echo "→ moved existing script to $backup"
  fi
  ln -s "$src" "$dest"
  echo "✓ linked $dest → $src"
fi

# ---- register it in settings.json -----------------------------------------
cmd="bash $dest"
[ -f "$settings" ] || printf '{}\n' > "$settings"

jq -e . "$settings" >/dev/null 2>&1 || {
  echo "error: $settings is not valid JSON — fix it and re-run" >&2; exit 1; }

if [ "$(jq -r '.statusLine.command // ""' "$settings")" = "$cmd" ]; then
  echo "✓ settings.json already points at it"
else
  existing="$(jq -r '.statusLine.command // ""' "$settings")"
  [ -n "$existing" ] && echo "→ replacing previous statusLine: $existing"
  backup="$settings.backup.$(date +%Y%m%d%H%M%S)"
  cp "$settings" "$backup"
  tmp="$(mktemp)"
  jq --arg cmd "$cmd" '.statusLine = {type: "command", command: $cmd}' \
    "$settings" > "$tmp"
  mv "$tmp" "$settings"
  echo "✓ updated $settings (backup at $backup)"
fi

echo
echo "Done. Start a new Claude Code session to see the statusline."
