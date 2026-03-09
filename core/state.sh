#!/usr/bin/env bash
# =============================================================================
# claude-quality-worker — State file management (jq-based)
#
# Sourced by run.sh. Provides functions to read/write state.json, which
# tracks per-domain review progress (last commit, baseline status).
#
# The state file is managed exclusively by bash — Claude never touches it.
# =============================================================================

# STATE_FILE must be set before sourcing this file.
# Typically: STATE_FILE="$SCRIPT_DIR/state.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Read a value from state.json
# Usage: state_read ".domains.lint.last_reviewed_commit"
state_read() {
    local jq_path="$1"
    jq -r "$jq_path // empty" "$STATE_FILE" 2>/dev/null || echo ""
}

# Write a value to state.json (in-place)
# Usage: state_write ".domains.lint.last_reviewed_commit" '"abc123"'
# Note: string values must be quoted with inner quotes: '"value"'
#       null/true/false/numbers are bare: 'null', 'true', '42'
state_write() {
    local jq_path="$1"
    local value="$2"
    local tmp
    tmp=$(mktemp)
    jq "$jq_path = $value" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Domain state accessors
# ---------------------------------------------------------------------------

# Get the last reviewed commit for a domain
# Usage: state_last_commit "lint"
state_last_commit() {
    local domain="$1"
    state_read ".domains.${domain}.last_reviewed_commit"
}

# Get whether baseline is complete for a domain
# Usage: state_baseline_complete "types"  → "true" or "false" or ""
state_baseline_complete() {
    local domain="$1"
    state_read ".domains.${domain}.baseline_complete"
}

# Get the last run date for a domain
# Usage: state_last_run_date "docs"
state_last_run_date() {
    local domain="$1"
    state_read ".domains.${domain}.last_run_date"
}

# Mark a domain as reviewed up to a commit
# Usage: state_mark_reviewed "lint" "abc123def" "2026-03-08" "0"
state_mark_reviewed() {
    local domain="$1"
    local commit="$2"
    local date="$3"
    local exit_code="${4:-0}"
    local tmp
    tmp=$(mktemp)
    jq ".domains.${domain}.last_reviewed_commit = \"${commit}\"
        | .domains.${domain}.last_run_date = \"${date}\"
        | .domains.${domain}.last_run_status = \"${exit_code}\"" \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Mark baseline as complete for a domain
# Usage: state_mark_baseline_complete "lint"
state_mark_baseline_complete() {
    local domain="$1"
    local tmp
    tmp=$(mktemp)
    jq ".domains.${domain}.baseline_complete = true
        | .domains.${domain}.baseline_remaining = []" \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Baseline progress tracking
# ---------------------------------------------------------------------------

# Get remaining files for baseline
# Usage: state_baseline_remaining "types"  → newline-separated file list
state_baseline_remaining() {
    local domain="$1"
    jq -r ".domains.${domain}.baseline_remaining // [] | .[]" "$STATE_FILE" 2>/dev/null || true
}

# Set the initial list of remaining files for baseline
# Usage: state_set_baseline_remaining "lint" file1.py file2.py ...
state_set_baseline_remaining() {
    local domain="$1"
    shift
    local json_array
    json_array=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    local tmp
    tmp=$(mktemp)
    jq ".domains.${domain}.baseline_remaining = ${json_array}" \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Remove processed files from baseline remaining list
# Usage: state_remove_from_baseline "lint" file1.py file2.py ...
state_remove_from_baseline() {
    local domain="$1"
    shift
    local remove_array
    remove_array=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    local tmp
    tmp=$(mktemp)
    jq ".domains.${domain}.baseline_remaining -= ${remove_array}" \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Get count of remaining baseline files
# Usage: state_baseline_remaining_count "types"
state_baseline_remaining_count() {
    local domain="$1"
    jq ".domains.${domain}.baseline_remaining // [] | length" "$STATE_FILE" 2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
# Domain rotation
# ---------------------------------------------------------------------------

# Pick the domain with the oldest last_run_date (for auto-rotation)
# Returns: "lint", "types", or "docs"
state_pick_next_domain() {
    # If any domain has never run, pick the first one (priority: lint → types → docs)
    for d in lint types docs; do
        local last_date
        last_date=$(state_last_run_date "$d")
        if [[ -z "$last_date" ]]; then
            echo "$d"
            return
        fi
    done

    # All domains have run at least once — pick the oldest
    jq -r '
        .domains | to_entries
        | sort_by(.value.last_run_date // "0000-00-00")
        | .[0].key
    ' "$STATE_FILE" 2>/dev/null || echo "lint"
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

# Create state.json from template if it doesn't exist
state_ensure_exists() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "Creating initial state file: $STATE_FILE"
        cat > "$STATE_FILE" << 'STATEEOF'
{
  "version": 1,
  "domains": {
    "lint": {
      "last_reviewed_commit": null,
      "last_run_date": null,
      "last_run_status": null,
      "baseline_complete": false,
      "baseline_remaining": []
    },
    "types": {
      "last_reviewed_commit": null,
      "last_run_date": null,
      "last_run_status": null,
      "baseline_complete": false,
      "baseline_remaining": []
    },
    "docs": {
      "last_reviewed_commit": null,
      "last_run_date": null,
      "last_run_status": null,
      "baseline_complete": false,
      "baseline_remaining": []
    }
  }
}
STATEEOF
    fi
}
