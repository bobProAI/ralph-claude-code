#!/bin/bash

# Claude Code Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Claude Code with usage management

set -e  # Exit on any error

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/response_analyzer.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"

# Configuration
STATE_DIR="."  # Default: current directory (preserves existing behavior)
STATE_PATHS_READY=false
PROMPT_FILE="PROMPT.md"
FIX_PLAN_FILE="@fix_plan.md"  # Default fix plan location
AUTONOMOUS_MODE=false  # CP-016.26: When true, auto-wait on rate limit instead of prompting
FOCUS_FIX_PLAN="${FOCUS_FIX_PLAN:-true}"  # When true, append remaining fix-plan items to the system prompt
FIX_PLAN_FOCUS_MAX_ITEMS="${FIX_PLAN_FOCUS_MAX_ITEMS:-12}"
FIX_PLAN_FOCUS_MAX_CHARS="${FIX_PLAN_FOCUS_MAX_CHARS:-1200}"
RESET_REVIEW_STATE=false
# Note: These paths are relative to STATE_DIR - they will be prefixed after arg parsing
LOG_DIR_NAME="logs"
DOCS_DIR_NAME="docs/generated"
STATUS_FILE_NAME="status.json"
PROGRESS_FILE_NAME="progress.json"
CLAUDE_CODE_CMD="claude"
MAX_CALLS_PER_HOUR=100  # Adjust based on your plan
VERBOSE_PROGRESS=false  # Default: no verbose progress updates
CLAUDE_TIMEOUT_MINUTES=15  # Default: 15 minutes timeout for Claude Code execution
SLEEP_DURATION=3600     # 1 hour in seconds
# Note: These file names are prefixed with STATE_DIR after arg parsing
CALL_COUNT_FILE_NAME=".call_count"
TIMESTAMP_FILE_NAME=".last_reset"
USE_TMUX=false

# Modern Claude CLI configuration (Phase 1.1)
CLAUDE_OUTPUT_FORMAT="json"              # Options: json, text
CLAUDE_ALLOWED_TOOLS="Read,Write,Bash(git *),Bash(pnpm *)"  # Comma-separated list of allowed tools
CLAUDE_USE_CONTINUE=true                 # Enable session continuity
CLAUDE_SESSION_FILE_NAME=".claude_session_id" # Session ID persistence file (prefixed with STATE_DIR)
CLAUDE_MIN_VERSION="2.0.76"              # Minimum required Claude CLI version
CLAUDE_MCP_CONFIG=""                     # Path to .mcp.json for MCP server configuration
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-}"        # Optional Claude CLI permission mode override
CODEX_REVIEW_ONLY="${CODEX_REVIEW_ONLY:-false}"            # When true, only allow Codex MCP tool
CODEX_CONTEXT_FILE="${CODEX_CONTEXT_FILE:-}"               # Optional file list for Codex context bundle
CODEX_CONTEXT_MAX_LINES="${CODEX_CONTEXT_MAX_LINES:-200}"
CODEX_CONTEXT_MAX_CHARS="${CODEX_CONTEXT_MAX_CHARS:-2000}"
CODEX_CONTEXT_TOTAL_MAX_CHARS="${CODEX_CONTEXT_TOTAL_MAX_CHARS:-8000}"
REVIEW_ONLY_RETRY_DONE="${REVIEW_ONLY_RETRY_DONE:-false}"

# Session management configuration (Phase 1.2)
# Note: SESSION_EXPIRATION_SECONDS is defined in lib/response_analyzer.sh (86400 = 24 hours)
RALPH_SESSION_FILE_NAME=".ralph_session"              # Ralph-specific session tracking (prefixed with STATE_DIR)
RALPH_SESSION_HISTORY_FILE_NAME=".ralph_session_history"  # Session transition history (prefixed)
# Session expiration: 24 hours default balances project continuity with fresh context
# Too short = frequent context loss; Too long = stale context causes unpredictable behavior
CLAUDE_SESSION_EXPIRY_HOURS=${CLAUDE_SESSION_EXPIRY_HOURS:-24}

# Valid tool patterns for --allowed-tools validation
# Tools can be exact matches or pattern matches with wildcards in parentheses
# Scoped tools: Read(<glob>), Write(<glob>), Edit(<glob>) restrict file access
VALID_TOOL_PATTERNS=(
    "Write"
    "Read"
    "Edit"
    "MultiEdit"
    "Glob"
    "Grep"
    "Task"
    "TodoWrite"
    "WebFetch"
    "WebSearch"
    "Bash(git *)"
    "Bash(pnpm *)"
    "NotebookEdit"
)

# Allowed Bash command patterns for monorepo safety (used with scoped tokens)
ALLOWED_BASH_PATTERNS=(
    "git *"
    "pnpm *"
)

# Exit detection configuration
EXIT_SIGNALS_FILE_NAME=".exit_signals"  # Prefixed with STATE_DIR after arg parsing
FIX_PLAN_FOCUS_STATE_FILE_NAME=".fix_plan_focus_state.json"
REVIEW_STATE_FILE_NAME=".review_state.json"
FIX_PLAN_PROGRESS_FILE_NAME=".fix_plan_progress.json"
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30  # If more than 30% of recent loops are test-only, flag it

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Setup state paths with STATE_DIR prefix (called after arg parsing)
setup_state_paths() {
    # Validate STATE_DIR
    if [ -z "$STATE_DIR" ]; then
        echo "Error: --state-dir cannot be empty"
        exit 1
    fi

    # Create STATE_DIR if missing
    mkdir -p "$STATE_DIR"

    # Apply STATE_DIR prefix to all state file paths
    LOG_DIR="$STATE_DIR/$LOG_DIR_NAME"
    DOCS_DIR="$STATE_DIR/$DOCS_DIR_NAME"
    STATUS_FILE="$STATE_DIR/$STATUS_FILE_NAME"
    PROGRESS_FILE="$STATE_DIR/$PROGRESS_FILE_NAME"
    CALL_COUNT_FILE="$STATE_DIR/$CALL_COUNT_FILE_NAME"
    TIMESTAMP_FILE="$STATE_DIR/$TIMESTAMP_FILE_NAME"
    CLAUDE_SESSION_FILE="$STATE_DIR/$CLAUDE_SESSION_FILE_NAME"
    RALPH_SESSION_FILE="$STATE_DIR/$RALPH_SESSION_FILE_NAME"
    RALPH_SESSION_HISTORY_FILE="$STATE_DIR/$RALPH_SESSION_HISTORY_FILE_NAME"
    EXIT_SIGNALS_FILE="$STATE_DIR/$EXIT_SIGNALS_FILE_NAME"
    FIX_PLAN_FOCUS_STATE_FILE="$STATE_DIR/$FIX_PLAN_FOCUS_STATE_FILE_NAME"
    REVIEW_STATE_FILE="$STATE_DIR/$REVIEW_STATE_FILE_NAME"
    FIX_PLAN_PROGRESS_FILE="$STATE_DIR/$FIX_PLAN_PROGRESS_FILE_NAME"
    CB_STATE_FILE="$STATE_DIR/.circuit_breaker_state"
    CB_HISTORY_FILE="$STATE_DIR/.circuit_breaker_history"
    RESPONSE_ANALYSIS_FILE="$STATE_DIR/.response_analysis"
    JSON_PARSE_RESULT_FILE="$STATE_DIR/.json_parse_result"

    # Initialize directories under STATE_DIR
    mkdir -p "$LOG_DIR" "$DOCS_DIR"
    STATE_PATHS_READY=true
}

# Check if tmux is available
check_tmux_available() {
    if ! command -v tmux &> /dev/null; then
        log_status "ERROR" "tmux is not installed. Please install tmux or run without --monitor flag."
        echo "Install tmux:"
        echo "  Ubuntu/Debian: sudo apt-get install tmux"
        echo "  macOS: brew install tmux"
        echo "  CentOS/RHEL: sudo yum install tmux"
        exit 1
    fi
}

# Setup tmux session with monitor
setup_tmux_session() {
    local session_name="ralph-$(date +%s)"
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    
    log_status "INFO" "Setting up tmux session: $session_name"
    
    # Create new tmux session detached
    tmux new-session -d -s "$session_name" -c "$(pwd)"
    
    # Split window vertically to create monitor pane on the right
    tmux split-window -h -t "$session_name" -c "$(pwd)"
    
    # Start monitor in the right pane
    if command -v ralph-monitor &> /dev/null; then
        tmux send-keys -t "$session_name:0.1" "ralph-monitor --state-dir '$STATE_DIR'" Enter
    else
        tmux send-keys -t "$session_name:0.1" "'$ralph_home/ralph_monitor.sh' --state-dir '$STATE_DIR'" Enter
    fi
    
    # Start ralph loop in the left pane (exclude tmux flag to avoid recursion)
    local ralph_cmd
    if command -v ralph &> /dev/null; then
        ralph_cmd="ralph"
    else
        ralph_cmd="'$ralph_home/ralph_loop.sh'"
    fi
    
    if [[ "$MAX_CALLS_PER_HOUR" != "100" ]]; then
        ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    fi
    if [[ "$PROMPT_FILE" != "PROMPT.md" ]]; then
        ralph_cmd="$ralph_cmd --prompt '$PROMPT_FILE'"
    fi
    
    tmux send-keys -t "$session_name:0.0" "$ralph_cmd" Enter
    
    # Focus on left pane (main ralph loop)
    tmux select-pane -t "$session_name:0.0"
    
    # Set window title
    tmux rename-window -t "$session_name:0" "Ralph: Loop | Monitor"
    
    log_status "SUCCESS" "Tmux session created. Attaching to session..."
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"
    
    # Attach to session (this will block until session ends)
    tmux attach-session -t "$session_name"
    
    exit 0
}

# Initialize call tracking
init_call_tracking() {
    log_status "INFO" "DEBUG: Entered init_call_tracking..."
    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    # Reset counter if it's a new hour
    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$CALL_COUNT_FILE"
        echo "$current_hour" > "$TIMESTAMP_FILE"
        log_status "INFO" "Call counter reset for new hour: $current_hour"
    fi

    # Initialize exit signals tracking if it doesn't exist
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    # Initialize circuit breaker
    init_circuit_breaker

    log_status "INFO" "DEBUG: Completed init_call_tracking successfully"
}

# Log function with timestamps and colors
log_status() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP") color=$PURPLE ;;
    esac
    
    echo -e "${color}[$timestamp] [$level] $message${NC}"
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log"
}

# Update status JSON for external monitoring
update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}
    
    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

# Check if we can make another call
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

# Increment call counter
increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Wait for rate limit reset with countdown
wait_for_reset() {
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    log_status "WARN" "Rate limit reached ($calls_made/$MAX_CALLS_PER_HOUR). Waiting for reset..."
    
    # Calculate time until next hour
    local current_minute
    current_minute=$(date +%M)
    current_minute=$((10#$current_minute))
    local current_second
    current_second=$(date +%S)
    current_second=$((10#$current_second))
    local wait_time=$(((60 - current_minute - 1) * 60 + (60 - current_second)))
    
    log_status "INFO" "Sleeping for $wait_time seconds until next hour..."
    
    # Countdown display
    while [[ $wait_time -gt 0 ]]; do
        local hours=$((wait_time / 3600))
        local minutes=$(((wait_time % 3600) / 60))
        local seconds=$((wait_time % 60))
        
        printf "\r${YELLOW}Time until reset: %02d:%02d:%02d${NC}" $hours $minutes $seconds
        sleep 1
        ((wait_time--))
    done
    printf "\n"
    
    # Reset counter
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Check if we should gracefully exit
should_exit_gracefully() {
    log_status "INFO" "DEBUG: Checking exit conditions..." >&2

    # Pre-compute fix plan completion so EXIT_SIGNAL can be gated
    local total_items=0
    local completed_items=0
    local deferred_items=0
    local in_progress_items=0
    local open_items=0
    local fix_plan_complete="false"
    local mcp_calls=0
    local mcp_success_calls=0
    local mcp_denied=0
    local mcp_required="true"
    local mcp_ready="false"

    if [[ -f "$FIX_PLAN_FILE" ]]; then
        local IFS=$' \t\n'
        read -r total_items completed_items deferred_items in_progress_items open_items <<< "$(get_fix_plan_counts)"

        log_status "INFO" "DEBUG: $FIX_PLAN_FILE check - total:$total_items, done:$completed_items, deferred:$deferred_items, in_progress:$in_progress_items, open:$open_items" >&2

        if [[ $total_items -gt 0 ]] && [[ $((completed_items + deferred_items)) -eq $total_items ]]; then
            fix_plan_complete="true"
        fi
    else
        log_status "INFO" "DEBUG: $FIX_PLAN_FILE file not found" >&2
    fi

    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        mcp_calls=$(jq -r '.analysis.mcp_calls // .mcp_calls // 0' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "0")
        mcp_success_calls=$(jq -r '.analysis.mcp_success_calls // .mcp_success_calls // 0' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "0")
        mcp_denied=$(jq -r '.analysis.mcp_denied // .mcp_denied // 0' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "0")
    fi
    if ! [[ "$mcp_calls" =~ ^[0-9]+$ ]]; then
        mcp_calls=0
    fi
    if ! [[ "$mcp_success_calls" =~ ^[0-9]+$ ]]; then
        mcp_success_calls=0
    fi
    if ! [[ "$mcp_denied" =~ ^[0-9]+$ ]]; then
        mcp_denied=0
    fi
    if [[ "$mcp_success_calls" -gt 0 ]]; then
        mcp_ready="true"
    fi
    if [[ "$mcp_calls" -le 0 && "$mcp_denied" -gt 0 ]]; then
        log_status "WARN" "MCP tool call denied by permissions (mcp_denied=$mcp_denied)" >&2
    fi

    # CP-016.26: PRIORITY 1 - Check Claude's explicit EXIT_SIGNAL first
    # This is the authoritative signal from Claude's RALPH_STATUS block.
    # If Claude says EXIT_SIGNAL: true, we exit only when the fix plan is complete.
    local claude_exit_signal="false"
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        # Check both .analysis.exit_signal and .exit_signal (different formats)
        claude_exit_signal=$(jq -r '.analysis.exit_signal // .exit_signal // "false"' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
    fi

    if [[ "$claude_exit_signal" == "true" ]]; then
        if [[ "$open_items" -gt 0 ]]; then
            local fix_plan_changed
            fix_plan_changed=$(fix_plan_changed_since_last)
            if [[ "$fix_plan_changed" == "false" ]]; then
                log_status "WARN" "Exit signal ignored: no fix_plan progress since last loop (open=$open_items)" >&2
            fi
        fi
        if [[ "$fix_plan_complete" != "true" ]]; then
            log_status "WARN" "Exit signal ignored: fix plan incomplete (done+deferred=$((completed_items + deferred_items))/$total_items)" >&2
            return 1
        fi
        if [[ "$mcp_required" == "true" && "$mcp_ready" != "true" ]]; then
            log_status "WARN" "Exit signal ignored: Codex MCP review incomplete (mcp_success_calls=$mcp_success_calls)" >&2
            return 1
        fi

        log_status "SUCCESS" "Exit condition: Claude explicit EXIT_SIGNAL=true in RALPH_STATUS block"
        echo "exit_signal"
        return 0
    fi

    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        log_status "INFO" "DEBUG: No exit signals file found, continuing..." >&2
        return 1  # Don't exit, file doesn't exist
    fi

    local signals=$(cat "$EXIT_SIGNALS_FILE")
    log_status "INFO" "DEBUG: Exit signals content: $signals" >&2

    # Count recent signals (last 5 loops) - with error handling
    local recent_test_loops
    local recent_done_signals
    local recent_completion_indicators

    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")

    log_status "INFO" "DEBUG: Exit counts - test_loops:$recent_test_loops, done_signals:$recent_done_signals, completion:$recent_completion_indicators" >&2

    # Check for exit conditions (heuristics - only if EXIT_SIGNAL not explicit)

    # 2. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        log_status "WARN" "Exit condition: Too many test-focused loops ($recent_test_loops >= $MAX_CONSECUTIVE_TEST_LOOPS)"
        echo "test_saturation"
        return 0
    fi

    # 3. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        if [[ "$mcp_required" == "true" && "$mcp_ready" != "true" ]]; then
            log_status "WARN" "Exit condition met but blocked (no MCP review): completion signals ($recent_done_signals >= $MAX_CONSECUTIVE_DONE_SIGNALS)" >&2
        else
            log_status "WARN" "Exit condition: Multiple completion signals ($recent_done_signals >= $MAX_CONSECUTIVE_DONE_SIGNALS)"
            echo "completion_signals"
            return 0
        fi
    fi

    # 4. Strong completion indicators (backup heuristic)
    if [[ $recent_completion_indicators -ge 3 ]]; then
        if [[ "$mcp_required" == "true" && "$mcp_ready" != "true" ]]; then
            log_status "WARN" "Exit condition met but blocked (no MCP review): completion indicators ($recent_completion_indicators >= 3)" >&2
        else
            log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators >= 3)" >&2
            echo "project_complete"
            return 0
        fi
    fi
    
    # 4. Check fix_plan.md for completion
    if [[ "$fix_plan_complete" == "true" ]]; then
        if [[ "$mcp_required" == "true" && "$mcp_ready" != "true" ]]; then
            log_status "WARN" "Exit condition met but blocked (no MCP review): fix plan complete (done+deferred=$((completed_items + deferred_items))/$total_items)" >&2
        else
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($((completed_items + deferred_items))/$total_items)" >&2
            echo "plan_complete"
            return 0
        fi
    fi
    
    log_status "INFO" "DEBUG: No exit conditions met, continuing loop" >&2
    echo ""  # Return empty string instead of using return code
}

# =============================================================================
# MODERN CLI HELPER FUNCTIONS (Phase 1.1)
# =============================================================================

# Check Claude CLI version for compatibility with modern flags
check_claude_version() {
    local version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [[ -z "$version" ]]; then
        log_status "WARN" "Cannot detect Claude CLI version, assuming compatible"
        return 0
    fi

    # Compare versions (simplified semver comparison)
    local required="$CLAUDE_MIN_VERSION"

    # Convert to comparable integers (major * 10000 + minor * 100 + patch)
    local ver_parts=(${version//./ })
    local req_parts=(${required//./ })

    local ver_num=$((${ver_parts[0]:-0} * 10000 + ${ver_parts[1]:-0} * 100 + ${ver_parts[2]:-0}))
    local req_num=$((${req_parts[0]:-0} * 10000 + ${req_parts[1]:-0} * 100 + ${req_parts[2]:-0}))

    if [[ $ver_num -lt $req_num ]]; then
        log_status "WARN" "Claude CLI version $version < $required. Some modern features may not work."
        log_status "WARN" "Consider upgrading: npm update -g @anthropic-ai/claude-code"
        return 1
    fi

    log_status "INFO" "Claude CLI version $version (>= $required) - modern features enabled"
    return 0
}

# Validate allowed tools against whitelist
# Returns 0 if valid, 1 if invalid with error message
# Supports scoped tokens: Read(<glob>), Write(<glob>), Edit(<glob>)
# Bash(...) patterns are restricted to ALLOWED_BASH_PATTERNS for monorepo safety
validate_allowed_tools() {
    local tools_input=$1

    if [[ -z "$tools_input" ]]; then
        return 0  # Empty is valid (uses defaults)
    fi

    # Split by comma
    local IFS=','
    read -ra tools <<< "$tools_input"

    for tool in "${tools[@]}"; do
        # Trim whitespace
        tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ -z "$tool" ]]; then
            continue
        fi

        local valid=false

        # Check against exact valid patterns
        for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
            if [[ "$tool" == "$pattern" ]]; then
                valid=true
                break
            fi
        done

        # If not exact match, check for scoped tokens
        if [[ "$valid" == "false" ]]; then
            # Check for scoped file tools: Read(<glob>), Write(<glob>), Edit(<glob>)
            if [[ "$tool" =~ ^(Read|Write|Edit)\((.+)\)$ ]]; then
                local glob_pattern="${BASH_REMATCH[2]}"
                # Validate non-empty glob pattern
                if [[ -n "$glob_pattern" && ! "$glob_pattern" =~ ^[[:space:]]*$ ]]; then
                    valid=true
                else
                    echo "Error: Scoped tool '$tool' has empty or whitespace-only glob pattern"
                    return 1
                fi
            fi

            # Check for Bash(...) pattern - restricted to allowed patterns
            if [[ "$tool" =~ ^Bash\((.+)\)$ ]]; then
                local bash_pattern="${BASH_REMATCH[1]}"
                # Check against allowed bash patterns
                for allowed in "${ALLOWED_BASH_PATTERNS[@]}"; do
                    if [[ "$bash_pattern" == "$allowed" ]]; then
                        valid=true
                        break
                    fi
                done
                if [[ "$valid" == "false" ]]; then
                    echo "Error: Bash pattern '$bash_pattern' is not in the allowed list"
                    echo "Allowed Bash patterns: ${ALLOWED_BASH_PATTERNS[*]}"
                    return 1
                fi
            fi
        fi

        if [[ "$valid" == "false" ]]; then
            echo "Error: Invalid tool in --allowed-tools: '$tool'"
            echo "Valid tools: ${VALID_TOOL_PATTERNS[*]}"
            echo "Scoped tools: Read(<glob>), Write(<glob>), Edit(<glob>)"
            echo "Allowed Bash patterns: ${ALLOWED_BASH_PATTERNS[*]}"
            return 1
        fi
    done

    return 0
}

# Build loop context for Claude Code session
# Provides loop-specific context via --append-system-prompt
build_loop_context() {
    local loop_count=$1
    local context=""
    local incomplete_tasks=0

    # Add loop number
    context="Loop #${loop_count}. "

    # Extract incomplete tasks from fix plan
    if [[ -f "$FIX_PLAN_FILE" ]]; then
        incomplete_tasks=$({ grep -c "^- \\[ \\]" "$FIX_PLAN_FILE" 2>/dev/null || true; } | head -n1)
        [[ -z "$incomplete_tasks" ]] && incomplete_tasks=0
        context+="Remaining tasks: ${incomplete_tasks}. "

        local total_items completed_items deferred_items in_progress_items open_items
        read -r total_items completed_items deferred_items in_progress_items open_items <<< "$(get_fix_plan_counts)"
        local review_count
        review_count=$(get_review_state_count)
        if [[ $total_items -gt 0 && $((completed_items + deferred_items)) -eq $total_items && "$review_count" == "0" ]]; then
            echo "Loop #${loop_count}. Remaining tasks: ${incomplete_tasks}. Codex review pending. Call mcp__codex__codex now; do not claim COMPLETE without MCP review."
            return 0
        fi
    fi

    # Add circuit breaker state
    if [[ -f "$CB_STATE_FILE" ]]; then
        local cb_state=$(jq -r '.state // "UNKNOWN"' "$CB_STATE_FILE" 2>/dev/null)
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
    fi

    # Add previous loop summary (truncated)
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local prev_summary=$(jq -r '.analysis.work_summary // ""' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null | head -c 200)
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            context+="Previous: ${prev_summary}"
        fi
    fi

    # Limit total length to ~500 chars
    echo "${context:0:500}"
}

# Get session file age in hours (cross-platform)
# Returns: age in hours on stdout, or -1 if stat fails
# Note: Returns 0 for files less than 1 hour old
get_session_file_age_hours() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    local os_type
    os_type=$(uname)

    local file_mtime=""
    if [[ "$os_type" == "Darwin" ]]; then
        # macOS (BSD stat), with GNU fallback in case coreutils stat is on PATH
        file_mtime=$(stat -f %m "$file" 2>/dev/null || true)
        if ! [[ "$file_mtime" =~ ^[0-9]+$ ]]; then
            file_mtime=$(stat -c %Y "$file" 2>/dev/null || true)
        fi
    else
        # Linux (GNU stat), with BSD fallback if needed
        file_mtime=$(stat -c %Y "$file" 2>/dev/null || true)
        if ! [[ "$file_mtime" =~ ^[0-9]+$ ]]; then
            file_mtime=$(stat -f %m "$file" 2>/dev/null || true)
        fi
    fi

    # Ensure we only use numeric mtimes to avoid arithmetic parsing issues
    if ! [[ "$file_mtime" =~ ^[0-9]+$ ]]; then
        file_mtime=""
    fi

    # Handle stat failure - return -1 to indicate error
    # This prevents false expiration when stat fails
    if [[ -z "$file_mtime" || "$file_mtime" == "0" ]]; then
        echo "-1"
        return
    fi

    local current_time
    current_time=$(date +%s)

    local age_seconds=$((current_time - file_mtime))
    local age_hours=$((age_seconds / 3600))

    echo "$age_hours"
}

# Initialize or resume Claude session (with expiration check)
#
# Session Expiration Strategy:
# - Default expiration: 24 hours (configurable via CLAUDE_SESSION_EXPIRY_HOURS)
# - 24 hours chosen because: long enough for multi-day projects, short enough
#   to prevent stale context from causing unpredictable behavior
# - Sessions auto-expire to ensure Claude starts fresh periodically
#
# Returns (stdout):
#   - Session ID string: when resuming a valid, non-expired session
#   - Empty string: when starting new session (no file, expired, or stat error)
#
# Return codes:
#   - 0: Always returns success (caller should check stdout for session ID)
#
init_claude_session() {
    if [[ -f "$CLAUDE_SESSION_FILE" ]]; then
        # Check session age
        local age_hours
        age_hours=$(get_session_file_age_hours "$CLAUDE_SESSION_FILE")

        # Handle stat failure (-1) - treat as needing new session
        # Don't expire sessions when we can't determine age
        if [[ $age_hours -eq -1 ]]; then
            log_status "WARN" "Could not determine session age, starting new session"
            rm -f "$CLAUDE_SESSION_FILE"
            echo ""
            return 0
        fi

        # Check if session has expired
        if [[ $age_hours -ge $CLAUDE_SESSION_EXPIRY_HOURS ]]; then
            log_status "INFO" "Session expired (${age_hours}h old, max ${CLAUDE_SESSION_EXPIRY_HOURS}h), starting new session"
            rm -f "$CLAUDE_SESSION_FILE"
            echo ""
            return 0
        fi

        # Session is valid, try to read it
        local session_id=$(cat "$CLAUDE_SESSION_FILE" 2>/dev/null)
        if [[ -n "$session_id" ]]; then
            log_status "INFO" "Resuming Claude session: ${session_id:0:20}... (${age_hours}h old)"
            echo "$session_id"
            return 0
        fi
    fi

    log_status "INFO" "Starting new Claude session"
    echo ""
}

# Save session ID after successful execution
save_claude_session() {
    local output_file=$1

    # Try to extract session ID from JSON output
    if [[ -f "$output_file" ]]; then
        local session_id=$(jq -r '.metadata.session_id // .session_id // empty' "$output_file" 2>/dev/null)
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            echo "$session_id" > "$CLAUDE_SESSION_FILE"
            log_status "INFO" "Saved Claude session: ${session_id:0:20}..."
        fi
    fi
}

# =============================================================================
# CP-016.26: AUTONOMOUS MODE HELPER FUNCTIONS
# =============================================================================

# Resume semantics:
# The main loop increments `loop_count` at the top of each iteration.
# To resume loop N (without changing numbering), set `loop_count` to N-1 before continuing.
loop_count_pre_increment_for_resume() {
    local saved_loop_count="$1"

    if [[ "$saved_loop_count" =~ ^[0-9]+$ ]] && [[ "$saved_loop_count" -gt 0 ]]; then
        echo $((saved_loop_count - 1))
    else
        echo "0"
    fi
}

# Calculate wait time from rate limit error message
# Error format: "You've hit your limit · resets 11pm (America/New_York)"
# Also supports: "resets 11:30pm (America/New_York)" with optional minutes
# Returns: wait time in seconds (includes 5-minute buffer)
calculate_wait_time() {
    local error_msg="$1"
    local reset_time reset_tz current_epoch reset_epoch wait_seconds os_type

    # Extract reset time and timezone using extended regex
    # Supports: "resets 11pm", "resets 11:30pm", "resets 11:30 pm"
    # Note: Store regex in variable to avoid bash parsing issues with special characters
    local reset_regex='resets[[:space:]]([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*(am|pm)[[:space:]]*\(([^)]+)\)'
    if [[ "$error_msg" =~ $reset_regex ]]; then
        local hour="${BASH_REMATCH[1]}"
        local minute="${BASH_REMATCH[3]:-00}"
        local ampm="${BASH_REMATCH[4]}"
        local tz="${BASH_REMATCH[5]}"

        # Normalize parsed values
        tz="${tz//$'\r'/}"
        hour=$((10#$hour))
        minute=$((10#$minute))

        # Convert to 24-hour format
        if [[ "$ampm" == "pm" && "$hour" != "12" ]]; then
            hour=$((hour + 12))
        elif [[ "$ampm" == "am" && "$hour" == "12" ]]; then
            hour=0
        fi
        printf -v hour "%02d" "$hour"
        printf -v minute "%02d" "$minute"

        # Get current time in the specified timezone
        current_epoch=$(TZ="$tz" date +%s 2>/dev/null)

        # Calculate reset epoch (today at reset hour, or tomorrow if past)
        # Use a dated timestamp to avoid platform quirks with time-only parsing.
        local date_str=""
        date_str=$(TZ="$tz" date +%Y-%m-%d 2>/dev/null)
        if [[ -n "$date_str" ]]; then
            if reset_epoch=$(TZ="$tz" date -j -f "%Y-%m-%d %H:%M" "$date_str $hour:$minute" +%s 2>/dev/null); then
                :
            elif reset_epoch=$(TZ="$tz" date -d "$date_str $hour:$minute" +%s 2>/dev/null); then
                :
            elif command -v gdate >/dev/null 2>&1; then
                reset_epoch=$(TZ="$tz" gdate -d "$date_str $hour:$minute" +%s 2>/dev/null)
            fi
        fi

        # If reset time calculation failed, use fallback
        if [[ -z "$reset_epoch" ]]; then
            log_status "WARN" "Failed to calculate reset time, using 60-minute fallback" >&2
            echo "3600"
            return
        fi

        # If reset time is in the past, add 24 hours
        if [[ $reset_epoch -le $current_epoch ]]; then
            reset_epoch=$((reset_epoch + 86400))
        fi

        wait_seconds=$((reset_epoch - current_epoch))

        # Add 5-minute buffer for safety
        wait_seconds=$((wait_seconds + 300))

        log_status "INFO" "Calculated wait time: $((wait_seconds / 60)) minutes until reset" >&2
        echo "$wait_seconds"
    else
        # Fallback to 60 minutes if parsing fails
        log_status "WARN" "Could not parse reset time from error message, using 60-minute fallback" >&2
        echo "3600"
    fi
}

# Get fix plan counts: total, completed, deferred, in_progress, open
get_fix_plan_counts() {
    if [[ ! -f "$FIX_PLAN_FILE" ]]; then
        echo "0 0 0 0 0"
        return 0
    fi

    local total_items completed_items deferred_items in_progress_items open_items
    total_items=$({ grep -cE "^[[:space:]]*[-*][[:space:]]+\\[[^]]\\]" "$FIX_PLAN_FILE" 2>/dev/null || true; } | head -n1)
    completed_items=$({ grep -cE "^[[:space:]]*[-*][[:space:]]+\\[[xX]\\]" "$FIX_PLAN_FILE" 2>/dev/null || true; } | head -n1)
    deferred_items=$({ grep -cE "^[[:space:]]*[-*][[:space:]]+\\[[dD]\\]" "$FIX_PLAN_FILE" 2>/dev/null || true; } | head -n1)
    in_progress_items=$({ grep -cE "^[[:space:]]*[-*][[:space:]]+\\[~\\]" "$FIX_PLAN_FILE" 2>/dev/null || true; } | head -n1)
    open_items=$({ grep -cE "^[[:space:]]*[-*][[:space:]]+\\[[[:space:]]\\]" "$FIX_PLAN_FILE" 2>/dev/null || true; } | head -n1)

    [[ -z "$total_items" ]] && total_items=0
    [[ -z "$completed_items" ]] && completed_items=0
    [[ -z "$deferred_items" ]] && deferred_items=0
    [[ -z "$in_progress_items" ]] && in_progress_items=0
    [[ -z "$open_items" ]] && open_items=0

    echo "$total_items $completed_items $deferred_items $in_progress_items $open_items"
}

get_fix_plan_signature() {
    if [[ ! -f "$FIX_PLAN_FILE" ]]; then
        echo ""
        return 0
    fi

    local sig=""
    sig=$(cksum "$FIX_PLAN_FILE" 2>/dev/null | awk '{print $1 "-" $2}' || true)
    echo "$sig"
}

get_fix_plan_progress_signature() {
    local sig=""
    if [[ -f "$FIX_PLAN_PROGRESS_FILE" ]]; then
        sig=$(jq -r '.signature // ""' "$FIX_PLAN_PROGRESS_FILE" 2>/dev/null || echo "")
    fi
    echo "$sig"
}

fix_plan_changed_since_last() {
    local current_sig
    current_sig=$(get_fix_plan_signature)
    local prev_sig
    prev_sig=$(get_fix_plan_progress_signature)

    if [[ -z "$current_sig" || -z "$prev_sig" ]]; then
        echo "unknown"
        return 0
    fi

    if [[ "$current_sig" != "$prev_sig" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

update_fix_plan_progress_state() {
    local loop_number=$1
    local current_sig
    current_sig=$(get_fix_plan_signature)
    local prev_sig
    prev_sig=$(get_fix_plan_progress_signature)

    if [[ -z "$current_sig" ]]; then
        return 0
    fi

    local ts
    ts=$(get_iso_timestamp)
    local last_changed_loop
    last_changed_loop=$(jq -r '.last_changed_loop // 0' "$FIX_PLAN_PROGRESS_FILE" 2>/dev/null || echo "0")
    local last_changed_ts
    last_changed_ts=$(jq -r '.last_changed_ts // ""' "$FIX_PLAN_PROGRESS_FILE" 2>/dev/null || echo "")

    local changed="false"
    if [[ -z "$prev_sig" || "$current_sig" != "$prev_sig" ]]; then
        changed="true"
        last_changed_loop=$loop_number
        last_changed_ts=$ts
    fi

    jq -n \
        --arg signature "$current_sig" \
        --arg last_seen_ts "$ts" \
        --argjson last_seen_loop "$loop_number" \
        --arg last_changed_ts "$last_changed_ts" \
        --argjson last_changed_loop "$last_changed_loop" \
        '{
            signature: $signature,
            last_seen_ts: $last_seen_ts,
            last_seen_loop: $last_seen_loop,
            last_changed_ts: $last_changed_ts,
            last_changed_loop: $last_changed_loop
        }' > "$FIX_PLAN_PROGRESS_FILE" 2>/dev/null || true
}

# Review state helpers
get_review_state_count() {
    local count=0
    if [[ -f "$REVIEW_STATE_FILE" ]]; then
        count=$(jq -r '.review_count // 0' "$REVIEW_STATE_FILE" 2>/dev/null || echo "0")
    fi
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        count=0
    fi
    echo "$count"
}

review_marker_present() {
    local analysis_file=$1
    local summary=""
    summary=$(jq -r '.analysis.work_summary // .work_summary // ""' "$analysis_file" 2>/dev/null || echo "")
    if [[ -n "$summary" ]] && echo "$summary" | grep -qiE 'review[[:space:]]*[0-9]+|codex review|review verdict'; then
        return 0
    fi

    local output_file=""
    local stderr_file=""
    output_file=$(jq -r '.output_file // empty' "$analysis_file" 2>/dev/null || echo "")
    if [[ -n "$output_file" && -f "$output_file" ]]; then
        if grep -qiE 'REVIEW VERDICT|Codex Review|Review[[:space:]]*[0-9]+' "$output_file"; then
            return 0
        fi
    fi

    return 1
}

parse_review_verdict() {
    local output_file=$1
    local verdict=""
    if [[ -n "$output_file" && -f "$output_file" ]]; then
        verdict=$(grep -Eo 'REVIEW_VERDICT:[[:space:]]*[A-Za-z_]+' "$output_file" 2>/dev/null | tail -1 | awk -F':' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
    fi
    if [[ -z "$verdict" ]]; then
        verdict="unknown"
    fi
    echo "$verdict"
}

save_review_state() {
    local count=$1
    local verdict=$2
    local session_id=$3
    local output_uuid=${4:-}
    local ts
    ts=$(get_iso_timestamp)

    jq -n \
        --argjson review_count "$count" \
        --arg last_review_ts "$ts" \
        --arg last_verdict "$verdict" \
        --arg last_session_id "$session_id" \
        --arg last_output_uuid "$output_uuid" \
        '{
            review_count: $review_count,
            last_review_ts: $last_review_ts,
            last_verdict: $last_verdict,
            last_session_id: $last_session_id,
            last_output_uuid: $last_output_uuid
        }' > "$REVIEW_STATE_FILE" 2>/dev/null || true
}

update_review_state_from_analysis() {
    local analysis_file=$1
    if [[ ! -f "$analysis_file" ]]; then
        return 0
    fi

    local mcp_success_calls=0
    mcp_success_calls=$(jq -r '.analysis.mcp_success_calls // .mcp_success_calls // 0' "$analysis_file" 2>/dev/null || echo "0")
    if ! [[ "$mcp_success_calls" =~ ^[0-9]+$ ]]; then
        mcp_success_calls=0
    fi
    if [[ "$mcp_success_calls" -le 0 ]]; then
        if review_marker_present "$analysis_file"; then
            log_status "WARN" "Review claim detected without MCP usage; ignoring review state update" >&2
        fi
        return 0
    fi

    if [[ "$CODEX_REVIEW_ONLY" != "true" ]]; then
        if ! review_marker_present "$analysis_file"; then
            return 0
        fi
    fi

    local output_file=""
    output_file=$(jq -r '.output_file // empty' "$analysis_file" 2>/dev/null || echo "")
    local session_id=""
    local output_uuid=""
    if [[ -n "$output_file" && -f "$output_file" ]]; then
        session_id=$(jq -r '.session_id // .metadata.session_id // .sessionId // empty' "$output_file" 2>/dev/null || echo "")
        output_uuid=$(jq -r '.uuid // empty' "$output_file" 2>/dev/null || echo "")
        if [[ -z "$output_uuid" || "$output_uuid" == "null" ]]; then
            output_uuid="$output_file"
        fi
    fi

    local last_output_uuid=""
    if [[ -f "$REVIEW_STATE_FILE" ]]; then
        last_output_uuid=$(jq -r '.last_output_uuid // ""' "$REVIEW_STATE_FILE" 2>/dev/null || echo "")
    fi
    if [[ -n "$output_uuid" && "$output_uuid" == "$last_output_uuid" ]]; then
        return 0
    fi

    local current_count
    current_count=$(get_review_state_count)
    local new_count=$((current_count + 1))
    local verdict
    verdict=$(parse_review_verdict "$output_file")
    save_review_state "$new_count" "$verdict" "$session_id" "$output_uuid"
}

augment_mcp_usage_from_stderr() {
    local analysis_file=$1
    local stderr_file=$2
    if [[ ! -f "$analysis_file" || -z "$stderr_file" || ! -f "$stderr_file" ]]; then
        return 0
    fi

    local current_mcp_calls=0
    current_mcp_calls=$(jq -r '.analysis.mcp_calls // .mcp_calls // 0' "$analysis_file" 2>/dev/null || echo "0")
    if ! [[ "$current_mcp_calls" =~ ^[0-9]+$ ]]; then
        current_mcp_calls=0
    fi

    local inferred_mcp_calls=0
    inferred_mcp_calls=$(grep -oE 'mcp__codex__codex(-reply)?' "$stderr_file" 2>/dev/null | wc -l | tr -d ' ')
    if ! [[ "$inferred_mcp_calls" =~ ^[0-9]+$ ]]; then
        inferred_mcp_calls=0
    fi

    if [[ "$inferred_mcp_calls" -le 0 ]]; then
        # MCP debug logs commonly include raw JSON-RPC method names (tools/call).
        inferred_mcp_calls=$(grep -cE 'tools/call' "$stderr_file" 2>/dev/null | tr -d ' ' || echo "0")
        if ! [[ "$inferred_mcp_calls" =~ ^[0-9]+$ ]]; then
            inferred_mcp_calls=0
        fi
    fi

    local updated=""
    if [[ "$current_mcp_calls" -le 0 && "$inferred_mcp_calls" -gt 0 ]]; then
        updated=$(jq \
            --arg stderr_file "$stderr_file" \
            --argjson mcp_calls "$inferred_mcp_calls" \
            '.stderr_file = $stderr_file
            | .analysis.stderr_file = $stderr_file
            | .mcp_calls = $mcp_calls
            | .analysis.mcp_calls = $mcp_calls' \
            "$analysis_file" 2>/dev/null || echo "")
        if [[ -n "$updated" ]]; then
            echo "$updated" > "$analysis_file"
            log_status "INFO" "MCP usage detected via stderr (mcp_calls=$inferred_mcp_calls)" >&2
        fi
    else
        updated=$(jq \
            --arg stderr_file "$stderr_file" \
            '.stderr_file = $stderr_file
            | .analysis.stderr_file = $stderr_file' \
            "$analysis_file" 2>/dev/null || echo "")
        if [[ -n "$updated" ]]; then
            echo "$updated" > "$analysis_file"
        fi
    fi

    return 0
}

enforce_mcp_review_only() {
    local analysis_file=$1
    if [[ "$CODEX_REVIEW_ONLY" != "true" ]]; then
        return 0
    fi
    if [[ ! -f "$analysis_file" ]]; then
        return 0
    fi

    local mcp_success_calls=0
    local mcp_denied=0
    mcp_success_calls=$(jq -r '.analysis.mcp_success_calls // .mcp_success_calls // 0' "$analysis_file" 2>/dev/null || echo "0")
    mcp_denied=$(jq -r '.analysis.mcp_denied // .mcp_denied // 0' "$analysis_file" 2>/dev/null || echo "0")
    if ! [[ "$mcp_success_calls" =~ ^[0-9]+$ ]]; then
        mcp_success_calls=0
    fi
    if ! [[ "$mcp_denied" =~ ^[0-9]+$ ]]; then
        mcp_denied=0
    fi

    if [[ "$mcp_success_calls" -le 0 ]]; then
        if [[ "$mcp_denied" -gt 0 ]]; then
            log_status "ERROR" "Review-only mode failed: MCP call denied by permissions (mcp_denied=$mcp_denied)" >&2
        else
            log_status "ERROR" "Review-only mode failed: no successful Codex MCP calls detected (mcp_success_calls=0)" >&2
        fi
        return 4
    fi

    return 0
}

warn_review_count_mismatch() {
    local analysis_file=$1
    if [[ ! -f "$analysis_file" ]]; then
        return 0
    fi

    local output_file=""
    output_file=$(jq -r '.output_file // empty' "$analysis_file" 2>/dev/null || echo "")
    if [[ -z "$output_file" || ! -f "$output_file" ]]; then
        return 0
    fi

    local reported=""
    reported=$(grep -Eo 'REVIEW_COUNT:[[:space:]]*[0-9]+' "$output_file" 2>/dev/null | tail -1 | awk -F':' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
    if [[ -z "$reported" ]]; then
        return 0
    fi

    local state_count
    state_count=$(get_review_state_count)
    if [[ "$reported" != "$state_count" ]]; then
        log_status "WARN" "REVIEW_COUNT mismatch: reported=$reported, state=$state_count" >&2
    fi
}

warn_missing_codex_diff() {
    local analysis_file=$1
    if [[ ! -f "$analysis_file" ]]; then
        return 0
    fi

    local output_file=""
    output_file=$(jq -r '.output_file // empty' "$analysis_file" 2>/dev/null || echo "")
    if [[ -z "$output_file" || ! -f "$output_file" ]]; then
        return 0
    fi

    if ! grep -qi 'CODEX_PATCH_REQUESTED:[[:space:]]*true' "$output_file"; then
        return 0
    fi

    if grep -qi 'CODEX_DIFF_RECEIVED:[[:space:]]*true' "$output_file"; then
        return 0
    fi

    if grep -q '^diff --git' "$output_file" || grep -q '^--- a/' "$output_file" || grep -q '^+++ b/' "$output_file"; then
        return 0
    fi

    log_status "WARN" "Codex patch requested but no unified diff detected; continue without blocking or re-request diff." >&2
}

# Build system prompt block with remaining fix-plan items (rotating window)
build_fix_plan_focus_block() {
    if [[ ! -f "$FIX_PLAN_FILE" ]]; then
        log_status "INFO" "Focus fix plan enabled, but file not found: $FIX_PLAN_FILE" >&2
        echo ""
        return 0
    fi

    local total_items completed_items deferred_items in_progress_items open_items
    local IFS=$' \t\n'
    read -r total_items completed_items deferred_items in_progress_items open_items <<< "$(get_fix_plan_counts)"
    local total_remaining=$((open_items + in_progress_items))

    local remaining_items=()
    local line=""
    while IFS= read -r line; do
        remaining_items+=("$line")
    done < <(grep -E "^[[:space:]]*[-*][[:space:]]+\\[[[:space:]~]\\]" "$FIX_PLAN_FILE" 2>/dev/null || true)

    if [[ $total_remaining -eq 0 ]]; then
        log_status "INFO" "Focus fix plan enabled, but no unchecked items found" >&2
        echo ""
        return 0
    fi

    local plan_hash=""
    plan_hash=$(cksum "$FIX_PLAN_FILE" 2>/dev/null | awk '{print $1 "-" $2}')
    if [[ -z "$plan_hash" ]]; then
        plan_hash="unknown"
    fi

    local window_offset=0
    local stored_hash=""
    local stored_deferred=0
    if [[ -f "$FIX_PLAN_FOCUS_STATE_FILE" ]]; then
        window_offset=$(jq -r '.window_offset // 0' "$FIX_PLAN_FOCUS_STATE_FILE" 2>/dev/null || echo "0")
        stored_hash=$(jq -r '.plan_hash // ""' "$FIX_PLAN_FOCUS_STATE_FILE" 2>/dev/null || echo "")
        stored_deferred=$(jq -r '.deferred_count // 0' "$FIX_PLAN_FOCUS_STATE_FILE" 2>/dev/null || echo "0")
    fi

    if ! [[ "$window_offset" =~ ^[0-9]+$ ]]; then
        window_offset=0
    fi
    if ! [[ "$stored_deferred" =~ ^[0-9]+$ ]]; then
        stored_deferred=0
    fi
    if [[ "$stored_hash" != "$plan_hash" ]]; then
        window_offset=0
    fi
    if [[ $window_offset -ge $total_remaining ]]; then
        window_offset=0
    fi

    local max_items="$FIX_PLAN_FOCUS_MAX_ITEMS"
    if ! [[ "$max_items" =~ ^[0-9]+$ ]] || [[ "$max_items" -le 0 ]]; then
        max_items=12
    fi

    local max_chars="$FIX_PLAN_FOCUS_MAX_CHARS"
    if ! [[ "$max_chars" =~ ^[0-9]+$ ]] || [[ "$max_chars" -le 0 ]]; then
        max_chars=1200
    fi

    local selected_items=()
    local char_count=0
    local scanned=0

    while [[ $scanned -lt $total_remaining && ${#selected_items[@]} -lt $max_items ]]; do
        local idx=$(( (window_offset + scanned) % total_remaining ))
        local line="${remaining_items[$idx]}"
        local line_len=${#line}

        if [[ $char_count -gt 0 && $((char_count + line_len)) -gt $max_chars ]]; then
            break
        fi

        selected_items+=("$line")
        char_count=$((char_count + line_len))
        scanned=$((scanned + 1))
    done

    if [[ ${#selected_items[@]} -eq 0 ]]; then
        selected_items+=("${remaining_items[$window_offset]}")
    fi

    local selected_count=${#selected_items[@]}
    local next_offset=$(( (window_offset + selected_count) % total_remaining ))
    local ts
    ts=$(get_iso_timestamp)

    jq -n \
        --argjson window_offset "$next_offset" \
        --arg plan_hash "$plan_hash" \
        --argjson total_remaining "$total_remaining" \
        --argjson last_count "$selected_count" \
        --argjson deferred_count "$deferred_items" \
        --argjson open_count "$open_items" \
        --argjson in_progress_count "$in_progress_items" \
        --arg updated_at "$ts" \
        '{
            window_offset: $window_offset,
            plan_hash: $plan_hash,
            total_remaining: $total_remaining,
            last_count: $last_count,
            deferred_count: $deferred_count,
            open_count: $open_count,
            in_progress_count: $in_progress_count,
            updated_at: $updated_at
        }' > "$FIX_PLAN_FOCUS_STATE_FILE" 2>/dev/null || true

    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local summary_text=""
        summary_text=$(jq -r '.analysis.work_summary // .work_summary // ""' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "")
        if [[ -n "$summary_text" ]] && printf '%s' "$summary_text" | grep -qi "defer"; then
            if [[ "$deferred_items" -le "$stored_deferred" ]]; then
                log_status "WARN" "Deferral mentioned, but no new [d] items recorded in $FIX_PLAN_FILE" >&2
            fi
        fi
    fi

    local block="Remaining fix plan items (showing $selected_count of $total_remaining; rotating each loop)."
    block+=$'\n'"Only work on unchecked items below; do not redo completed items."
    block+=$'\n'"For each item listed, make a call this loop: either (1) take concrete action toward completion and update @fix_plan.md, or (2) mark it [d] with a reason and CP reference (e.g., [d] (defer to CP-017: visual emphasis))."
    block+=$'\n'"Do not claim COMPLETE until every remaining item is [x] or [d]."
    block+=$'\n'"Status counts: total=$total_items, done=$completed_items, deferred=$deferred_items, in_progress=$in_progress_items, open=$open_items."
    for line in "${selected_items[@]}"; do
        block+=$'\n'"$line"
    done

    echo "$block"
}

# Build an optional Codex context bundle from a file list.
# File list should contain one path per line (relative or absolute).
build_codex_context_block() {
    if [[ -z "$CODEX_CONTEXT_FILE" ]]; then
        echo ""
        return 0
    fi

    if [[ ! -f "$CODEX_CONTEXT_FILE" ]]; then
        log_status "WARN" "Codex context file not found: $CODEX_CONTEXT_FILE" >&2
        echo ""
        return 0
    fi

    local total_chars=0
    local files_added=0
    local block="Codex Context Bundle (auto-generated)\nUse these excerpts when preparing a Codex Patch Request.\n"

    while IFS= read -r path; do
        path=$(echo "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -z "$path" || "$path" =~ ^# ]]; then
            continue
        fi
        if [[ ! -f "$path" ]]; then
            continue
        fi

        local content
        content=$(sed -n "1,${CODEX_CONTEXT_MAX_LINES}p" "$path" | head -c "$CODEX_CONTEXT_MAX_CHARS")
        if [[ -z "$content" ]]; then
            continue
        fi

        local snippet="### $path\n$content\n"
        local snippet_len=${#snippet}
        if (( total_chars + snippet_len > CODEX_CONTEXT_TOTAL_MAX_CHARS )); then
            local remaining=$((CODEX_CONTEXT_TOTAL_MAX_CHARS - total_chars))
            if (( remaining <= 0 )); then
                break
            fi
            snippet=$(printf "%s" "$snippet" | head -c "$remaining")
            snippet_len=${#snippet}
        fi

        block+="$snippet\n"
        total_chars=$((total_chars + snippet_len))
        files_added=$((files_added + 1))

        if (( total_chars >= CODEX_CONTEXT_TOTAL_MAX_CHARS )); then
            break
        fi
    done < "$CODEX_CONTEXT_FILE"

    if (( files_added == 0 )); then
        echo ""
        return 0
    fi

    log_status "INFO" "Codex context bundle built ($files_added files, ${total_chars} chars)" >&2
    printf '%s\n' "$block"
}

# =============================================================================
# SESSION LIFECYCLE MANAGEMENT FUNCTIONS (Phase 1.2)
# =============================================================================

# Get current session ID from Ralph session file
# Returns: session ID string or empty if not found
get_session_id() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        echo ""
        return 0
    fi

    # Extract session_id from JSON file (SC2155: separate declare from assign)
    local session_id
    session_id=$(jq -r '.session_id // ""' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    # Handle jq failure or null/empty results
    if [[ $jq_status -ne 0 || -z "$session_id" || "$session_id" == "null" ]]; then
        session_id=""
    fi
    echo "$session_id"
    return 0
}

# Reset session with reason logging
# Usage: reset_session "reason_for_reset"
reset_session() {
    local reason=${1:-"manual_reset"}

    # Get current timestamp
    local reset_timestamp
    reset_timestamp=$(get_iso_timestamp)

    # Always create/overwrite the session file using jq for safe JSON escaping
    jq -n \
        --arg session_id "" \
        --arg created_at "" \
        --arg last_used "" \
        --arg reset_at "$reset_timestamp" \
        --arg reset_reason "$reason" \
        '{
            session_id: $session_id,
            created_at: $created_at,
            last_used: $last_used,
            reset_at: $reset_at,
            reset_reason: $reset_reason
        }' > "$RALPH_SESSION_FILE"

    # Also clear the Claude session file for consistency
    rm -f "$CLAUDE_SESSION_FILE" 2>/dev/null

    # Log the session transition (non-fatal to prevent script exit under set -e)
    log_session_transition "active" "reset" "$reason" "${loop_count:-0}" || true

    log_status "INFO" "Session reset: $reason"
}

# Log session state transitions to history file
# Usage: log_session_transition from_state to_state reason loop_number
log_session_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=${4:-0}

    # Get timestamp once (SC2155: separate declare from assign)
    local ts
    ts=$(get_iso_timestamp)

    # Create transition entry using jq for safe JSON (SC2155: separate declare from assign)
    local transition
    transition=$(jq -n -c \
        --arg timestamp "$ts" \
        --arg from_state "$from_state" \
        --arg to_state "$to_state" \
        --arg reason "$reason" \
        --argjson loop_number "$loop_number" \
        '{
            timestamp: $timestamp,
            from_state: $from_state,
            to_state: $to_state,
            reason: $reason,
            loop_number: $loop_number
        }')

    # Read history file defensively - fallback to empty array on any failure
    local history
    if [[ -f "$RALPH_SESSION_HISTORY_FILE" ]]; then
        history=$(cat "$RALPH_SESSION_HISTORY_FILE" 2>/dev/null)
        # Validate JSON, fallback to empty array if corrupted
        if ! echo "$history" | jq empty 2>/dev/null; then
            history='[]'
        fi
    else
        history='[]'
    fi

    # Append transition and keep only last 50 entries
    local updated_history
    updated_history=$(echo "$history" | jq ". += [$transition] | .[-50:]" 2>/dev/null)
    local jq_status=$?

    # Only write if jq succeeded
    if [[ $jq_status -eq 0 && -n "$updated_history" ]]; then
        echo "$updated_history" > "$RALPH_SESSION_HISTORY_FILE"
    else
        # Fallback: start fresh with just this transition
        echo "[$transition]" > "$RALPH_SESSION_HISTORY_FILE"
    fi
}

# Generate a unique session ID using timestamp and random component
generate_session_id() {
    local ts
    ts=$(date +%s)
    local rand
    rand=$RANDOM
    echo "ralph-${ts}-${rand}"
}

# Initialize session tracking (called at loop start)
init_session_tracking() {
    local ts
    ts=$(get_iso_timestamp)

    # Create session file if it doesn't exist
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "" \
            --arg reset_reason "" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"

        log_status "INFO" "Initialized session tracking (session: $new_session_id)"
        return 0
    fi

    # Validate existing session file
    if ! jq empty "$RALPH_SESSION_FILE" 2>/dev/null; then
        log_status "WARN" "Corrupted session file detected, recreating..."
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "$ts" \
            --arg reset_reason "corrupted_file_recovery" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"
    fi
}

# Update last_used timestamp in session file (called on each loop iteration)
update_session_last_used() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        return 0
    fi

    local ts
    ts=$(get_iso_timestamp)

    # Update last_used in existing session file
    local updated
    updated=$(jq --arg last_used "$ts" '.last_used = $last_used' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    if [[ $jq_status -eq 0 && -n "$updated" ]]; then
        echo "$updated" > "$RALPH_SESSION_FILE"
    fi
}

# Global array for Claude command arguments (avoids shell injection)
declare -a CLAUDE_CMD_ARGS=()

# Resolve absolute path for the configured STATE_DIR.
get_state_dir_abs() {
    local state_dir="${STATE_DIR:-.}"
    (cd "$state_dir" 2>/dev/null && pwd -P) || pwd -P
}

# Best-effort repo root (git top-level); falls back to state dir.
get_repo_root_abs() {
    local state_dir_abs=$1
    git -C "$state_dir_abs" rev-parse --show-toplevel 2>/dev/null || echo "$state_dir_abs"
}

# Derive CP number from state directory name, falling back to scanning PROMPT.md.
get_current_cp_number() {
    local state_dir_abs=$1
    local base
    base=$(basename "$state_dir_abs")
    if [[ "$base" =~ ^CP-[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$base"
        return 0
    fi

    local prompt_path="$state_dir_abs/$PROMPT_FILE"
    if [[ -f "$prompt_path" ]]; then
        local from_prompt=""
        from_prompt=$(grep -Eo 'CP-[0-9]+(\.[0-9]+)?' "$prompt_path" 2>/dev/null | head -1 || true)
        if [[ -n "$from_prompt" ]]; then
            echo "$from_prompt"
            return 0
        fi
    fi

    echo ""
    return 0
}

build_review_only_user_prompt() {
    local state_dir_abs
    state_dir_abs=$(get_state_dir_abs)
    local repo_root_abs
    repo_root_abs=$(get_repo_root_abs "$state_dir_abs")
    local cp_number
    cp_number=$(get_current_cp_number "$state_dir_abs")

    local fix_plan_path="$FIX_PLAN_FILE"
    if [[ "$fix_plan_path" != /* ]]; then
        fix_plan_path="$state_dir_abs/$fix_plan_path"
    fi

    local cp_docs=()
    if [[ -n "$cp_number" ]]; then
        while IFS= read -r f; do
            cp_docs+=("$f")
        done < <(ls -1 "$repo_root_abs/docs/change_proposals/${cp_number}-"*.md 2>/dev/null || true)
    fi

    local cp_docs_block="(none found)"
    if (( ${#cp_docs[@]} > 0 )); then
        cp_docs_block=""
        for f in "${cp_docs[@]}"; do
            cp_docs_block+=$'- '"$f"$'\n'
        done
    fi

    local task_json_path=""
    if [[ -n "$cp_number" ]]; then
        task_json_path="$repo_root_abs/docs/change_proposals/${cp_number}-task.json"
    fi

    cat << EOF
You are running Ralph in REVIEW-ONLY mode.

Hard requirements:
1) Make EXACTLY ONE tool call total: \`mcp__codex__codex\`.
2) Tool input must include:
   - \`prompt\`: the delegation prompt below
   - \`cwd\`: \`$repo_root_abs\`
   - \`sandbox\`: \`read-only\`
3) Do NOT call \`mcp__codex__codex-reply\` or any other tools.
4) After the tool returns, output ONLY:
   - A short "Codex Review" section containing the returned \`content\` text
   - A \`---RALPH_STATUS---\` block with \`EXIT_SIGNAL: true\`
5) If the tool call errors or times out, output exactly: \`FAIL: MCP_REQUIRED\` (and nothing else).

Delegation prompt to Codex (advisory / read-only):

## 1. TASK
Perform a final advisory code review for ${cp_number:-this CP} in \`bob_party\`, focused on whether the work is actually complete for human review.

## 2. EXPECTED OUTCOME
1) A ranked list of issues (if any) with concrete evidence (file paths).
2) A clear verdict: PASS / NEEDS_FIXES / BLOCKED.

## 3. CONTEXT
- Repo root: \`$repo_root_abs\`
- Ralph state dir: \`$state_dir_abs\`
- Fix plan file: \`$fix_plan_path\`
- CP doc candidates:
$cp_docs_block
- Task JSON (expected): \`$task_json_path\`

## 4. CONSTRAINTS
- Advisory only: do not modify files.
- Do not run tests/commands in this review-only delegation.
- Treat \`[x]\` and \`[d]\` as complete for loop exit gating.

## 5. MUST DO
- Read the fix plan and summarize totals for \`[x]\`/\`[d]\`/\`[~]\`/\`[ ]\`.
- Verify whether \`apps/sidecar-extension/src/overlay.tsx\` exists.
- Check CP doc + task JSON exist (report missing if not).

## 6. MUST NOT DO
- Do not claim tests passed unless you actually ran them.

## 7. OUTPUT FORMAT
- Summary (2-4 sentences)
- Issues (bullets; include file paths)
- Verdict: PASS / NEEDS_FIXES / BLOCKED
EOF
}

# Build Claude CLI command with modern flags using array (shell-injection safe)
# Populates global CLAUDE_CMD_ARGS array for direct execution
# Uses -p flag with prompt content (Claude CLI does not have --prompt-file)
build_claude_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local focus_block=""
    local codex_context_block=""
    local review_gate_block=""

    # Reset global array
    CLAUDE_CMD_ARGS=("$CLAUDE_CODE_CMD")

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        log_status "ERROR" "Prompt file not found: $prompt_file"
        return 1
    fi

    # Add output format flag
    # In review-only mode we need `stream-json` to reliably observe tool_use events.
    if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then
        local cli_output_format="json"
        if [[ "$CODEX_REVIEW_ONLY" == "true" ]]; then
            cli_output_format="stream-json"
        fi
        CLAUDE_CMD_ARGS+=("--output-format" "$cli_output_format")
        # Review-only runs should be fully deterministic and observable:
        # - `--include-partial-messages` is required for tool_use events in stream-json output.
        # - `--no-session-persistence` avoids anchoring on prior sessions and prevents writes.
        # - Claude requires `--verbose` with `--print` + `--output-format=stream-json`.
        if [[ "$CODEX_REVIEW_ONLY" == "true" ]]; then
            CLAUDE_CMD_ARGS+=("--include-partial-messages")
            CLAUDE_CMD_ARGS+=("--no-session-persistence")
            CLAUDE_CMD_ARGS+=("--verbose")
        fi
    fi

    # Add MCP server configuration if specified
    if [[ -n "$CLAUDE_MCP_CONFIG" ]]; then
        if [[ -f "$CLAUDE_MCP_CONFIG" ]]; then
            CLAUDE_CMD_ARGS+=("--mcp-config" "$CLAUDE_MCP_CONFIG")
            log_status "INFO" "MCP config loaded: $CLAUDE_MCP_CONFIG"
        else
            log_status "WARN" "MCP config file not found: $CLAUDE_MCP_CONFIG"
        fi
    fi
    if [[ "$CODEX_REVIEW_ONLY" == "true" && -n "$CLAUDE_MCP_CONFIG" && -f "$CLAUDE_MCP_CONFIG" ]]; then
        CLAUDE_CMD_ARGS+=("--strict-mcp-config")
        CLAUDE_CMD_ARGS+=("--debug" "mcp")
    fi

    # Add allowed tools (each tool as separate array element)
    local effective_tools="$CLAUDE_ALLOWED_TOOLS"
    if [[ "$CODEX_REVIEW_ONLY" == "true" ]]; then
        # MCP tools are namespaced as mcp__<server>__<tool>
        # Codex MCP server exposes `codex` and `codex-reply`, but review-only should be single-call.
        effective_tools="mcp__codex__codex"
    fi
    if [[ -n "$effective_tools" ]]; then
        CLAUDE_CMD_ARGS+=("--allowedTools")
        # Split by comma and add each tool
        local IFS=','
        read -ra tools_array <<< "$effective_tools"
        for tool in "${tools_array[@]}"; do
            # Trim whitespace
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                CLAUDE_CMD_ARGS+=("$tool")
            fi
        done
    fi
    if [[ -n "$CLAUDE_PERMISSION_MODE" ]]; then
        CLAUDE_CMD_ARGS+=("--permission-mode" "$CLAUDE_PERMISSION_MODE")
    fi

    # Add session continuity flag
    # Review-only runs must start fresh (avoid anchoring on prior "COMPLETE" sessions).
    if [[ "$CLAUDE_USE_CONTINUE" == "true" && "$CODEX_REVIEW_ONLY" != "true" ]]; then
        CLAUDE_CMD_ARGS+=("--continue")
    fi

    if [[ "$FOCUS_FIX_PLAN" == "true" ]]; then
        focus_block=$(build_fix_plan_focus_block)
        if [[ -n "$focus_block" ]]; then
            local focus_lines=0
            focus_lines=$(printf '%s\n' "$focus_block" | wc -l | tr -d ' ')
            log_status "INFO" "Focus fix plan block injected ($focus_lines lines, ${#focus_block} chars)" >&2
        else
            log_status "INFO" "Focus fix plan block empty" >&2
        fi
    fi
    if [[ -n "$CODEX_CONTEXT_FILE" ]]; then
        codex_context_block=$(build_codex_context_block)
        if [[ -n "$codex_context_block" ]]; then
            log_status "INFO" "Codex context block injected (${#codex_context_block} chars)" >&2
        fi
    fi

    # Add system prompts (no escaping needed - array handles it)
    if [[ -n "$loop_context" ]]; then
        CLAUDE_CMD_ARGS+=("--append-system-prompt" "$loop_context")
    fi
    local review_count_block="Authoritative review_count: $(get_review_state_count). Use this value in RALPH_STATUS. Do not claim PASS or increment REVIEW_COUNT without a Codex MCP review."
    CLAUDE_CMD_ARGS+=("--append-system-prompt" "$review_count_block")
    if [[ -f "$FIX_PLAN_FILE" ]]; then
        local IFS=$' \t\n'
        local total_items completed_items deferred_items in_progress_items open_items
        read -r total_items completed_items deferred_items in_progress_items open_items <<< "$(get_fix_plan_counts)"
        if [[ $total_items -gt 0 && $((completed_items + deferred_items)) -eq $total_items ]]; then
            if [[ "$(get_review_state_count)" == "0" ]]; then
                review_gate_block="Codex review required now. Call mcp__codex__codex for Review 1. Do not claim COMPLETE or PASS without a Codex MCP review."
            fi
        fi
    fi
    if [[ -n "$review_gate_block" ]]; then
        CLAUDE_CMD_ARGS+=("--append-system-prompt" "$review_gate_block")
    fi
    if [[ -n "$focus_block" ]]; then
        CLAUDE_CMD_ARGS+=("--append-system-prompt" "$focus_block")
    fi
    if [[ -n "$codex_context_block" ]]; then
        CLAUDE_CMD_ARGS+=("--append-system-prompt" "$codex_context_block")
    fi

    # Read prompt file content and use -p flag
    # Note: Claude CLI uses -p for prompts, not --prompt-file (which doesn't exist)
    # Array-based approach maintains shell injection safety
    local prompt_content
    if [[ "$CODEX_REVIEW_ONLY" == "true" ]]; then
        prompt_content=$(build_review_only_user_prompt)
    else
        prompt_content=$(cat "$prompt_file")
    fi
    CLAUDE_CMD_ARGS+=("-p" "$prompt_content")
}

# Main execution function
execute_claude_code() {
    local loop_count=$1
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    local timeout_seconds=$((CLAUDE_TIMEOUT_MINUTES * 60))
    local extra_prompt=""
    local strict_retry_prompt="Review-only enforcement: first action must be mcp__codex__codex. If you cannot, respond exactly 'FAIL: MCP_REQUIRED' and stop."
    local output_file=""

    # Build loop context for session continuity
    local loop_context=""
    if [[ "$CLAUDE_USE_CONTINUE" == "true" && "$CODEX_REVIEW_ONLY" != "true" ]]; then
        loop_context=$(build_loop_context "$loop_count")
        if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
            log_status "INFO" "Loop context: $loop_context"
        fi
    fi

    # Initialize or resume session
    local session_id=""
    if [[ "$CLAUDE_USE_CONTINUE" == "true" && "$CODEX_REVIEW_ONLY" != "true" ]]; then
        session_id=$(init_claude_session)
    fi

    # In review-only mode, enforce the MCP call from the first attempt (no retries/anchoring).
    if [[ "$CODEX_REVIEW_ONLY" == "true" ]]; then
        extra_prompt="$strict_retry_prompt"
        REVIEW_ONLY_RETRY_DONE="true"
    fi

    local attempt=0
    local analysis_exit_code=0
    while true; do
        attempt=$((attempt + 1))
        calls_made=$((calls_made + 1))

        local timestamp
        timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
        local attempt_suffix=""
        if [[ $attempt -gt 1 ]]; then
            attempt_suffix="_retry${attempt}"
        fi
        output_file="$LOG_DIR/claude_output_${timestamp}${attempt_suffix}.log"
        stderr_file="$LOG_DIR/claude_output_${timestamp}${attempt_suffix}.stderr.log"

        log_status "LOOP" "Executing Claude Code (Call $calls_made/$MAX_CALLS_PER_HOUR)"
        log_status "INFO" "⏳ Starting Claude Code execution... (timeout: ${CLAUDE_TIMEOUT_MINUTES}m)"

        # Build the Claude CLI command with modern flags
        # Note: We use the modern CLI with -p flag when CLAUDE_OUTPUT_FORMAT is "json"
        # For backward compatibility, fall back to stdin piping for text mode
        local use_modern_cli=false

        if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then
            # Modern approach: use CLI flags (builds CLAUDE_CMD_ARGS array)
            if build_claude_command "$PROMPT_FILE" "$loop_context" "$session_id"; then
                use_modern_cli=true
                if [[ -n "$extra_prompt" ]]; then
                    CLAUDE_CMD_ARGS+=("--append-system-prompt" "$extra_prompt")
                fi
                log_status "INFO" "Using modern CLI mode"
            else
                log_status "WARN" "Failed to build modern CLI command, falling back to legacy mode"
            fi
        else
            log_status "INFO" "Using legacy CLI mode (text output)"
        fi

        # Execute Claude Code
        if [[ "$use_modern_cli" == "true" ]]; then
            # Modern execution with command array (shell-injection safe)
            # Execute array directly without bash -c to prevent shell metacharacter interpretation
            if timeout ${timeout_seconds}s "${CLAUDE_CMD_ARGS[@]}" > "$output_file" 2> "$stderr_file" &
            then
                :  # Continue to wait loop
            else
                log_status "ERROR" "❌ Failed to start Claude Code process (modern mode)"
                # Fall back to legacy mode
                log_status "INFO" "Falling back to legacy mode..."
                use_modern_cli=false
            fi
        fi

        # Fall back to legacy stdin piping if modern mode failed or not enabled
        if [[ "$use_modern_cli" == "false" ]]; then
            if timeout ${timeout_seconds}s $CLAUDE_CODE_CMD < "$PROMPT_FILE" > "$output_file" 2> "$stderr_file" &
            then
                :  # Continue to wait loop
            else
                log_status "ERROR" "❌ Failed to start Claude Code process"
                return 1
            fi
        fi

        # Get PID and monitor progress
        local claude_pid=$!
        local progress_counter=0

        # Show progress while Claude Code is running
        while kill -0 $claude_pid 2>/dev/null; do
            progress_counter=$((progress_counter + 1))
            case $((progress_counter % 4)) in
                1) progress_indicator="⠋" ;;
                2) progress_indicator="⠙" ;;
                3) progress_indicator="⠹" ;;
                0) progress_indicator="⠸" ;;
            esac

            # Get last line from output if available
            local last_line=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
            fi

            # Update progress file for monitor
            cat > "$PROGRESS_FILE" << EOF
{
    "status": "executing",
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

            # Only log if verbose mode is enabled
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                if [[ -n "$last_line" ]]; then
                    log_status "INFO" "$progress_indicator Claude Code: $last_line... (${progress_counter}0s)"
                else
                    log_status "INFO" "$progress_indicator Claude Code working... (${progress_counter}0s elapsed)"
                fi
            fi

            sleep 10
        done

        # Wait for the process to finish and get exit code
        wait $claude_pid
        local exit_code=$?

        # CP-016.26: Check for errors embedded in JSON response, even with non-zero exit codes
        # Rate limit errors can come as {"is_error": true, "result": "You've hit your limit..."}
        local rate_limit_detected="false"
        local json_error_file="$output_file"
        if ! jq empty "$json_error_file" >/dev/null 2>&1; then
            if [[ -s "$stderr_file" ]] && jq empty "$stderr_file" >/dev/null 2>&1; then
                json_error_file="$stderr_file"
            fi
        fi
        if jq -e '.is_error == true' "$json_error_file" >/dev/null 2>&1; then
            local error_msg
            error_msg=$(jq -r '.result // "Unknown error"' "$json_error_file" 2>/dev/null)
            if [[ "$error_msg" == *"limit"* ]] || [[ "$error_msg" == *"resets"* ]]; then
                log_status "ERROR" "API rate limit detected in JSON response: $error_msg"
                # Store error message for wait time calculation
                echo "$error_msg" > "$STATE_DIR/.rate_limit_error"
                rate_limit_detected="true"
                exit_code=2  # Treat as rate limit error
            else
                log_status "ERROR" "Claude returned error: $error_msg"
                if [ $exit_code -eq 0 ]; then
                    exit_code=1
                fi
            fi
        fi

        if [ $exit_code -ne 0 ]; then
            # Clear progress file on failure
            echo '{"status": "failed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

            # Check if the failure is due to API 5-hour limit
            if [[ "$rate_limit_detected" == "true" ]] || grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached" "$output_file" "$stderr_file" 2>/dev/null; then
                log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
                return 2  # Special return code for API limit
            fi

            if [[ -s "$stderr_file" ]]; then
                log_status "ERROR" "❌ Claude Code execution failed, check: $output_file (stderr: $stderr_file)"
            else
                log_status "ERROR" "❌ Claude Code execution failed, check: $output_file"
            fi
            return 1
        fi

        # Only increment counter on successful execution
        echo "$calls_made" > "$CALL_COUNT_FILE"

        # Clear progress file
        echo '{"status": "completed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        log_status "SUCCESS" "✅ Claude Code execution completed successfully"

        # Save session ID from JSON output (Phase 1.1)
        if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
            save_claude_session "$output_file"
        fi

        # Analyze the response
        log_status "INFO" "🔍 Analyzing Claude Code response..."
        analyze_response "$output_file" "$loop_count" "$RESPONSE_ANALYSIS_FILE"
        analysis_exit_code=$?
        augment_mcp_usage_from_stderr "$RESPONSE_ANALYSIS_FILE" "$stderr_file"

        if [[ "$CODEX_REVIEW_ONLY" == "true" ]]; then
            REVIEW_ONLY_RETRY_DONE="true"
        fi
        break
    done

        # Update exit signals based on analysis
        update_exit_signals "$RESPONSE_ANALYSIS_FILE" "$EXIT_SIGNALS_FILE"

        # Update review state based on MCP review signals
        update_review_state_from_analysis "$RESPONSE_ANALYSIS_FILE"
        warn_review_count_mismatch "$RESPONSE_ANALYSIS_FILE"
        warn_missing_codex_diff "$RESPONSE_ANALYSIS_FILE"

        # Log analysis summary
        log_analysis_summary "$RESPONSE_ANALYSIS_FILE"

        # Warn when Claude claims completion without fix-plan progress
        if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
            local analysis_exit_signal="false"
            analysis_exit_signal=$(jq -r '.analysis.exit_signal // .exit_signal // "false"' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
            if [[ "$analysis_exit_signal" == "true" ]]; then
                local total_items completed_items deferred_items in_progress_items open_items
                local IFS=$' \t\n'
                read -r total_items completed_items deferred_items in_progress_items open_items <<< "$(get_fix_plan_counts)"
                if [[ "$open_items" -gt 0 ]]; then
                    local fix_plan_changed
                    fix_plan_changed=$(fix_plan_changed_since_last)
                    if [[ "$fix_plan_changed" == "false" ]]; then
                        log_status "WARN" "Completion claimed but no fix_plan progress since last loop (open=$open_items)" >&2
                    fi
                fi
            fi
        fi

        # Record fix plan progress signature for next loop comparison
        update_fix_plan_progress_state "$loop_count"

        # Enforce Codex MCP usage in review-only mode
        if ! enforce_mcp_review_only "$RESPONSE_ANALYSIS_FILE"; then
            return 4
        fi

        # Get file change count for circuit breaker
        local files_changed=$(git diff --name-only 2>/dev/null | wc -l || echo 0)
        local has_errors="false"

        # Two-stage error detection to avoid JSON field false positives
        # Stage 1: Filter out JSON field patterns like "is_error": false
        # Stage 2: Look for actual error messages in specific contexts
        # Avoid type annotations like "error: Error" by requiring lowercase after ": error"
        if cat "$output_file" "$stderr_file" 2>/dev/null | \
           grep -v '"[^"]*error[^"]*":' 2>/dev/null | \
           grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
            has_errors="true"

            # Debug logging: show what triggered error detection
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                log_status "DEBUG" "Error patterns found:"
                cat "$output_file" "$stderr_file" 2>/dev/null | \
                    grep -v '"[^"]*error[^"]*":' 2>/dev/null | \
                    grep -nE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' | \
                    head -3 | while IFS= read -r line; do
                    log_status "DEBUG" "  $line"
                done
            fi

            log_status "WARN" "Errors detected in output, check: $output_file"
        fi
        local output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

        # Record result in circuit breaker
        record_loop_result "$loop_count" "$files_changed" "$has_errors" "$output_length"
        local circuit_result=$?

        if [[ $circuit_result -ne 0 ]]; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3  # Special code for circuit breaker trip
        fi

        return 0
}

# CP-016.26: Global flag to track if signal handler already processed cleanup
# This prevents EXIT trap from overwriting status set by SIGINT/SIGTERM handlers
SIGNAL_CLEANUP_DONE=false

# CP-016.26: Enhanced cleanup function with graceful exit preservation
# Handles EXIT signal - runs after other handlers exit
cleanup_on_exit() {
    local exit_code=$?

    # Only manage status/session when running the main loop (paths initialized).
    if [[ "$STATE_PATHS_READY" != "true" ]]; then
        return
    fi

    # CP-016.26: If SIGINT/SIGTERM handler already ran, don't overwrite status
    if [[ "$SIGNAL_CLEANUP_DONE" == "true" ]]; then
        log_status "INFO" "Cleanup already done by signal handler, skipping EXIT trap"
        return
    fi

    # Check if we already have a graceful exit - don't overwrite
    local last_action=""
    local current_status=""
    if [[ -f "$STATUS_FILE" ]]; then
        last_action=$(jq -r '.last_action // ""' "$STATUS_FILE" 2>/dev/null || echo "")
        current_status=$(jq -r '.status // ""' "$STATUS_FILE" 2>/dev/null || echo "")
    fi

    # Don't overwrite graceful_exit status (project completed successfully)
    if [[ "$last_action" == "graceful_exit" ]]; then
        log_status "INFO" "Preserving graceful_exit status"
        return
    fi

    # CP-016.26: Don't overwrite interrupted/stopped/paused status
    # These were set intentionally by signal handlers or rate limit handling
    if [[ "$current_status" == "stopped" || "$current_status" == "paused" || "$current_status" == "halted" || "$current_status" == "failed" ]]; then
        log_status "INFO" "Preserving existing status: $current_status"
        return
    fi

    # Determine reason based on exit code and context
    local reason="interrupted"
    local status="stopped"

    if [[ $exit_code -eq 2 ]]; then
        reason="api_5hour_limit"
        status="paused"
    elif [[ $exit_code -eq 0 ]]; then
        reason="completed"
        status="completed"
    elif [[ $exit_code -eq 3 ]]; then
        reason="circuit_breaker_trip"
        status="halted"
    elif [[ $exit_code -eq 4 ]]; then
        reason="review_only_no_mcp"
        status="failed"
    fi

    log_status "INFO" "Ralph terminating (exit_code=$exit_code, reason=$reason)"
    update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo 0)" \
        "interrupted" "$status" "$reason"

    # Reset session for non-graceful terminations
    if [[ "$reason" != "completed" ]]; then
        reset_session "manual_interrupt"
    fi
}

# SIGINT/SIGTERM handler - sets status before exit triggers EXIT trap
cleanup() {
    if [[ "$STATE_PATHS_READY" != "true" ]]; then
        exit 0
    fi

    log_status "INFO" "Ralph loop interrupted by signal. Cleaning up..."

    # Mark that signal handler is doing cleanup
    SIGNAL_CLEANUP_DONE=true

    # Check if we already have a graceful exit
    local last_action=""
    if [[ -f "$STATUS_FILE" ]]; then
        last_action=$(jq -r '.last_action // ""' "$STATUS_FILE" 2>/dev/null || echo "")
    fi

    if [[ "$last_action" != "graceful_exit" ]]; then
        reset_session "manual_interrupt"
        update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "interrupted" "stopped" "signal_interrupt"
    fi
    exit 0
}

# Set up signal handlers
# EXIT trap uses cleanup_on_exit for comprehensive handling
# SIGINT/SIGTERM use cleanup for immediate response
trap cleanup_on_exit EXIT
trap cleanup SIGINT SIGTERM

# Global variable for loop count (needed by cleanup function)
loop_count=0

# Main loop
main() {
    
    log_status "SUCCESS" "🚀 Ralph loop starting with Claude Code"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Logs: $LOG_DIR/ | Docs: $DOCS_DIR/ | Status: $STATUS_FILE"
    local main_exit_code=0
    
    # Check if this is a Ralph project directory
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        
        # Check if this looks like a partial Ralph project
        if [[ -f "$FIX_PLAN_FILE" ]] || [[ -d "specs" ]] || [[ -f "@AGENT.md" ]]; then
            echo "This appears to be a Ralph project but is missing PROMPT.md."
            echo "You may need to create or restore the PROMPT.md file."
        else
            echo "This directory is not a Ralph project."
        fi
        
        echo ""
        echo "To fix this:"
        echo "  1. Create a new project: ralph-setup my-project"
        echo "  2. Import existing requirements: ralph-import requirements.md"
        echo "  3. Navigate to an existing Ralph project directory"
        echo "  4. Or create PROMPT.md manually in this directory"
        echo ""
        echo "Ralph projects should contain: PROMPT.md, @fix_plan.md, specs/, src/, etc."
        exit 1
    fi

    # Initialize session tracking before entering the loop
    init_session_tracking

    # CP-016.26: Check for rate_limit_loop recovery state
    if [[ -f "$STATE_DIR/.rate_limit_loop" ]]; then
        log_status "INFO" "Detected rate limit recovery state file..."
        local rate_limit_state
        rate_limit_state=$(cat "$STATE_DIR/.rate_limit_loop" 2>/dev/null || echo "{}")
        local wait_until
        wait_until=$(echo "$rate_limit_state" | jq -r '.wait_until // 0' 2>/dev/null || echo "0")
        local saved_loop_count
        saved_loop_count=$(echo "$rate_limit_state" | jq -r '.loop_count // 0' 2>/dev/null || echo "0")
        local current_time
        current_time=$(date +%s)

        if [[ "$wait_until" -gt "$current_time" ]]; then
            local remaining_wait=$((wait_until - current_time))
            local remaining_minutes=$((remaining_wait / 60))

            if [[ "$AUTONOMOUS_MODE" == "true" ]]; then
                log_status "INFO" "[AUTONOMOUS] Resuming rate limit wait: $remaining_minutes minutes remaining..."
                loop_count=$(loop_count_pre_increment_for_resume "$saved_loop_count")  # Resume at saved loop number

                # Continue countdown
                while [[ $remaining_wait -gt 0 ]]; do
                    local hours=$((remaining_wait / 3600))
                    local minutes=$(((remaining_wait % 3600) / 60))
                    local seconds=$((remaining_wait % 60))
                    printf "\r${YELLOW}[AUTONOMOUS] Time until retry: %02d:%02d:%02d${NC}" $hours $minutes $seconds
                    sleep 1
                    ((remaining_wait--))
                done
                printf "\n"

                log_status "SUCCESS" "[AUTONOMOUS] Rate limit wait complete (recovered), starting loop..."
            else
                # Interactive mode - ask user
                echo -e "\n${YELLOW}Ralph was previously waiting for rate limit reset.${NC}"
                echo -e "Wait time remaining: $remaining_minutes minutes"
                echo -e "\n${BLUE}Do you want to:${NC}"
                echo -e "  ${GREEN}1)${NC} Continue waiting"
                echo -e "  ${GREEN}2)${NC} Start fresh (skip wait)"
                echo -e "\n${BLUE}Choose an option (1 or 2):${NC} "

                read -t 30 -n 1 recovery_choice
                echo

                if [[ "$recovery_choice" == "1" ]]; then
                    log_status "INFO" "User chose to continue waiting..."
                    loop_count=$(loop_count_pre_increment_for_resume "$saved_loop_count")  # Resume at saved loop number

                    while [[ $remaining_wait -gt 0 ]]; do
                        local minutes=$((remaining_wait / 60))
                        local seconds=$((remaining_wait % 60))
                        printf "\r${YELLOW}Time until retry: %02d:%02d${NC}" $minutes $seconds
                        sleep 1
                        ((remaining_wait--))
                    done
                    printf "\n"

                    log_status "SUCCESS" "Rate limit wait complete (recovered), starting loop..."
                else
                    log_status "INFO" "User chose to start fresh, skipping remaining wait..."
                fi
            fi
        else
            log_status "INFO" "Rate limit wait period has passed, cleaning up recovery state..."
            loop_count=$(loop_count_pre_increment_for_resume "$saved_loop_count")  # Resume at saved loop number
        fi

        # Clean up recovery state file
        rm -f "$STATE_DIR/.rate_limit_loop"
        rm -f "$STATE_DIR/.rate_limit_error"
    fi

    log_status "INFO" "Starting main loop..."
    log_status "INFO" "DEBUG: About to enter while loop, loop_count=$loop_count"
    
    while true; do
        loop_count=$((loop_count + 1))
        log_status "INFO" "DEBUG: Successfully incremented loop_count to $loop_count"

        # Update session last_used timestamp
        update_session_last_used

        log_status "INFO" "Loop #$loop_count - calling init_call_tracking..."
        init_call_tracking
        
        log_status "LOOP" "=== Starting Loop #$loop_count ==="
        
        # Check circuit breaker before attempting execution
        if should_halt_execution; then
            reset_session "circuit_breaker_open"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - execution halted"
            break
        fi

        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi

        # Check for graceful exit conditions
        local exit_reason=$(should_exit_gracefully)
        if [[ "$exit_reason" != "" ]]; then
            log_status "SUCCESS" "🏁 Graceful exit triggered: $exit_reason"
            reset_session "project_complete"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "graceful_exit" "completed" "$exit_reason"

            log_status "SUCCESS" "🎉 Ralph has completed the project! Final stats:"
            log_status "INFO" "  - Total loops: $loop_count"
            log_status "INFO" "  - API calls used: $(cat "$CALL_COUNT_FILE")"
            log_status "INFO" "  - Exit reason: $exit_reason"

            break
        fi
        
        # Update status
        local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        update_status "$loop_count" "$calls_made" "executing" "running"
        
        # Execute Claude Code (guard against set -e on non-zero exit)
        local exec_result=0
        if execute_claude_code "$loop_count"; then
            exec_result=0
        else
            exec_result=$?
        fi
        
        if [ $exec_result -eq 0 ]; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "completed" "success"

            # Brief pause between successful executions
            sleep 5
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened
            reset_session "circuit_breaker_trip"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - halting loop"
            log_status "INFO" "Run 'ralph --reset-circuit' to reset the circuit breaker after addressing issues"
            break
        elif [ $exec_result -eq 4 ]; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "mcp_required" "failed" "review_only_no_mcp"
            log_status "ERROR" "🛑 Review-only run failed: no successful Codex MCP usage detected"
            main_exit_code=4
            break
        elif [ $exec_result -eq 2 ]; then
            # API 5-hour limit reached - handle specially
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit" "paused" "rate_limited"
            log_status "WARN" "🛑 Claude API 5-hour limit reached!"

            # CP-016.26: Autonomous mode - auto-wait without user interaction
            if [[ "$AUTONOMOUS_MODE" == "true" ]]; then
                log_status "INFO" "[AUTONOMOUS] Auto-wait enabled - calculating optimal wait time..."

                # Read error message from state file if available
                local error_msg=""
                if [[ -f "$STATE_DIR/.rate_limit_error" ]]; then
                    error_msg=$(cat "$STATE_DIR/.rate_limit_error" 2>/dev/null || echo "")
                fi

                # Calculate wait time from error message
                local wait_seconds
                wait_seconds=$(calculate_wait_time "$error_msg")
                local wait_minutes=$((wait_seconds / 60))

                log_status "INFO" "[AUTONOMOUS] Waiting $wait_minutes minutes ($wait_seconds seconds) until rate limit reset..."

                # Save state for potential crash recovery
                echo "{\"mode\":\"rate_limit_wait\",\"wait_until\":$(($(date +%s) + wait_seconds)),\"loop_count\":$loop_count}" > "$STATE_DIR/.rate_limit_loop"

                # Countdown display (no user interaction)
                while [[ $wait_seconds -gt 0 ]]; do
                    local hours=$((wait_seconds / 3600))
                    local minutes=$(((wait_seconds % 3600) / 60))
                    local seconds=$((wait_seconds % 60))
                    printf "\r${YELLOW}[AUTONOMOUS] Time until retry: %02d:%02d:%02d${NC}" $hours $minutes $seconds
                    sleep 1
                    ((wait_seconds--))
                done
                printf "\n"

                # Clean up state file
                rm -f "$STATE_DIR/.rate_limit_loop"
                rm -f "$STATE_DIR/.rate_limit_error"

                log_status "SUCCESS" "[AUTONOMOUS] Rate limit wait complete, resuming loop..."
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "executing" "running" "resumed_after_rate_limit"

                # Resume at the same loop number (do not advance numbering after a rate-limit pause)
                loop_count=$(loop_count_pre_increment_for_resume "$loop_count")
                continue
            else
                # Interactive mode - ask user whether to wait or exit
                echo -e "\n${YELLOW}The Claude API 5-hour usage limit has been reached.${NC}"
                echo -e "${YELLOW}You can either:${NC}"
                echo -e "  ${GREEN}1)${NC} Wait for the limit to reset (usually within an hour)"
                echo -e "  ${GREEN}2)${NC} Exit the loop and try again later"
                echo -e "\n${BLUE}Choose an option (1 or 2):${NC} "

                # Read user input with timeout
                read -t 30 -n 1 user_choice
                echo  # New line after input

                if [[ "$user_choice" == "2" ]] || [[ -z "$user_choice" ]]; then
                    log_status "INFO" "User chose to exit (or timed out). Exiting loop..."
                    update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit_exit" "stopped" "api_5hour_limit"
                    break
                else
                    log_status "INFO" "User chose to wait. Waiting for API limit reset..."
                    # Wait for longer period when API limit is hit
                    local wait_minutes=60
                    log_status "INFO" "Waiting $wait_minutes minutes before retrying..."

                    # Countdown display
                    local wait_seconds=$((wait_minutes * 60))
                    while [[ $wait_seconds -gt 0 ]]; do
                        local minutes=$((wait_seconds / 60))
                        local seconds=$((wait_seconds % 60))
                        printf "\r${YELLOW}Time until retry: %02d:%02d${NC}" $minutes $seconds
                        sleep 1
                        ((wait_seconds--))
                    done
                    printf "\n"

                    # Resume at the same loop number after waiting
                    loop_count=$(loop_count_pre_increment_for_resume "$loop_count")
                    continue
                fi
            fi
        else
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "failed" "error"
            log_status "WARN" "Execution failed, waiting 30 seconds before retry..."
            sleep 30
        fi
        
        log_status "LOOP" "=== Completed Loop #$loop_count ==="
    done
    return "$main_exit_code"
}

# Help function
show_help() {
    cat << HELPEOF
Ralph Loop for Claude Code

Usage: $0 [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.
           Use 'ralph-setup project-name' to create a new project first.

Options:
    -h, --help              Show this help message
    -c, --calls NUM         Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE       Set prompt file (default: $PROMPT_FILE)
    -s, --status            Show current status and exit
    -m, --monitor           Start with tmux session and live monitor (requires tmux)
    -v, --verbose           Show detailed progress updates during execution
    -t, --timeout MIN       Set Claude Code execution timeout in minutes (default: $CLAUDE_TIMEOUT_MINUTES)
    --reset-circuit         Reset circuit breaker to CLOSED state
    --circuit-status        Show circuit breaker status and exit
    --reset-session         Reset session state and exit (clears session continuity)
    --reset-review-state    Reset review count state and exit

Modern CLI Options (Phase 1.1):
    --output-format FORMAT  Set Claude output format: json or text (default: $CLAUDE_OUTPUT_FORMAT)
    --allowed-tools TOOLS   Comma-separated list of allowed tools (default: $CLAUDE_ALLOWED_TOOLS)
                            Supports scoped tokens: Read(<glob>), Write(<glob>), Edit(<glob>)
    --permission-mode MODE  Set Claude CLI permission mode (default: unset)
    --review-only           Restrict tools to Codex MCP only for this run
    --no-continue           Disable session continuity across loops
    --session-expiry HOURS  Set session expiration time in hours (default: $CLAUDE_SESSION_EXPIRY_HOURS)

Codex Context Options:
    --codex-context FILE    Path to file list for Codex context bundle (optional)
    --codex-context-max-lines N   Max lines per file in Codex context (default: $CODEX_CONTEXT_MAX_LINES)
    --codex-context-max-chars N   Max chars per file in Codex context (default: $CODEX_CONTEXT_MAX_CHARS)
    --codex-context-total-chars N Max total chars across bundle (default: $CODEX_CONTEXT_TOTAL_MAX_CHARS)

Autonomous Mode Options (CP-016.26):
    --autonomous            Run without interactive prompts; auto-wait on rate limit and resume

Monorepo Options (Phase 6.5):
    --state-dir DIR         Directory for all state files (default: . - current directory)
    --fix-plan FILE         Path to fix plan file (default: $FIX_PLAN_FILE)
    --focus-fix-plan        Append remaining fix plan items to the system prompt (default: on)
    --no-focus-fix-plan     Disable fix plan focus injection

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)
    - .ralph_session: Session lifecycle tracking
    - .ralph_session_history: Session transition history (last 50)
    - .call_count: API call counter for rate limiting
    - .last_reset: Timestamp of last rate limit reset

Example workflow:
    ralph-setup my-project     # Create project
    cd my-project             # Enter project directory
    $0 --monitor             # Start Ralph with monitoring

Examples:
    $0 --calls 50 --prompt my_prompt.md
    $0 --monitor             # Start with integrated tmux monitoring
    $0 --monitor --timeout 30   # 30-minute timeout for complex tasks
    $0 --verbose --timeout 5    # 5-minute timeout with detailed progress
    $0 --output-format text     # Use legacy text output format
    $0 --no-continue            # Disable session continuity
    $0 --session-expiry 48      # 48-hour session expiration
    $0 --no-focus-fix-plan      # Disable fix plan focus injection

HELPEOF
}

# Parse command line arguments
	while [[ $# -gt 0 ]]; do
	    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
	        -s|--status)
	            setup_state_paths
	            if [[ -f "$STATUS_FILE" ]]; then
	                echo "Current Status:"
	                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
	            else
	                echo "No status file found. Ralph may not be running."
            fi
            exit 0
            ;;
        -m|--monitor)
            USE_TMUX=true
            shift
            ;;
        -v|--verbose)
            VERBOSE_PROGRESS=true
            shift
            ;;
        -t|--timeout)
            if [[ "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$2" -le 120 ]]; then
                CLAUDE_TIMEOUT_MINUTES="$2"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
            ;;
	        --reset-circuit)
	            # Source the circuit breaker library
	            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
	            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
	            source "$SCRIPT_DIR/lib/date_utils.sh"
	            setup_state_paths
	            reset_circuit_breaker "Manual reset via command line"
	            reset_session "manual_circuit_reset"
	            exit 0
	            ;;
	        --reset-session)
	            # Reset session state only
	            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
	            source "$SCRIPT_DIR/lib/date_utils.sh"
	            setup_state_paths
	            reset_session "manual_reset_flag"
	            echo -e "\033[0;32m✅ Session state reset successfully\033[0m"
	            exit 0
	            ;;
        --reset-review-state)
            RESET_REVIEW_STATE=true
            shift
            ;;
	        --circuit-status)
	            # Source the circuit breaker library
	            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
	            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
	            setup_state_paths
	            show_circuit_status
	            exit 0
	            ;;
        --output-format)
            if [[ "$2" == "json" || "$2" == "text" ]]; then
                CLAUDE_OUTPUT_FORMAT="$2"
            else
                echo "Error: --output-format must be 'json' or 'text'"
                exit 1
            fi
            shift 2
            ;;
        --allowed-tools)
            if ! validate_allowed_tools "$2"; then
                exit 1
            fi
            CLAUDE_ALLOWED_TOOLS="$2"
            shift 2
            ;;
        --permission-mode)
            if [[ -z "$2" ]]; then
                echo "Error: --permission-mode requires a value"
                exit 1
            fi
            CLAUDE_PERMISSION_MODE="$2"
            shift 2
            ;;
        --review-only)
            CODEX_REVIEW_ONLY=true
            shift
            ;;
        --codex-context)
            if [[ -z "$2" ]]; then
                echo "Error: --codex-context requires a file path"
                exit 1
            fi
            CODEX_CONTEXT_FILE="$2"
            shift 2
            ;;
        --codex-context-max-lines)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --codex-context-max-lines requires a positive integer"
                exit 1
            fi
            CODEX_CONTEXT_MAX_LINES="$2"
            shift 2
            ;;
        --codex-context-max-chars)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --codex-context-max-chars requires a positive integer"
                exit 1
            fi
            CODEX_CONTEXT_MAX_CHARS="$2"
            shift 2
            ;;
        --codex-context-total-chars)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --codex-context-total-chars requires a positive integer"
                exit 1
            fi
            CODEX_CONTEXT_TOTAL_MAX_CHARS="$2"
            shift 2
            ;;
        --no-continue)
            CLAUDE_USE_CONTINUE=false
            shift
            ;;
        --session-expiry)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --session-expiry requires a positive integer (hours)"
                exit 1
            fi
            CLAUDE_SESSION_EXPIRY_HOURS="$2"
            shift 2
            ;;
        --state-dir)
            if [[ -z "$2" ]]; then
                echo "Error: --state-dir requires a path argument"
                exit 1
            fi
            STATE_DIR="$2"
            shift 2
            ;;
        --fix-plan)
            if [[ -z "$2" ]]; then
                echo "Error: --fix-plan requires a file path argument"
                exit 1
            fi
            FIX_PLAN_FILE="$2"
            shift 2
            ;;
        --focus-fix-plan)
            FOCUS_FIX_PLAN=true
            shift
            ;;
        --no-focus-fix-plan)
            FOCUS_FIX_PLAN=false
            shift
            ;;
        --autonomous)
            # CP-016.26: Enable autonomous mode - auto-wait on rate limit instead of prompting
            AUTONOMOUS_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Setup state paths with STATE_DIR prefix
setup_state_paths

if [[ "$RESET_REVIEW_STATE" == "true" ]]; then
    rm -f "$REVIEW_STATE_FILE"
    echo -e "\033[0;32m✅ Review state reset successfully\033[0m"
    exit 0
fi

# Only execute when run directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # If tmux mode requested, set it up
    if [[ "$USE_TMUX" == "true" ]]; then
        check_tmux_available
        setup_tmux_session
    fi

    # Start the main loop
    main
fi
