#!/bin/bash
# Saves model, context %, cost and plan limits for the Spyglass panel: ~/.claude/spyglass/stats/<session_id>.json
# Feed it Claude Code's statusline JSON on stdin; call it from your statusline script.
# Hooks and the statusline may run without Homebrew on PATH (jq).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
dir="${SPYGLASS_HOME:-$HOME/.claude/spyglass}/stats"
mkdir -p "$dir"
in=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
[ -z "$sid" ] && exit 0
jq --argjson now "$(date +%s)" '{
  model: (.model.display_name // .model.id // null),
  ctx: (.context_window.used_percentage // null | if . == null then null else floor end),
  ctxTokens: (.context_window.total_input_tokens // null),
  ctxSize: (.context_window.context_window_size // null),
  cost: (.cost.total_cost_usd // null),
  # Plan limits (subscriptions only; null on API keys): {five_hour: {pct, resets}, seven_day: {...}, ...}; behind a Claude
  # gateway also spend_limit: {pct, resets, usd, limitUsd}. pct goes past 100 once a limit is used up.
  limits: (.rate_limits // null | if . == null then null else
    with_entries(select(.value | type == "object" and has("used_percentage")))
    | map_values({pct: .used_percentage, resets: (.resets_at // null)}
                 + (if .used_usd != null then {usd: .used_usd, limitUsd: (.limit_usd // null)} else {} end)) end),
  updated: $now
}' <<<"$in" > "$dir/$sid.json.tmp" 2>/dev/null && mv "$dir/$sid.json.tmp" "$dir/$sid.json" || rm -f "$dir/$sid.json.tmp"
exit 0
