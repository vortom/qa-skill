#!/bin/bash
# ADB wrapper functions for QA testing
# Usage: source this file, then call functions
#
# Required environment variables (must be set by the caller):
#   APP_PACKAGE   - Android application package name (e.g., "com.example.app")
#   APP_ACTIVITY  - Main activity class name (e.g., "com.example.app.MainActivity")
#
# Optional environment variables:
#   APK_PATH      - Path to the debug APK (default: "android/app/build/outputs/apk/debug/app-debug.apk")
#
# Primitive functions:
#   adb_tap, adb_swipe, adb_input_text, adb_press_back, adb_press_home,
#   adb_screenshot, adb_get_screen_xml, adb_get_screen_size
#
# Compound functions (prefer these — each replaces 2-4 primitive calls):
#   adb_tap_text TEXT [SLEEP] [INDEX]      — XML dump → find element → tap center (falls back to content-desc, then clickable parent)
#   adb_tap_content_desc DESC [SLEEP] [INDEX] — XML dump → find by content-desc → tap center
#   adb_wait_for_text TEXT [TIMEOUT]       — Poll XML until text appears
#   adb_tap_and_wait TAP WAIT [TIMEOUT]    — Tap by text, wait for new text
#   adb_assert_text TEXT                   — Check text exists on screen (0/1)
#   adb_assert_no_text TEXT                — Check text does NOT exist on screen (0/1)
#   adb_list_texts [XML]                   — List all visible text elements
#   adb_screen_state SCREENSHOT [XML]      — Screenshot + XML dump in one call
#   adb_scroll_to_text TEXT [MAX] [DIR]    — Scroll until text found on screen
#   adb_toggle_airplane_mode STATE         — Toggle airplane mode on/off
#   adb_long_press X Y [DURATION]          — Long press at coordinates

# Validate required environment variables
if [[ -z "${APP_PACKAGE:-}" ]]; then
    echo "ERROR: APP_PACKAGE environment variable is not set." >&2
    echo "Set it to your Android application package name (e.g., export APP_PACKAGE='com.example.app')" >&2
    return 1 2>/dev/null || exit 1
fi

if [[ -z "${APP_ACTIVITY:-}" ]]; then
    echo "ERROR: APP_ACTIVITY environment variable is not set." >&2
    echo "Set it to your main activity class (e.g., export APP_ACTIVITY='com.example.app.MainActivity')" >&2
    return 1 2>/dev/null || exit 1
fi

# Configuration (derived from environment)
readonly QA_APP_PACKAGE="$APP_PACKAGE"
readonly QA_APP_ACTIVITY="$APP_ACTIVITY"
readonly QA_APK_PATH="${APK_PATH:-android/app/build/outputs/apk/debug/app-debug.apk}"

# Colors for output (guarded — may already be defined by report.sh)
if [[ -z "${RED:-}" ]]; then readonly RED='\033[0;31m'; fi
if [[ -z "${GREEN:-}" ]]; then readonly GREEN='\033[0;32m'; fi
if [[ -z "${YELLOW:-}" ]]; then readonly YELLOW='\033[0;33m'; fi
if [[ -z "${NC:-}" ]]; then readonly NC='\033[0m'; fi

log_info() { echo -e "${GREEN}[ADB]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[ADB]${NC} $*"; }
log_error() { echo -e "${RED}[ADB]${NC} $*" >&2; }

# Check if a device/emulator is connected and ready
adb_device_ready() {
    local devices
    devices=$(adb devices 2>/dev/null | grep -v "List" | grep -v "^$" | wc -l)
    if [[ "$devices" -eq 0 ]]; then
        log_error "No devices connected"
        return 1
    fi
    if ! adb devices 2>/dev/null | grep -q "device$"; then
        log_error "Device not ready (offline or unauthorized)"
        return 1
    fi
    log_info "Device ready"
    return 0
}

# Get the connected device/emulator serial
adb_get_device() {
    adb devices 2>/dev/null | grep "device$" | head -1 | cut -f1
}

# Install the debug APK
adb_install_app() {
    if [[ ! -f "$QA_APK_PATH" ]]; then
        log_error "APK not found at: $QA_APK_PATH"
        log_info "Build it first: cd android && ./gradlew assembleDebug"
        return 1
    fi
    log_info "Installing APK: $QA_APK_PATH"
    if adb install -r "$QA_APK_PATH" >/dev/null 2>&1; then
        log_info "App installed successfully"
        return 0
    else
        log_error "Failed to install APK"
        return 1
    fi
}

# Check if app is installed
adb_app_installed() {
    adb shell pm list packages 2>/dev/null | grep -q "$QA_APP_PACKAGE"
}

# Launch the app
adb_launch_app() {
    log_info "Launching app ($QA_APP_PACKAGE)"
    adb shell am start -n "${QA_APP_PACKAGE}/${QA_APP_ACTIVITY}" >/dev/null 2>&1
    sleep 2
    log_info "App launched"
}

# Force stop the app
adb_stop_app() {
    log_info "Stopping app ($QA_APP_PACKAGE)"
    adb shell am force-stop "$QA_APP_PACKAGE" >/dev/null 2>&1
    log_info "App stopped"
}

# Clear app data
adb_clear_app_data() {
    log_info "Clearing app data ($QA_APP_PACKAGE)"
    adb shell pm clear "$QA_APP_PACKAGE" >/dev/null 2>&1
    log_info "App data cleared"
}

# Tap at screen coordinates
adb_tap() {
    local x="$1"
    local y="$2"
    log_info "Tap at ($x, $y)"
    adb shell input tap "$x" "$y"
    sleep 0.5
}

# Swipe gesture
adb_swipe() {
    local x1="$1"
    local y1="$2"
    local x2="$3"
    local y2="$4"
    local duration="${5:-300}"
    log_info "Swipe from ($x1, $y1) to ($x2, $y2)"
    adb shell input swipe "$x1" "$y1" "$x2" "$y2" "$duration"
    sleep 0.5
}

# Input text
adb_input_text() {
    local text="$1"
    local escaped_text="${text// /%s}"
    log_info "Input text: $text"
    adb shell input text "$escaped_text"
}

# Press back button
adb_press_back() {
    log_info "Press back"
    adb shell input keyevent KEYCODE_BACK
    sleep 0.3
}

# Press home button
adb_press_home() {
    log_info "Press home"
    adb shell input keyevent KEYCODE_HOME
    sleep 0.3
}

# Take a screenshot (resized to fit Claude Code's 2000px multi-image limit)
adb_screenshot() {
    local output_file="$1"
    local max_dimension="${2:-1800}"
    local output_dir
    output_dir=$(dirname "$output_file")
    mkdir -p "$output_dir"
    local temp_file="/sdcard/screenshot_temp.png"
    adb shell screencap -p "$temp_file" 2>/dev/null
    adb pull "$temp_file" "$output_file" >/dev/null 2>&1
    adb shell rm "$temp_file" 2>/dev/null
    if [[ -f "$output_file" ]]; then
        # Resize so longest side ≤ max_dimension (prevents Claude Code image limit errors)
        if command -v sips &>/dev/null; then
            sips --resampleHeightWidthMax "$max_dimension" "$output_file" >/dev/null 2>&1
        elif command -v convert &>/dev/null; then
            convert "$output_file" -resize "${max_dimension}x${max_dimension}>" "$output_file"
        fi
        log_info "Screenshot saved: $output_file"
        return 0
    else
        log_error "Failed to capture screenshot"
        return 1
    fi
}

# Get UI hierarchy XML (with retry — uiautomator can fail during transitions)
adb_get_screen_xml() {
    local output_file="$1"
    local temp_file="/sdcard/window_dump.xml"
    local attempt
    for attempt in 1 2 3; do
        adb shell uiautomator dump "$temp_file" >/dev/null 2>&1
        adb pull "$temp_file" "$output_file" >/dev/null 2>&1
        adb shell rm "$temp_file" 2>/dev/null
        if [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
            log_info "UI hierarchy saved: $output_file"
            return 0
        fi
        if [[ $attempt -lt 3 ]]; then
            log_warn "XML dump attempt $attempt failed, retrying in 1s..."
            sleep 1
        fi
    done
    log_error "Failed to dump UI hierarchy after 3 attempts"
    return 1
}

# Get screen resolution
adb_get_screen_size() {
    adb shell wm size 2>/dev/null | grep -oE "[0-9]+x[0-9]+" | tr 'x' ' '
}

# Wait for app to be in foreground
adb_wait_for_app() {
    local timeout="${1:-10}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if adb shell dumpsys activity activities 2>/dev/null | grep -q "mResumedActivity.*${QA_APP_PACKAGE}"; then
            log_info "App is in foreground"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    log_error "Timeout waiting for app to be in foreground"
    return 1
}

# ─── Compound / Smart Functions ──────────────────────────────────────────────
# These reduce tool calls by combining observe→act→verify into single commands.

# Internal: temp file for XML dumps (avoids per-call path arguments)
_ADB_XML_TMP="/tmp/qa-screen-dump.xml"

# Internal: dump fresh UI hierarchy to temp file (with retry)
_adb_fresh_xml() {
    local temp_file="/sdcard/window_dump.xml"
    local attempt
    for attempt in 1 2 3; do
        adb shell uiautomator dump "$temp_file" >/dev/null 2>&1
        adb pull "$temp_file" "$_ADB_XML_TMP" >/dev/null 2>&1
        adb shell rm "$temp_file" 2>/dev/null
        if [[ -f "$_ADB_XML_TMP" ]] && [[ -s "$_ADB_XML_TMP" ]]; then
            return 0
        fi
        if [[ $attempt -lt 3 ]]; then
            sleep 1
        fi
    done
    log_error "Failed to dump UI hierarchy after 3 attempts"
    return 1
}

# Internal: find element center coordinates by text match in XML file
# Usage: _adb_parse_bounds "Button Text" [xml_file] [index]
# Output: prints "cx cy" to stdout (e.g., "540 1802")
# index: 1-based match index (default 1 = first match)
# Returns 1 if not found
_adb_parse_bounds() {
    local search_text="$1"
    local xml_file="${2:-$_ADB_XML_TMP}"
    local index="${3:-1}"
    if [[ ! -f "$xml_file" ]]; then
        log_error "XML file not found: $xml_file"
        return 1
    fi
    # Split XML nodes onto separate lines, find matching text, extract bounds
    # Portable: uses sed + awk only (no grep -P)
    local bounds
    bounds=$(sed 's/></>\n</g' "$xml_file" \
        | grep "text=\"${search_text}\"" \
        | sed -n "${index}p" \
        | sed 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/')
    if [[ -z "$bounds" ]]; then
        # Fallback: try content-desc match
        bounds=$(sed 's/></>\n</g' "$xml_file" \
            | grep "content-desc=\"${search_text}\"" \
            | sed -n "${index}p" \
            | sed 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/')
    fi
    if [[ -z "$bounds" || "$bounds" == *"bounds"* ]]; then
        log_error "Element not found: '$search_text'"
        return 1
    fi
    # Calculate center from "x1 y1 x2 y2"
    local x1 y1 x2 y2
    read -r x1 y1 x2 y2 <<< "$bounds"

    # Detect zero bounds (Compose layout quirk: child Text can have [0,0][0,0] while parent is real)
    if [[ "$x1" -eq 0 && "$y1" -eq 0 && "$x2" -eq 0 && "$y2" -eq 0 ]]; then
        log_warn "Element '$search_text' has zero bounds, looking up clickable parent..."
        local parent_bounds
        parent_bounds=$(sed 's/></>\n</g' "$xml_file" \
            | grep -B10 "text=\"${search_text}\"" \
            | grep 'clickable="true"' \
            | tail -1 \
            | sed 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/')
        if [[ -n "$parent_bounds" && "$parent_bounds" != "0 0 0 0" ]]; then
            read -r x1 y1 x2 y2 <<< "$parent_bounds"
            log_info "Using clickable parent bounds: [$x1,$y1][$x2,$y2]"
        else
            log_error "Element '$search_text' and all parents have zero bounds — cannot determine position"
            return 1
        fi
    fi

    echo "$(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))"
}

# Internal: find element center coordinates by content-desc only
# Usage: _adb_parse_bounds_desc "Journal" [xml_file] [index]
_adb_parse_bounds_desc() {
    local search_desc="$1"
    local xml_file="${2:-$_ADB_XML_TMP}"
    local index="${3:-1}"
    if [[ ! -f "$xml_file" ]]; then
        log_error "XML file not found: $xml_file"
        return 1
    fi
    local bounds
    bounds=$(sed 's/></>\n</g' "$xml_file" \
        | grep "content-desc=\"${search_desc}\"" \
        | sed -n "${index}p" \
        | sed 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/')
    if [[ -z "$bounds" || "$bounds" == *"bounds"* ]]; then
        log_error "Element not found (content-desc): '$search_desc'"
        return 1
    fi
    local x1 y1 x2 y2
    read -r x1 y1 x2 y2 <<< "$bounds"
    echo "$(( (x1 + x2) / 2 )) $(( (y1 + y2) / 2 ))"
}

# Tap an element found by its visible text (one call replaces XML dump + parse + tap)
# Falls back to content-desc if text not found.
# Usage: adb_tap_text "Continue with Google" [sleep_after] [index]
# index: 1-based match index for disambiguation (default 1 = first match)
adb_tap_text() {
    local search_text="$1"
    local sleep_after="${2:-1}"
    local index="${3:-1}"
    _adb_fresh_xml || return 1
    local coords
    coords=$(_adb_parse_bounds "$search_text" "$_ADB_XML_TMP" "$index") || return 1
    local cx cy
    read -r cx cy <<< "$coords"
    if [[ "$cx" -eq 0 && "$cy" -eq 0 ]]; then
        log_error "Tap aborted: resolved coordinates are (0, 0) for '$search_text'"
        return 1
    fi
    log_info "Tap text '$search_text' at ($cx, $cy)"
    adb shell input tap "$cx" "$cy"
    sleep "$sleep_after"
}

# Tap an element found by its content-desc attribute (for elements without visible text)
# Usage: adb_tap_content_desc "Journal" [sleep_after] [index]
adb_tap_content_desc() {
    local search_desc="$1"
    local sleep_after="${2:-1}"
    local index="${3:-1}"
    _adb_fresh_xml || return 1
    local coords
    coords=$(_adb_parse_bounds_desc "$search_desc" "$_ADB_XML_TMP" "$index") || return 1
    local cx cy
    read -r cx cy <<< "$coords"
    if [[ "$cx" -eq 0 && "$cy" -eq 0 ]]; then
        log_error "Tap aborted: resolved coordinates are (0, 0) for content-desc '$search_desc'"
        return 1
    fi
    log_info "Tap content-desc '$search_desc' at ($cx, $cy)"
    adb shell input tap "$cx" "$cy"
    sleep "$sleep_after"
}

# Wait until specific text appears on screen (polls UI XML)
# Usage: adb_wait_for_text "Welcome" [timeout_seconds]
# Returns 0 when found, 1 on timeout
adb_wait_for_text() {
    local search_text="$1"
    local timeout="${2:-10}"
    local elapsed=0
    log_info "Waiting for text: '$search_text' (timeout: ${timeout}s)"
    while [[ $elapsed -lt $timeout ]]; do
        _adb_fresh_xml 2>/dev/null
        if _adb_parse_bounds "$search_text" >/dev/null 2>&1; then
            log_info "Found text: '$search_text' (${elapsed}s)"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    log_error "Timeout waiting for text: '$search_text'"
    return 1
}

# Tap element by text, then wait for new text to appear (state transition in one call)
# Usage: adb_tap_and_wait "Next" "You're Ready" [timeout]
adb_tap_and_wait() {
    local tap_text="$1"
    local wait_text="$2"
    local timeout="${3:-10}"
    adb_tap_text "$tap_text" 0.5 || return 1
    adb_wait_for_text "$wait_text" "$timeout"
}

# Assert that specific text exists on the current screen
# Usage: adb_assert_text "Content generated by AI" && echo "found"
# Returns 0 if found, 1 if not
adb_assert_text() {
    local search_text="$1"
    _adb_fresh_xml || return 1
    if _adb_parse_bounds "$search_text" >/dev/null 2>&1; then
        log_info "Assert PASS: '$search_text' found"
        return 0
    else
        log_error "Assert FAIL: '$search_text' not found"
        return 1
    fi
}

# List all visible text elements on screen (one per line, for debugging)
# Usage: adb_list_texts [xml_file]
adb_list_texts() {
    local xml_file="${1:-}"
    if [[ -z "$xml_file" ]]; then
        _adb_fresh_xml || return 1
        xml_file="$_ADB_XML_TMP"
    fi
    sed 's/></>\n</g' "$xml_file" \
        | sed -n 's/.*text="\([^"]*\)".*/\1/p' \
        | grep -v '^$'
}

# Capture full screen state: screenshot + XML dump in one call
# Usage: adb_screen_state "/path/to/screenshot.png" ["/path/to/dump.xml"]
adb_screen_state() {
    local screenshot_path="$1"
    local xml_path="${2:-${screenshot_path%.png}.xml}"
    adb_screenshot "$screenshot_path" || return 1
    adb_get_screen_xml "$xml_path" || return 1
    log_info "State captured: $screenshot_path + $xml_path"
}

# ─── Additional Compound Functions ───────────────────────────────────────────

# Assert that specific text does NOT exist on the current screen (inverse of adb_assert_text)
# Usage: adb_assert_no_text "Error message" && echo "good, no error"
# Returns 0 if NOT found (pass), 1 if found (fail)
adb_assert_no_text() {
    local search_text="$1"
    _adb_fresh_xml || return 1
    if _adb_parse_bounds "$search_text" >/dev/null 2>&1; then
        log_error "Assert FAIL: '$search_text' found (unexpected)"
        return 1
    else
        log_info "Assert PASS: '$search_text' not found (expected)"
        return 0
    fi
}

# Scroll until specific text appears on screen
# Usage: adb_scroll_to_text "Sign Out" [max_scrolls] [direction]
# direction: "down" (default) or "up"
# Returns 0 when found, 1 if not found after max scrolls
adb_scroll_to_text() {
    local search_text="$1"
    local max_scrolls="${2:-5}"
    local direction="${3:-down}"
    local scroll_count=0

    log_info "Scrolling $direction to find: '$search_text' (max: $max_scrolls)"

    # Check if already visible
    _adb_fresh_xml 2>/dev/null
    if _adb_parse_bounds "$search_text" >/dev/null 2>&1; then
        log_info "Already visible: '$search_text'"
        return 0
    fi

    # Get screen dimensions for scroll gesture
    local screen_size
    screen_size=$(adb_get_screen_size)
    local screen_w screen_h
    read -r screen_w screen_h <<< "$screen_size"
    local center_x=$(( screen_w / 2 ))
    local start_y end_y

    if [[ "$direction" == "down" ]]; then
        start_y=$(( screen_h * 75 / 100 ))
        end_y=$(( screen_h * 25 / 100 ))
    else
        start_y=$(( screen_h * 25 / 100 ))
        end_y=$(( screen_h * 75 / 100 ))
    fi

    while [[ $scroll_count -lt $max_scrolls ]]; do
        adb shell input swipe "$center_x" "$start_y" "$center_x" "$end_y" 300
        sleep 0.5
        ((scroll_count++))

        _adb_fresh_xml 2>/dev/null
        if _adb_parse_bounds "$search_text" >/dev/null 2>&1; then
            log_info "Found '$search_text' after $scroll_count scroll(s)"
            return 0
        fi
    done

    log_error "Text '$search_text' not found after $max_scrolls scrolls"
    return 1
}

# Toggle airplane mode on or off
# Usage: adb_toggle_airplane_mode "on"   — enable airplane mode
#        adb_toggle_airplane_mode "off"  — disable airplane mode
# Note: Always restore "off" at end of test session — state persists across app restarts
# Note: On non-rooted Samsung Android 12+ devices, the broadcast may fail (SecurityException).
#       Falls back to svc wifi/data disable, but warns about potential ADB disruption.
adb_toggle_airplane_mode() {
    local state="$1"
    if [[ "$state" == "on" ]]; then
        adb shell settings put global airplane_mode_on 1
        if adb shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true 2>&1 | grep -q "SecurityException"; then
            log_warn "Airplane mode broadcast denied (device may require root)"
            log_warn "Falling back to svc wifi/data disable — ADB over WiFi may disconnect"
            adb shell svc wifi disable 2>/dev/null
            adb shell svc data disable 2>/dev/null
            sleep 2
            log_info "Network disabled via svc (WiFi + data off)"
        else
            sleep 1
            log_info "Airplane mode ON"
        fi
    elif [[ "$state" == "off" ]]; then
        adb shell settings put global airplane_mode_on 0
        if adb shell am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false 2>&1 | grep -q "SecurityException"; then
            log_warn "Airplane mode broadcast denied, re-enabling via svc..."
            adb shell svc wifi enable 2>/dev/null
            adb shell svc data enable 2>/dev/null
        fi
        sleep 2
        log_info "Airplane mode OFF / Network restored"
    else
        log_error "Invalid state: '$state' (use 'on' or 'off')"
        return 1
    fi
}

# Long press at screen coordinates (implemented as zero-distance swipe)
# Usage: adb_long_press 540 1200 [duration_ms]
# Default duration: 1000ms (1 second)
adb_long_press() {
    local x="$1"
    local y="$2"
    local duration="${3:-1000}"
    log_info "Long press at ($x, $y) for ${duration}ms"
    adb shell input swipe "$x" "$y" "$x" "$y" "$duration"
    sleep 0.5
}
