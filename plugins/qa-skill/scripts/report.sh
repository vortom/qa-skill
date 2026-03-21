#!/bin/bash
# JUnit XML report generation for QA testing
# Usage: source this file, then call functions
#
# Optional environment variables:
#   QA_REPORT_PREFIX - Prefix for the temp state directory (default: "qa-test-report")
#                      The state dir will be /tmp/<QA_REPORT_PREFIX>

# Report state (using temp files for cross-function state)
# Not readonly — script may be re-sourced in the same shell session
REPORT_STATE_DIR="/tmp/${QA_REPORT_PREFIX:-qa-test-report}"
REPORT_TESTCASES_FILE="$REPORT_STATE_DIR/testcases.xml"
REPORT_STATS_FILE="$REPORT_STATE_DIR/stats"

# Colors for output (guarded — may already be defined by adb.sh)
if [[ -z "${RED:-}" ]]; then readonly RED='\033[0;31m'; fi
if [[ -z "${GREEN:-}" ]]; then readonly GREEN='\033[0;32m'; fi
if [[ -z "${NC:-}" ]]; then readonly NC='\033[0m'; fi

# Portable timestamp — macOS date doesn't support %N (nanoseconds)
_report_timestamp() {
    if date +%s.%N 2>/dev/null | grep -q 'N'; then
        date +%s
    else
        date +%s.%N
    fi
}

log_info() { echo -e "${GREEN}[REPORT]${NC} $*"; }
log_error() { echo -e "${RED}[REPORT]${NC} $*" >&2; }

# Initialize a new report
report_init() {
    local suite_name="$1"
    local output_dir="${2:-tests/qa/results}"
    rm -rf "$REPORT_STATE_DIR"
    mkdir -p "$REPORT_STATE_DIR"
    : > "$REPORT_TESTCASES_FILE"
    cat > "$REPORT_STATS_FILE" << EOF
suite_name='${suite_name//\'/\'\\\'\'}'
output_dir='${output_dir//\'/\'\\\'\'}'
tests=0
failures=0
errors=0
start_time=$(_report_timestamp)
EOF
    mkdir -p "$output_dir"
    log_info "Initialized report: $suite_name"
}

# Add a passing test case
report_add_pass() {
    local test_name="$1"
    local duration="$2"
    source "$REPORT_STATS_FILE"
    local escaped_name
    escaped_name=$(echo "$test_name" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
    cat >> "$REPORT_TESTCASES_FILE" << EOF
  <testcase name="$escaped_name" classname="qa.${suite_name}" time="$duration"/>
EOF
    ((tests++))
    sed -i '' "s/^tests=.*/tests=$tests/" "$REPORT_STATS_FILE" 2>/dev/null || \
        sed -i "s/^tests=.*/tests=$tests/" "$REPORT_STATS_FILE"
    log_info "PASS: $test_name (${duration}s)"
}

# Add a failing test case
report_add_fail() {
    local test_name="$1"
    local duration="$2"
    local error_message="$3"
    local screenshot_path="${4:-}"
    source "$REPORT_STATS_FILE"
    local escaped_name
    local escaped_message
    escaped_name=$(echo "$test_name" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
    escaped_message=$(echo "$error_message" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
    local failure_content="$escaped_message"
    if [[ -n "$screenshot_path" ]]; then
        failure_content="${failure_content}&#10;Screenshot: ${screenshot_path}"
    fi
    cat >> "$REPORT_TESTCASES_FILE" << EOF
  <testcase name="$escaped_name" classname="qa.${suite_name}" time="$duration">
    <failure message="$escaped_message">$failure_content</failure>
  </testcase>
EOF
    ((tests++))
    ((failures++))
    sed -i '' "s/^tests=.*/tests=$tests/" "$REPORT_STATS_FILE" 2>/dev/null || \
        sed -i "s/^tests=.*/tests=$tests/" "$REPORT_STATS_FILE"
    sed -i '' "s/^failures=.*/failures=$failures/" "$REPORT_STATS_FILE" 2>/dev/null || \
        sed -i "s/^failures=.*/failures=$failures/" "$REPORT_STATS_FILE"
    log_error "FAIL: $test_name (${duration}s) - $error_message"
}

# Add an error test case
report_add_error() {
    local test_name="$1"
    local duration="$2"
    local error_message="$3"
    source "$REPORT_STATS_FILE"
    local escaped_name
    local escaped_message
    escaped_name=$(echo "$test_name" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
    escaped_message=$(echo "$error_message" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
    cat >> "$REPORT_TESTCASES_FILE" << EOF
  <testcase name="$escaped_name" classname="qa.${suite_name}" time="$duration">
    <error message="$escaped_message">$escaped_message</error>
  </testcase>
EOF
    ((tests++))
    ((errors++))
    sed -i '' "s/^tests=.*/tests=$tests/" "$REPORT_STATS_FILE" 2>/dev/null || \
        sed -i "s/^tests=.*/tests=$tests/" "$REPORT_STATS_FILE"
    sed -i '' "s/^errors=.*/errors=$errors/" "$REPORT_STATS_FILE" 2>/dev/null || \
        sed -i "s/^errors=.*/errors=$errors/" "$REPORT_STATS_FILE"
    log_error "ERROR: $test_name (${duration}s) - $error_message"
}

# Finish the report and write to file
report_finish() {
    source "$REPORT_STATS_FILE"
    local end_time
    local total_time
    end_time=$(_report_timestamp)
    total_time=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
    local timestamp
    timestamp=$(date +%Y-%m-%dT%H-%M-%S)
    local output_file="${output_dir}/${suite_name}-${timestamp}.xml"
    cat > "$output_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="$suite_name" tests="$tests" failures="$failures" errors="$errors" time="$total_time" timestamp="$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)">
$(cat "$REPORT_TESTCASES_FILE")
</testsuite>
EOF
    log_info "Report saved: $output_file"
    log_info "Results: $tests tests, $failures failures, $errors errors (${total_time}s)"
    rm -rf "$REPORT_STATE_DIR"
    if [[ "$failures" -gt 0 ]] || [[ "$errors" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Get current test count
report_get_test_count() {
    source "$REPORT_STATS_FILE"
    echo "$tests"
}

# Print summary without finishing
report_summary() {
    source "$REPORT_STATS_FILE"
    local verdict="PASS"
    if [[ "$failures" -gt 0 ]] || [[ "$errors" -gt 0 ]]; then
        verdict="FAIL"
    fi
    echo "[$verdict] $tests tests, $failures failures, $errors errors"
}
