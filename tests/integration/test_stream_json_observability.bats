#!/usr/bin/env bats
# CP-022: stream-json observability + safer retries

load '../helpers/test_helper'
load '../helpers/fixtures'

RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Minimal project artifacts expected by ralph_loop.sh
    create_sample_prompt "PROMPT.md"
    create_sample_fix_plan "@fix_plan.md" 3 0
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > ".exit_signals"

    mkdir -p logs docs/generated bin

    # Stub Claude CLI (used by ralph_loop.sh in modern mode)
    cat > bin/claude << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--version" ]]; then
  echo "2.1.2 (Claude Code)"
  exit 0
fi

mode="${CLAUDE_STUB_MODE:-progress}"

case "$mode" in
  progress)
    # Emit NDJSON with quotes/braces so progress.json must escape it correctly.
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"text":"hello \"world\" {brace}"}},"session_id":"s-123"}'
    sleep 3
    printf '%s\n' '{"type":"stream_event","event":{"type":"message_stop"},"session_id":"s-123"}'
    # Keep the process alive briefly so Ralph can poll progress.json at least once.
    sleep 5
    ;;
  rate_limit)
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"text":"thinking"}},"session_id":"s-123"}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"result":"You\u0027ve hit your limit · resets 11pm (America/New_York)","session_id":"s-123","permission_denials":[]}'
    exit 0
    ;;
  mcp_timeout)
    echo "MCP tool call 'codex' timed out after 300s" >&2
    exit 1
    ;;
  *)
    echo "Unknown CLAUDE_STUB_MODE=$mode" >&2
    exit 2
    ;;
esac
EOF
    chmod +x bin/claude
    export PATH="$TEST_DIR/bin:$PATH"

    # Keep tests fast.
    export RALPH_PROGRESS_POLL_SECONDS=1
    export RALPH_RETRY_SLEEP_SECONDS=1
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

@test "progress.json remains valid JSON in stream-json mode (quotes/braces) while executing" {
    export CLAUDE_STUB_MODE="progress"

    timeout 6 bash "$RALPH_LOOP" \
        --prompt PROMPT.md \
        --calls 5 \
        --timeout 1 \
        --output-format stream-json \
        --no-focus-fix-plan \
        --no-continue \
        >/dev/null 2>&1 &
    local ralph_pid=$!

    # Wait until progress.json contains the stream line with quotes/braces.
    for _ in {1..30}; do
        if [[ -s "progress.json" ]]; then
            local preview
            preview=$(jq -r '.last_output_preview // ""' progress.json 2>/dev/null || echo "")
            # The NDJSON line contains JSON-escaped quotes within the line: \"world\"
            if [[ "$preview" == *'hello \"world\"'* ]]; then
                break
            fi
        fi
        sleep 0.2
    done

    run jq . progress.json
    assert_success

    run jq -r '.output_format' progress.json
    assert_success
    assert_equal "$output" "stream-json"

    run jq -r '.last_stream_record_type' progress.json
    assert_success
    assert_equal "$output" "stream_event"

    wait "$ralph_pid" >/dev/null 2>&1 || true
}

@test "stream-json rate-limit parsing stores provider message once and updates status fields" {
    export CLAUDE_STUB_MODE="rate_limit"

    # Choose "2" (exit) at the interactive rate-limit prompt to keep the test fast.
    run bash -c "printf '2' | bash \"$RALPH_LOOP\" --prompt PROMPT.md --calls 5 --timeout 1 --output-format stream-json --no-focus-fix-plan --no-continue"

    assert_file_exists ".rate_limit_error"
    local error_msg
    error_msg="$(cat .rate_limit_error)"
    assert_equal "$error_msg" "You've hit your limit · resets 11pm (America/New_York)"

    # Must not spam Unknown error fallbacks
    [[ "$error_msg" != *"Unknown error"* ]]

    assert_file_exists "status.json"
    run jq -r '.provider_rate_limit_reset_hint' status.json
    assert_success
    assert_equal "$output" "11pm (America/New_York)"

    run jq -r '.next_reset' status.json
    assert_success
    local next_reset="$output"

    run jq -r '.next_call_budget_reset' status.json
    assert_success
    assert_equal "$output" "$next_reset"
}

@test "repeated mcp_tool_timeout failures stop early with failure-class exit_reason" {
    export CLAUDE_STUB_MODE="mcp_timeout"

    run timeout 10 bash "$RALPH_LOOP" \
        --prompt PROMPT.md \
        --calls 5 \
        --timeout 1 \
        --output-format stream-json \
        --no-focus-fix-plan \
        --no-continue

    # Should stop early due to repeated mcp_tool_timeout (not run until outer timeout).
    [[ "$status" -eq 1 ]]

    assert_file_exists ".failure_state.json"
    run jq -r '.last_failure_class' .failure_state.json
    assert_success
    assert_equal "$output" "mcp_tool_timeout"

    run jq -r '.consecutive_same_class' .failure_state.json
    assert_success
    assert_equal "$output" "2"

    assert_file_exists "status.json"
    run jq -r '.exit_reason' status.json
    assert_success
    assert_equal "$output" "mcp_tool_timeout"
}
