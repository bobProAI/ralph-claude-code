#!/usr/bin/env bats
# Unit tests for Codex CLI runner (scripts/ralph-codex-cli.sh)

load '../helpers/test_helper'

RUNNER_SCRIPT="${BATS_TEST_DIRNAME}/../../../../scripts/ralph-codex-cli.sh"
SHIM_SCRIPT="${BATS_TEST_DIRNAME}/../../../../scripts/ralph-codex-shim.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    STATE_DIR="$TEST_DIR/state"
    BIN_DIR="$TEST_DIR/bin"

    mkdir -p "$STATE_DIR/logs" "$BIN_DIR"

    # Minimal CP workspace files
    cat > "$STATE_DIR/PROMPT.md" << 'EOF'
# Test Prompt
Please complete the tasks and end with a RALPH_STATUS block.
EOF

    cat > "$STATE_DIR/@fix_plan.md" << 'EOF'
# Fix Plan
- [x] Completed task 1
EOF

    create_stub_bin
    export PATH="$BIN_DIR:$PATH"
    export CODEX_STUB_MODE="success"
    export PNPM_SHOULD_FAIL="false"
    export PNPM_STATE_FILE="$TEST_DIR/pnpm_state"
    export RALPH_DISABLE_PNPM_SHIM="true"
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

create_stub_bin() {
    # Stub timeout: ignore duration and run command
    cat > "$BIN_DIR/timeout" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
exec "$@"
EOF
    chmod +x "$BIN_DIR/timeout"
    ln -s "$BIN_DIR/timeout" "$BIN_DIR/gtimeout"

    # Stub codex
    cat > "$BIN_DIR/codex" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "whoami" ]]; then
    echo "stub-user"
    exit 0
fi

mode="${CODEX_STUB_MODE:-success}"
output_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        exec)
            shift
            ;;
        --output-last-message)
            output_file="$2"
            shift 2
            ;;
        --sandbox)
            shift 2
            ;;
        --cd)
            shift 2
            ;;
        --full-auto|--json|-)
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -n "${CODEX_CAPTURE_PROMPT:-}" ]]; then
    cat - > "$CODEX_CAPTURE_PROMPT"
else
    cat - >/dev/null
fi

case "$mode" in
    success)
        if [[ -n "$output_file" ]]; then
            cat > "$output_file" << 'MSG'
Work complete.

---RALPH_STATUS---
CP_NUMBER: CP-TEST
STATUS: COMPLETE
TASKS_REMAINING: 0
EXIT_SIGNAL: true
RECOMMENDATION: stop
---END_RALPH_STATUS---
MSG
        fi
        printf '%s\n' '{"type":"message","content":"ok"}'
        exit 0
        ;;
    missing_last)
        printf '%s\n' '{"type":"message","content":"ok"}'
        exit 0
        ;;
    auth_fail)
        echo "not authenticated" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$BIN_DIR/codex"

    # Stub pnpm gates
    cat > "$BIN_DIR/pnpm" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${PNPM_SHOULD_FAIL:-false}"
state_file="${PNPM_STATE_FILE:-}"

if [[ "$mode" == "once" ]]; then
    if [[ -n "$state_file" && ! -f "$state_file" ]]; then
        echo "1" > "$state_file" 2>/dev/null || true
        echo "pnpm stub failure" >&2
        exit 1
    fi
fi

if [[ "$mode" == "true" ]]; then
    echo "pnpm stub failure" >&2
    exit 1
fi
echo "pnpm stub ok: $*" >&2
exit 0
EOF
    chmod +x "$BIN_DIR/pnpm"
}

@test "codex cli runner completes after two confirmations" {
    run bash "$RUNNER_SCRIPT" --directory "$STATE_DIR" --calls 5 --timeout 1
    assert_success

    assert_file_exists "$STATE_DIR/status.json"
    run jq -r '.status' "$STATE_DIR/status.json"
    assert_success
    assert_equal "$output" "completed"

    run jq -r '.exit_reason' "$STATE_DIR/status.json"
    assert_success
    assert_equal "$output" "verified_complete"
}

@test "codex cli runner fails when last message is missing" {
    export CODEX_STUB_MODE="missing_last"
    # Ensure the fix plan is NOT complete so the runner must invoke Codex.
    cat > "$STATE_DIR/@fix_plan.md" << 'EOF'
# Fix Plan
- [ ] Incomplete task 1
EOF
    run bash "$RUNNER_SCRIPT" --directory "$STATE_DIR" --calls 5 --timeout 1
    assert_failure

    assert_file_exists "$STATE_DIR/status.json"
    run jq -r '.exit_reason' "$STATE_DIR/status.json"
    assert_success
    assert_equal "$output" "invalid_output"
}

@test "legacy MCP shim fails fast with migration guidance" {
    run bash "$SHIM_SCRIPT" 2>&1
    assert_failure
    [[ "$output" == *"deprecated"* ]]
    [[ "$output" == *"ralph-codex-cli.sh"* ]]
}

@test "ship-gate failure after completion runs Codex in gate-fix mode (no re-decompose)" {
    export PNPM_SHOULD_FAIL="once"
    export CODEX_CAPTURE_PROMPT="$TEST_DIR/captured_prompt.md"

    run bash "$RUNNER_SCRIPT" --directory "$STATE_DIR" --calls 5 --timeout 1
    assert_success

    assert_file_exists "$CODEX_CAPTURE_PROMPT"
    run grep -q "MODE: FIX_SHIP_GATES" "$CODEX_CAPTURE_PROMPT"
    assert_success
}
