#!/bin/bash
# Tests for suggest-mcp-search.sh advisory hook
# Run: bash .claude/hooks/tests/test_suggest_mcp_search.sh

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/suggest-mcp-search.sh"
PASS=0
FAIL=0

run_hook() {
  echo "$1" | bash "$HOOK" 2>&1
}

assert_banner() {
  local desc="$1" input="$2"
  local output
  output=$(run_hook "$input")
  if echo "$output" | grep -q "MCP search available"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc — expected banner, got: $output"
  fi
}

assert_no_banner() {
  local desc="$1" input="$2"
  local output
  output=$(run_hook "$input")
  if [ -z "$output" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc — expected no output, got: $output"
  fi
}

# --- Should fire (grep on framework paths) ---

assert_banner "grep -r on roles/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"activation\" roles/"}}'

assert_banner "grep -rn on .claude/hooks/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn \"require-active\" .claude/hooks/"}}'

assert_banner "grep on workflows/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"SDLC\" workflows/"}}'

assert_banner "grep on docs/agdr" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"migration\" docs/agdr/"}}'

assert_banner "grep on handbooks/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -l \"blocking\" handbooks/"}}'

assert_banner "grep on workspace/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn \"export\" workspace/yumyum/backend/src/"}}'

assert_banner "find on templates/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find templates/ -name \"*.md\""}}'

assert_banner "piped grep on skills/" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat skills/debug/SKILL.md | grep hypothesis"}}'

# --- Should NOT fire ---

assert_no_banner "grep on non-framework path" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"TODO\" src/"}}'

assert_no_banner "non-Bash tool" \
  '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"roles/engineering/tech-lead.md"}}'

assert_no_banner "non-grep bash command" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm test"}}'

assert_no_banner "git command" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log --oneline -5"}}'

assert_no_banner "grep on random dir" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -r \"error\" /var/log/"}}'

# --- Results ---

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
