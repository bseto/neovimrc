#!/bin/sh
# Claude status line: saves the account's usage windows and each chat's model and effort for the Neovim agent grid,
# then draws the GSD status line.
# Every chat writes here, and an idle chat drops a window whose reset has passed. So each window is merged with the
# saved one: the later reset wins, then the higher use.
input=$(cat)
out="${TMPDIR:-/tmp}/claude-usage.json"
old=$(cat "$out" 2>/dev/null)
limits=$(printf '%s' "$input" | jq -c --argjson old "${old:-null}" '
  def newer(a; b):
    if a == null then b elif b == null then a
    elif a.resets_at != b.resets_at then (if a.resets_at > b.resets_at then a else b end)
    elif a.used_percentage >= b.used_percentage then a else b end;
  .rate_limits // empty | . as $new | ($old // {}) as $o
  | reduce ((($new | keys) + ($o | keys)) | unique)[] as $k ({}; .[$k] = newer($new[$k]; $o[$k]))
' 2>/dev/null) || limits=$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
[ -n "$limits" ] && printf '%s\n' "$limits" >"$out"
# Model and effort per session, for the grid cards.
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
case "$session" in
'' | */* | *..*) ;;
*) printf '%s' "$input" | jq -c '{model: (.model.display_name // .model.id), effort: .effort.level}' \
  >"${TMPDIR:-/tmp}/claude-model-$session.json" 2>/dev/null ;;
esac
printf '%s' "$input" | node "$HOME/.claude/hooks/gsd-statusline.js"
