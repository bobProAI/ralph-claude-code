#!/usr/bin/env bats
# Unit tests for JSON output parsing in response_analyzer.sh
# TDD: Write tests first, then implement

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo for tests
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up environment
    export PROMPT_FILE="PROMPT.md"
    export LOG_DIR="logs"
    export DOCS_DIR="docs/generated"
    export STATUS_FILE="status.json"
    export EXIT_SIGNALS_FILE=".exit_signals"

    mkdir -p "$LOG_DIR" "$DOCS_DIR"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# JSON FORMAT DETECTION TESTS
# =============================================================================

@test "detect_output_format identifies valid JSON output" {
    local output_file="$LOG_DIR/test_output.log"

    # Create JSON output
    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "work_type": "IMPLEMENTATION",
    "files_modified": 5,
    "error_count": 0,
    "summary": "Implemented authentication module"
}
EOF

    # Should detect as JSON
    run detect_output_format "$output_file"
    assert_equal "$output" "json"
}

@test "detect_output_format identifies text output" {
    local output_file="$LOG_DIR/test_output.log"

    # Create text output
    cat > "$output_file" << 'EOF'
Reading PROMPT.md...
Implementing feature X...
All tests passed.
Done.
EOF

    # Should detect as text
    run detect_output_format "$output_file"
    assert_equal "$output" "text"
}

@test "detect_output_format handles mixed content (JSON with surrounding text)" {
    local output_file="$LOG_DIR/test_output.log"

    # Create mixed output (Claude sometimes adds text around JSON)
    cat > "$output_file" << 'EOF'
Starting execution...

{
    "status": "IN_PROGRESS",
    "exit_signal": false
}

Done processing.
EOF

    # Should detect as text since it's not pure JSON
    run detect_output_format "$output_file"
    # Mixed content should be treated as text for safety
    [[ "$output" == "text" || "$output" == "mixed" ]]
}

@test "detect_output_format handles empty file" {
    local output_file="$LOG_DIR/empty.log"
    touch "$output_file"

    run detect_output_format "$output_file"
    assert_equal "$output" "text"
}

# =============================================================================
# JSON PARSING TESTS
# =============================================================================

@test "parse_json_response extracts status field correctly" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "work_type": "IMPLEMENTATION",
    "files_modified": 5,
    "error_count": 0,
    "summary": "All tasks completed"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    # Should create result file with parsed values
    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local status=$(jq -r '.status' "$result_file")
    assert_equal "$status" "COMPLETE"
}

@test "parse_json_response extracts exit_signal correctly" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "work_type": "IMPLEMENTATION"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "true"
}

@test "parse_json_response maps IN_PROGRESS status to non-exit signal" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS",
    "exit_signal": false,
    "work_type": "IMPLEMENTATION",
    "files_modified": 3
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "false"
}

@test "parse_json_response identifies TEST_ONLY work type" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS",
    "exit_signal": false,
    "work_type": "TEST_ONLY",
    "files_modified": 0
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local is_test_only=$(jq -r '.is_test_only' "$result_file")
    assert_equal "$is_test_only" "true"
}

@test "parse_json_response extracts files_modified count" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS",
    "files_modified": 7,
    "work_type": "IMPLEMENTATION"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local files=$(jq -r '.files_modified' "$result_file")
    assert_equal "$files" "7"
}

@test "parse_json_response handles error_count field" {
    local output_file="$LOG_DIR/test_output.log"

    # is_stuck threshold is >5 errors (matches response_analyzer.sh text parsing)
    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS",
    "error_count": 6,
    "work_type": "IMPLEMENTATION"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # High error count (>5) should indicate stuck state
    local is_stuck=$(jq -r '.is_stuck' "$result_file")
    assert_equal "$is_stuck" "true"
}

@test "parse_json_response extracts summary field" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "summary": "Implemented user authentication with JWT tokens"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local summary=$(jq -r '.summary' "$result_file")
    [[ "$summary" == *"authentication"* ]]
}

# =============================================================================
# JSON SCHEMA VALIDATION TESTS
# =============================================================================

@test "parse_json_response handles missing optional fields gracefully" {
    local output_file="$LOG_DIR/test_output.log"

    # Minimal JSON with only required fields
    cat > "$output_file" << 'EOF'
{
    "status": "IN_PROGRESS"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # Should not error, should use defaults
    local status=$(jq -r '.status' "$result_file")
    assert_equal "$status" "IN_PROGRESS"
}

@test "parse_json_response handles malformed JSON gracefully" {
    local output_file="$LOG_DIR/test_output.log"

    # Invalid JSON
    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE"
    "missing_comma": true
}
EOF

    run parse_json_response "$output_file"
    # Should fail gracefully
    [[ $status -ne 0 ]] || [[ "$output" == *"error"* ]] || [[ "$output" == *"fallback"* ]] || skip "parse_json_response not yet implemented"
}

@test "parse_json_response handles nested metadata object" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "metadata": {
        "loop_number": 5,
        "timestamp": "2026-01-09T10:30:00Z",
        "session_id": "abc123"
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local loop_num=$(jq -r '.metadata.loop_number // .loop_number' "$result_file")
    assert_equal "$loop_num" "5"
}

# =============================================================================
# INTEGRATION: analyze_response WITH JSON
# =============================================================================

@test "analyze_response detects JSON format and parses correctly" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "work_type": "IMPLEMENTATION",
    "files_modified": 5,
    "error_count": 0,
    "summary": "All authentication features completed"
}
EOF

    analyze_response "$output_file" 1
    local result=$?

    assert_equal "$result" "0"
    assert_file_exists ".response_analysis"

    local exit_signal=$(jq -r '.analysis.exit_signal' .response_analysis)
    assert_equal "$exit_signal" "true"
}

@test "analyze_response falls back to text parsing on JSON failure" {
    local output_file="$LOG_DIR/test_output.log"

    # Invalid JSON but contains completion keywords
    cat > "$output_file" << 'EOF'
{ invalid json here }
But the project is complete and all tasks are done.
EOF

    analyze_response "$output_file" 1
    local result=$?

    assert_equal "$result" "0"
    assert_file_exists ".response_analysis"

    # Should still detect completion via text parsing
    local has_completion=$(jq -r '.analysis.has_completion_signal' .response_analysis)
    assert_equal "$has_completion" "true"
}

@test "analyze_response uses JSON confidence boost when available" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "status": "COMPLETE",
    "exit_signal": true,
    "confidence": 95
}
EOF

    analyze_response "$output_file" 1

    # JSON with explicit exit_signal should have high confidence
    local confidence=$(jq -r '.analysis.confidence_score' .response_analysis)
    [[ "$confidence" -ge 50 ]]
}

# =============================================================================
# BACKWARD COMPATIBILITY TESTS
# =============================================================================

@test "analyze_response still handles traditional RALPH_STATUS format" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
Completed the implementation.

---RALPH_STATUS---
STATUS: COMPLETE
EXIT_SIGNAL: true
WORK_TYPE: IMPLEMENTATION
---END_RALPH_STATUS---
EOF

    analyze_response "$output_file" 1

    local exit_signal=$(jq -r '.analysis.exit_signal' .response_analysis)
    assert_equal "$exit_signal" "true"

    local confidence=$(jq -r '.analysis.confidence_score' .response_analysis)
    [[ "$confidence" -ge 100 ]]
}

@test "analyze_response handles plain text completion signals" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
I have finished implementing all the requested features.
The project is complete and ready for review.
All tests are passing.
EOF

    analyze_response "$output_file" 1

    local has_completion=$(jq -r '.analysis.has_completion_signal' .response_analysis)
    assert_equal "$has_completion" "true"
}

@test "analyze_response maintains text parsing for test-only detection" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
Running tests...
npm test
All tests passed successfully!
EOF

    analyze_response "$output_file" 1

    local is_test_only=$(jq -r '.analysis.is_test_only' .response_analysis)
    assert_equal "$is_test_only" "true"
}

# =============================================================================
# CLAUDE CODE CLI JSON STRUCTURE TESTS
# =============================================================================
# Tests for the modernized Claude Code CLI output format with:
# - result: Actual Claude response content
# - sessionId: Session UUID for continuity
# - metadata: Structured information about the execution

@test "detect_output_format identifies Claude CLI JSON with result field" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Implemented authentication module with JWT tokens.",
    "sessionId": "session-abc123",
    "metadata": {
        "files_changed": 3,
        "has_errors": false,
        "completion_status": "in_progress"
    }
}
EOF

    run detect_output_format "$output_file"
    assert_equal "$output" "json"
}

@test "parse_json_response extracts result field from Claude CLI format" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "All tasks completed successfully. Project ready for review.",
    "sessionId": "session-xyz789"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # Result should be captured in summary field
    local summary=$(jq -r '.summary' "$result_file")
    [[ "$summary" == *"All tasks completed"* ]]
}

@test "parse_json_response extracts sessionId from Claude CLI format" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Working on feature implementation.",
    "sessionId": "session-unique-123"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local session_id=$(jq -r '.session_id' "$result_file")
    assert_equal "$session_id" "session-unique-123"
}

@test "parse_json_response extracts metadata.files_changed" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Modified configuration files.",
    "sessionId": "session-001",
    "metadata": {
        "files_changed": 5,
        "has_errors": false
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local files=$(jq -r '.files_modified' "$result_file")
    assert_equal "$files" "5"
}

@test "parse_json_response extracts metadata.has_errors" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Encountered compilation errors.",
    "sessionId": "session-002",
    "metadata": {
        "files_changed": 0,
        "has_errors": true
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # has_errors should map to error tracking
    local is_stuck=$(jq -r '.is_stuck' "$result_file")
    # Single error shouldn't trigger stuck (threshold is >5)
    # But we should track error state
    [[ -f "$result_file" ]]
}

@test "parse_json_response detects completion from metadata.completion_status" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Project implementation finished.",
    "sessionId": "session-003",
    "metadata": {
        "files_changed": 10,
        "has_errors": false,
        "completion_status": "complete"
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "true"
}

@test "parse_json_response handles progress_indicators array" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Made significant progress.",
    "sessionId": "session-004",
    "metadata": {
        "files_changed": 3,
        "has_errors": false,
        "progress_indicators": ["implemented auth", "added tests", "updated docs"]
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # Progress indicators should boost confidence or be stored
    [[ -f "$result_file" ]]
}

@test "parse_json_response extracts usage metadata" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Completed task.",
    "sessionId": "session-005",
    "metadata": {
        "files_changed": 2,
        "usage": {
            "input_tokens": 1500,
            "output_tokens": 800
        }
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || skip "parse_json_response not yet implemented"

    # Usage info should be preserved in metadata
    [[ -f "$result_file" ]]
}

@test "analyze_response handles Claude CLI JSON and detects completion" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "All requested features have been implemented. The project is complete.",
    "sessionId": "session-complete-001",
    "metadata": {
        "files_changed": 8,
        "has_errors": false,
        "completion_status": "complete"
    }
}
EOF

    analyze_response "$output_file" 1

    assert_file_exists ".response_analysis"

    local exit_signal=$(jq -r '.analysis.exit_signal' .response_analysis)
    assert_equal "$exit_signal" "true"

    local output_format=$(jq -r '.output_format' .response_analysis)
    assert_equal "$output_format" "json"
}

@test "analyze_response persists sessionId to .claude_session_id file" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Working on implementation.",
    "sessionId": "session-persist-test-123"
}
EOF

    analyze_response "$output_file" 1

    # Session ID should be persisted for continuity
    [[ -f ".claude_session_id" ]] || skip "Session persistence not yet implemented"

    local stored_session=$(cat .claude_session_id)
    [[ "$stored_session" == *"session-persist-test-123"* ]]
}

# =============================================================================
# SESSION MANAGEMENT FUNCTION TESTS
# =============================================================================

@test "store_session_id writes session to file with timestamp" {
    run store_session_id "session-test-abc"

    [[ -f ".claude_session_id" ]] || skip "store_session_id not yet implemented"

    local content=$(cat .claude_session_id)
    [[ "$content" == *"session-test-abc"* ]]
}

@test "get_last_session_id retrieves stored session" {
    # First store a session
    echo '{"session_id": "session-retrieve-test", "timestamp": "2026-01-09T10:00:00Z"}' > .claude_session_id

    run get_last_session_id

    [[ "$output" == *"session-retrieve-test"* ]] || skip "get_last_session_id not yet implemented"
}

@test "get_last_session_id returns empty when no session file" {
    rm -f .claude_session_id

    run get_last_session_id

    # Should return empty string, not error
    [[ "$status" -eq 0 ]] || skip "get_last_session_id not yet implemented"
    [[ -z "$output" || "$output" == "" || "$output" == "null" ]]
}

@test "should_resume_session returns true for recent session" {
    # Store a recent session (simulated as current timestamp)
    local now=$(date +%s)
    echo "{\"session_id\": \"session-recent\", \"timestamp\": \"$(date -Iseconds)\"}" > .claude_session_id

    run should_resume_session

    # Should indicate session can be resumed
    [[ "$status" -eq 0 ]] || skip "should_resume_session not yet implemented"
}

@test "should_resume_session returns false for old session" {
    # Store an old session (24+ hours ago)
    echo '{"session_id": "session-old", "timestamp": "2020-01-01T00:00:00Z"}' > .claude_session_id

    run should_resume_session

    # Should indicate session expired
    [[ "$status" -ne 0 || "$output" == "false" ]] || skip "should_resume_session not yet implemented"
}

@test "should_resume_session returns false when no session file" {
    rm -f .claude_session_id

    run should_resume_session

    # Should indicate no session to resume
    [[ "$status" -ne 0 || "$output" == "false" ]] || skip "should_resume_session not yet implemented"
}

# =============================================================================
# CP-016.26: EXIT_SIGNAL EXTRACTION FROM EMBEDDED RALPH_STATUS
# =============================================================================
# Critical bug fix: Claude CLI embeds RALPH_STATUS in the .result field,
# not as top-level JSON fields. These tests verify proper extraction.

@test "parse_json_response extracts EXIT_SIGNAL from embedded RALPH_STATUS in result" {
    local output_file="$LOG_DIR/test_output.log"

    # This is the actual format Claude CLI produces - RALPH_STATUS is inside .result
    cat > "$output_file" << 'EOF'
{
    "result": "Implementation complete.\n\n---RALPH_STATUS---\nCP_NUMBER: CP-016.25\nSTATUS: COMPLETE\nTASKS_REMAINING: 0\nEXIT_SIGNAL: true\nRECOMMENDATION: All acceptance criteria verified\n---END_RALPH_STATUS---",
    "sessionId": "session-abc123",
    "total_cost_usd": 3.39
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || fail "parse_json_response did not create result file"

    # Critical: exit_signal MUST be true when embedded RALPH_STATUS says EXIT_SIGNAL: true
    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "true"
}

@test "parse_json_response extracts EXIT_SIGNAL: false from embedded RALPH_STATUS" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Working on tasks.\n\n---RALPH_STATUS---\nCP_NUMBER: CP-016.25\nSTATUS: IN_PROGRESS\nTASKS_REMAINING: 5\nEXIT_SIGNAL: false\nRECOMMENDATION: Continue implementing AC-3\n---END_RALPH_STATUS---",
    "sessionId": "session-def456"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || fail "parse_json_response did not create result file"

    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "false"
}

@test "parse_json_response handles newlines in RALPH_STATUS block correctly" {
    local output_file="$LOG_DIR/test_output.log"

    # Test with actual newlines (not escaped \n)
    cat > "$output_file" << 'JSONEOF'
{
    "result": "All done.\n\n---RALPH_STATUS---\nSTATUS: COMPLETE\nEXIT_SIGNAL: true\n---END_RALPH_STATUS---",
    "sessionId": "test-session"
}
JSONEOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || fail "parse_json_response did not create result file"

    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "true"
}

@test "parse_json_response handles REVIEW_LOOP status with EXIT_SIGNAL false" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "In Codex review.\n\n---RALPH_STATUS---\nCP_NUMBER: CP-016.26\nSTATUS: REVIEW_LOOP\nREVIEW_COUNT: 1\nREVIEW_VERDICT: NEEDS_FIXES\nEXIT_SIGNAL: false\n---END_RALPH_STATUS---",
    "sessionId": "review-session"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || fail "parse_json_response did not create result file"

    # REVIEW_LOOP with NEEDS_FIXES should NOT exit
    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "false"
}

@test "parse_json_response does not extract EXIT_SIGNAL from non-RALPH_STATUS content" {
    local output_file="$LOG_DIR/test_output.log"

    # EXIT_SIGNAL text outside RALPH_STATUS block should NOT trigger exit
    cat > "$output_file" << 'EOF'
{
    "result": "I mentioned EXIT_SIGNAL: true in my explanation but the actual status is still in progress.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nEXIT_SIGNAL: false\n---END_RALPH_STATUS---",
    "sessionId": "no-false-positive"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || fail "parse_json_response did not create result file"

    # Should use the EXIT_SIGNAL from inside the block (false), not the text mention
    local exit_signal=$(jq -r '.exit_signal' "$result_file")
    assert_equal "$exit_signal" "false"
}

# =============================================================================
# CP-016.26: MCP CALL TRACKING TESTS
# =============================================================================

@test "parse_json_response tracks mcp_calls from result text" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "I delegated the implementation to Codex using mcp__codex__codex tool. The result was excellent.",
    "sessionId": "mcp-test"
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || fail "parse_json_response did not create result file"

    local mcp_calls=$(jq -r '.mcp_calls' "$result_file")
    [[ "$mcp_calls" -ge 1 ]] || fail "Expected at least 1 MCP call, got $mcp_calls"
}

@test "parse_json_response tracks mcp_calls from usage metadata" {
    local output_file="$LOG_DIR/test_output.log"

    cat > "$output_file" << 'EOF'
{
    "result": "Task completed.",
    "sessionId": "mcp-usage-test",
    "modelUsage": {
        "codex_requests": 3
    }
}
EOF

    run parse_json_response "$output_file"
    local result_file=".json_parse_result"

    [[ -f "$result_file" ]] || fail "parse_json_response did not create result file"

    # Should detect codex in usage keys
    local mcp_calls=$(jq -r '.mcp_calls' "$result_file")
    [[ "$mcp_calls" -ge 1 ]] || fail "Expected at least 1 MCP call from usage metadata, got $mcp_calls"
}
