#!/usr/bin/env bats
# Unit Tests for Rate Limiting Logic

load '../helpers/test_helper'

# Source ralph functions (we need to extract these first)
setup() {
    # Source helper functions
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

    # Set up environment
    export MAX_CALLS_PER_HOUR=100
    export CALL_COUNT_FILE=".call_count"
    export TIMESTAMP_FILE=".last_reset"

    # Stub logger used by calculate_wait_time (avoid noisy output)
    log_status() { :; }

    # Source CP-016.26 autonomous helpers directly from ralph_loop.sh
    local ralph_loop_sh="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
    source <(sed -n '/^loop_count_pre_increment_for_resume() {/,/^}$/p' "$ralph_loop_sh")
    source <(sed -n '/^calculate_wait_time() {/,/^}$/p' "$ralph_loop_sh")

    # Create temp test directory
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"

    # Initialize files
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
}

teardown() {
    # Clean up
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper function: can_make_call (extracted from ralph_loop.sh)
can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call
    else
        return 0  # Can make call
    fi
}

# Helper function: increment_call_counter (extracted from ralph_loop.sh)
increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Test 1: can_make_call returns success when under limit
@test "can_make_call returns success when under limit" {
    echo "50" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 2: can_make_call returns success when exactly at limit minus 1
@test "can_make_call returns success when at limit minus 1" {
    echo "99" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 3: can_make_call returns failure when at limit
@test "can_make_call returns failure when at limit" {
    echo "100" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_failure
}

# Test 4: can_make_call returns failure when over limit
@test "can_make_call returns failure when over limit" {
    echo "150" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_failure
}

# Test 5: can_make_call returns success when file doesn't exist (0 calls)
@test "can_make_call returns success when call count file missing" {
    rm -f "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 6: increment_call_counter increases from 0
@test "increment_call_counter increases from 0 to 1" {
    echo "0" > "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "1"
    assert_equal "$(cat $CALL_COUNT_FILE)" "1"
}

# Test 7: increment_call_counter increases from middle value
@test "increment_call_counter increases from 42 to 43" {
    echo "42" > "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "43"
    assert_equal "$(cat $CALL_COUNT_FILE)" "43"
}

# Test 8: increment_call_counter works near limit
@test "increment_call_counter increases from 99 to 100" {
    echo "99" > "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "100"
    assert_equal "$(cat $CALL_COUNT_FILE)" "100"
}

# Test 9: increment_call_counter works when file missing
@test "increment_call_counter creates file and sets to 1 when missing" {
    rm -f "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "1"
    assert_equal "$(cat $CALL_COUNT_FILE)" "1"
}

# Test 10: Rate limit with different MAX_CALLS value (50)
@test "can_make_call respects MAX_CALLS_PER_HOUR of 50" {
    echo "49" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=50

    run can_make_call
    assert_success

    echo "50" > "$CALL_COUNT_FILE"
    run can_make_call
    assert_failure
}

# Test 11: Rate limit with different MAX_CALLS value (25)
@test "can_make_call respects MAX_CALLS_PER_HOUR of 25" {
    echo "24" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=25

    run can_make_call
    assert_success

    echo "25" > "$CALL_COUNT_FILE"
    run can_make_call
    assert_failure
}

# Test 12: Counter persistence across multiple increments
@test "counter persists correctly across multiple increments" {
    echo "0" > "$CALL_COUNT_FILE"

    result1=$(increment_call_counter)  # 1
    result2=$(increment_call_counter)  # 2
    result3=$(increment_call_counter)  # 3
    result4=$(increment_call_counter)  # 4

    assert_equal "$result4" "4"
    assert_equal "$(cat $CALL_COUNT_FILE)" "4"
}

# Test 13: Call count file contains only a number
@test "call count file contains valid integer" {
    run increment_call_counter

    # Check the call count file contains a valid integer
    value=$(cat "$CALL_COUNT_FILE")
    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "Call count file does not contain valid integer: $value"
        return 1
    }
}

# Test 14: Can make call with zero calls
@test "can_make_call returns success with zero calls made" {
    echo "0" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 15: Edge case - very large MAX_CALLS value
@test "can_make_call works with large MAX_CALLS value" {
    echo "5000" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=10000

    run can_make_call
    assert_success
}

# =============================================================================
# CP-016.26: AUTONOMOUS RATE LIMIT WAIT + RESUME HELPERS
# =============================================================================

@test "calculate_wait_time falls back to 3600 when reset time cannot be parsed" {
    run calculate_wait_time "You've hit your limit."
    assert_success
    assert_equal "$output" "3600"
}

@test "calculate_wait_time falls back to 3600 when timezone is invalid" {
    run calculate_wait_time "You've hit your limit · resets 11pm (Invalid/Timezone)"
    assert_success
    assert_equal "$output" "3600"
}

@test "calculate_wait_time parses hour-only reset time" {
    run calculate_wait_time "You've hit your limit · resets 11pm (UTC)"
    assert_success
    [[ "$output" =~ ^[0-9]+$ ]] || fail "Expected integer seconds, got: $output"
    [[ "$output" -ge 300 ]] || fail "Expected >=300 seconds buffer, got: $output"
    [[ "$output" -le 90000 ]] || fail "Expected <=90000 seconds, got: $output"
}

@test "calculate_wait_time parses hour+minute reset time" {
    run calculate_wait_time "You've hit your limit · resets 11:30pm (UTC)"
    assert_success
    [[ "$output" =~ ^[0-9]+$ ]] || fail "Expected integer seconds, got: $output"
    [[ "$output" -ge 300 ]] || fail "Expected >=300 seconds buffer, got: $output"
    [[ "$output" -le 90000 ]] || fail "Expected <=90000 seconds, got: $output"
}

@test "loop_count_pre_increment_for_resume preserves loop numbering after increment" {
    run loop_count_pre_increment_for_resume "8"
    assert_success
    assert_equal "$output" "7"

    local next_loop=$((output + 1))
    assert_equal "$next_loop" "8"
}

@test "rate limit recovery state preserves loop numbering" {
    cat > .rate_limit_loop << 'EOF'
{"mode":"rate_limit_wait","wait_until":123,"loop_count":8}
EOF

    local saved_loop_count
    saved_loop_count=$(jq -r '.loop_count' .rate_limit_loop)

    run loop_count_pre_increment_for_resume "$saved_loop_count"
    assert_success

    local next_loop=$((output + 1))
    assert_equal "$next_loop" "8"
}
