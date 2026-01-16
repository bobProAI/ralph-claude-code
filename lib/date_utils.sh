#!/usr/bin/env bash

# date_utils.sh - Cross-platform date utility functions
# Provides consistent date formatting and arithmetic across GNU (Linux) and BSD (macOS) systems

# Get current timestamp in ISO 8601 format with seconds precision
# Returns: YYYY-MM-DDTHH:MM:SS+00:00 format
get_iso_timestamp() {
    local os_type
    os_type=$(uname)

    if [[ "$os_type" == "Darwin" ]]; then
        # macOS (BSD date)
        # Use manual formatting and add colon to timezone offset
        date -u +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\(..\)$/:\1/'
    else
        # Linux (GNU date) - use -u flag for UTC
        date -u -Iseconds
    fi
}

# Get time component (HH:MM:SS) for one hour from now
# Returns: HH:MM:SS format
get_next_hour_time() {
    # Try BSD date first (macOS native), then GNU date (Linux or Homebrew coreutils)
    # This handles cases where PATH has GNU coreutils even on macOS
    if date -v+1H '+%H:%M:%S' 2>/dev/null; then
        return 0
    elif date -d '+1 hour' '+%H:%M:%S' 2>/dev/null; then
        return 0
    else
        # Fallback: calculate manually using epoch arithmetic
        local current_epoch next_epoch
        current_epoch=$(date +%s)
        next_epoch=$((current_epoch + 3600))
        date -r "$next_epoch" '+%H:%M:%S' 2>/dev/null || \
        date -d "@$next_epoch" '+%H:%M:%S' 2>/dev/null || \
        echo "??:??:??"
    fi
}

# Get current timestamp in a basic format (fallback)
# Returns: YYYY-MM-DD HH:MM:SS format
get_basic_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Get current Unix epoch time in seconds
# Returns: Integer seconds since 1970-01-01 00:00:00 UTC
get_epoch_seconds() {
    date +%s
}

# Export functions for use in other scripts
export -f get_iso_timestamp
export -f get_next_hour_time
export -f get_basic_timestamp
export -f get_epoch_seconds
