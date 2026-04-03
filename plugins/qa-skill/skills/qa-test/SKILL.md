---
name: qa-test
description: Use when you need to run end-to-end QA testing on any platform the project supports — Android, Web, iOS, desktop, etc. Detects platforms from project structure and docs, then uses the appropriate testing tools. Supports PR review, manual test cases, and exploratory testing.
argument-hint: "[--pr N] [--cases path] [description]"
disable-model-invocation: false
allowed-tools: Bash(/tmp/qa *), Bash(adb *), Bash(curl *), Read, Write
---

# QA Test Skill

Autonomous QA testing pipeline. Five phases, each writing artifacts to a session directory. Platform-agnostic — discovers what platforms exist and adapts execution accordingly.

## Input Parsing

Parse `$ARGUMENTS`:
- Contains `--pr <N>` → PR mode
- Contains `--issue <N>` → Issue mode (fetch test cases from GitHub issue)
- Contains `--cases <path>` → Test cases mode (format: `templates/test-case.md`)
- Non-empty free text → Description mode
- Empty/no args → Interactive (ask user which mode)

## Phase 0: SETUP

**CRITICAL — use absolute paths everywhere.** Relative paths break across tool calls because working directories can shift.

```bash
PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SESSION_DIR="$PROJECT_DIR/tests/qa-sessions/$(date +%Y-%m-%dT%H-%M)"
mkdir -p "$SESSION_DIR/screenshots"
```

**Why `git rev-parse`?** `$(pwd)` can resolve to the wrong directory if context switches happened earlier in the conversation. `git rev-parse --show-toplevel` always returns the project root.

**Platform detection** — scan project structure, CLAUDE.md, README, and docs to build a `PLATFORMS` list. Look for platform directories, build configs, and documented setup instructions. Common signals:

| Signal | Platform |
|--------|----------|
| `android/` dir, `build.gradle.kts` | Android |
| `ios/` dir, `*.xcodeproj`, `*.xcworkspace` | iOS |
| Web framework configs (`next.config.*`, `vite.config.*`, `package.json` with dev server), `playwright.config.*` | Web |
| Desktop framework indicators | Desktop |

This list is not exhaustive — use project docs as the source of truth. If no platforms detected, ask the user.

**Per-platform prerequisites:** For each detected platform, verify the testing environment is ready:
- Build tools available and app/site builds successfully
- Device, emulator, simulator, or browser connected/available
- Required MCP tools or CLI utilities accessible
- If the app requires a backend, verify it is accessible (e.g., `curl -sf <backend-url>/api/health`). Check CLAUDE.md for the backend URL.

**Locate skill scripts:** The skill uses `${CLAUDE_SKILL_DIR}` — a dynamic variable that Claude Code substitutes with the absolute path to this skill's directory at runtime. The runner template (Phase 1) uses this to find `../../scripts/report.sh` and `../../scripts/adb.sh` (relative to the skill's location within the plugin).

**Android-specific:** `adb.sh` is sourced later (after Phase 1 discovers APP_PACKAGE and APP_ACTIVITY).

**Permission handling:** This skill declares `allowed-tools` in its frontmatter, which auto-approves `/tmp/qa` runner commands, `adb` calls, `curl` health checks, and file read/write operations during skill execution. No manual permission configuration is needed.

> **Fallback:** If `allowed-tools` is not supported in your environment, add `"Bash(/tmp/qa *)"` to `.claude/settings.local.json` under `permissions.allow` to auto-approve runner commands manually.

## Phase 1: DISCOVER

**Project discovery (all platforms):**

PR mode (fast path):
1. `CLAUDE.md` — project overview, architecture, build commands
2. `gh pr view <N>` + `gh pr diff <N>` — understand what changed

Full discovery (all other modes):
1. `CLAUDE.md`, `README.md`, `.claude/rules/`, `docs/` scan
2. Key directories (`ls` top-level + platform dirs)
3. `git log --oneline -20` — recent changes

**Per-platform discovery:** For each detected platform, find the details needed to build, launch, navigate, and interact. Read project docs for platform-specific setup instructions, entry points, key screens/routes, and testing tools. Examples:
- Android: `APP_PACKAGE`, `APP_ACTIVITY`, build command, ADB interaction
- Web: base URL, dev server command, key routes, Playwright MCP interaction
- iOS: bundle ID, scheme, simulator setup, interaction method

Write findings to `<session>/context.md`: project identity, detected platforms with their specifics, key screens/flows, build commands, auth flow, known pitfalls.

**Gate:** If critical platform details cannot be determined (e.g., Android APP_PACKAGE, Web base URL), ask the user.

**Per-platform setup:** Build, install/deploy, and verify each platform is ready for testing. For Android, this includes sourcing `adb.sh` and running `adb_install_app`. For Web, ensure the dev server is running. Follow whatever setup the project docs describe.

**Session runner script (mandatory for Android, recommended for all platforms):** Shell state does not persist between Bash tool calls, so sourcing scripts and exporting env vars every time is wasteful and generates repetitive permission prompts. After discovering platform details, create the runner and a **fixed-path symlink**. For web-only sessions, the runner only needs `report.sh` — skip Android vars and `adb.sh`.

**All paths in the runner MUST be absolute** — never use relative paths.

**Finding the skill scripts:** Use `${CLAUDE_SKILL_DIR}` to resolve the scripts directory. This variable is automatically substituted by Claude Code with the absolute path to the skill's directory (`skills/qa-test/`). The helper scripts are at `../../scripts/` relative to the skill.

```bash
# CLAUDE_SKILL_DIR is substituted by Claude Code at runtime
# It points to the skill's directory (e.g., /path/to/qa-skill/skills/qa-test)
QA_PLUGIN_DIR="$(dirname "$(dirname "${CLAUDE_SKILL_DIR}")")"
```

**Android runner** (when Android platform detected):
```bash
cat > "$SESSION_DIR/qa.sh" << RUNNER
#!/bin/bash
set -euo pipefail
export SESSION_DIR="$SESSION_DIR"
export APP_PACKAGE="<discovered-package>"
export APP_ACTIVITY="<discovered-activity>"
export APK_PATH="$PROJECT_DIR/android/app/build/outputs/apk/debug/app-debug.apk"
QA_PLUGIN_DIR="$QA_PLUGIN_DIR"
source "\$QA_PLUGIN_DIR/scripts/report.sh"
source "\$QA_PLUGIN_DIR/scripts/adb.sh"
"\$@"
RUNNER
chmod +x "$SESSION_DIR/qa.sh"
ln -sf "$SESSION_DIR/qa.sh" /tmp/qa
```

**Web-only runner** (when only Web platform detected — no Android vars or adb.sh):
```bash
cat > "$SESSION_DIR/qa.sh" << RUNNER
#!/bin/bash
set -euo pipefail
export SESSION_DIR="$SESSION_DIR"
QA_PLUGIN_DIR="$QA_PLUGIN_DIR"
source "\$QA_PLUGIN_DIR/scripts/report.sh"
"\$@"
RUNNER
chmod +x "$SESSION_DIR/qa.sh"
ln -sf "$SESSION_DIR/qa.sh" /tmp/qa
```

**Why `/tmp/qa`?** Every command now starts with `/tmp/qa` — a fixed, simple prefix that Claude Code's permission system can match with a single rule: `Bash(/tmp/qa *)`. Without this, each command contains session-specific paths and shell variable expansions that don't match permission patterns.

Then **all subsequent commands** use `/tmp/qa` directly:
```bash
# Compound functions — prefer these (1 call replaces 3-4 primitive calls):
/tmp/qa adb_tap_text "Continue with Google"
/tmp/qa adb_tap_text "Enable Location" 1 2   # tap 2nd match (skip title, hit button)
/tmp/qa adb_tap_content_desc "Journal"        # for icon-only nav items
/tmp/qa adb_tap_and_wait "Next" "You're Ready" 10
/tmp/qa adb_assert_text "Welcome"

# Screenshot + XML state capture (use $SESSION_DIR inside eval — it's exported by the runner):
/tmp/qa adb_screen_state "$SESSION_DIR/screenshots/step1.png"

# Chain multiple actions in a single tool call (use eval, not bash -c):
/tmp/qa eval 'adb_tap_text "Next" && adb_screen_state "$SESSION_DIR/screenshots/step2.png" && report_add_pass "Navigation works" "3"'
```

## Phase 2: PLAN

Generate test plan based on input mode:

| Mode | Steps |
|------|-------|
| PR | `gh pr view <N>` + `gh pr diff <N>` → map changes to screens → generate scenarios |
| Issue | `gh issue view <N>` → extract test cases → parse priority/section structure → generate scenarios |
| Cases | Parse structured markdown, validate fields, order by dependency |
| Description | Map text to project context, generate scenarios |
| Interactive | Ask user, then follow appropriate mode |

Each scenario gets a `platform` tag. In PR mode, infer from changed file paths which platform(s) are affected. Backend changes → scenarios for all detected platforms.

Write to `<session>/test-plan.md`. Present plan to user.

**Gate:** Wait for user approval before executing.

## Phase 3: EXECUTE

```bash
/tmp/qa report_init "qa-test" "$SESSION_DIR"
```

**Limits:** Max 3 retries per step. Max 30 total steps per session.

### Tool Call Economy

**Each Bash tool call has overhead.** Even with `allowed-tools` auto-approval, minimize calls for efficiency:

1. **Use compound functions** instead of primitives (1 call replaces 3-4):

   | Instead of (3-4 calls) | Use (1 call) |
   |------------------------|--------------|
   | `adb_get_screen_xml` → parse XML → `adb_tap X Y` | `adb_tap_text "Button Label"` |
   | XML dump → find content-desc → `adb_tap X Y` | `adb_tap_content_desc "Journal"` |
   | `adb_tap_text` → `sleep` → poll XML | `adb_tap_and_wait "Next" "Ready"` |
   | `adb_screenshot` + `adb_get_screen_xml` | `adb_screen_state "path.png"` |
   | XML dump → grep for text → check result | `adb_assert_text "Expected Text"` |

2. **Chain related operations** with `&&` using `eval` (not `bash -c` — subshells lose sourced functions):
   ```bash
   /tmp/qa eval 'adb_tap_text "Next" && adb_assert_text "Step 2" && report_add_pass "Navigation" "3"'
   ```

3. **Batch verify + record** — combine assertion and reporting:
   ```bash
   /tmp/qa eval 'adb_assert_text "Welcome" && adb_assert_text "Sign In" && report_add_pass "Welcome screen elements" "2"'
   ```

4. **Screenshot only for evidence**, not for element discovery. Use `adb_list_texts` or `adb_assert_text` to inspect screen state.

### Android Function Reference

| Function | Purpose | Replaces |
|----------|---------|----------|
| `adb_tap_text TEXT [SLEEP] [INDEX]` | Find element by text + tap (falls back to content-desc). INDEX for disambiguation (1-based, default 1) | XML dump + parse + tap |
| `adb_tap_content_desc DESC [SLEEP] [INDEX]` | Find element by content-desc + tap. For elements without visible text (e.g., icon-only nav items) | XML dump + parse + tap |
| `adb_wait_for_text TEXT [TIMEOUT]` | Poll until text appears | Hardcoded `sleep` |
| `adb_tap_and_wait TAP WAIT [TIMEOUT]` | Tap + wait for transition | tap + sleep + verify |
| `adb_assert_text TEXT` | Check text on screen (0/1) | XML dump + grep |
| `adb_assert_no_text TEXT` | Check text NOT on screen (0/1) | XML dump + grep + invert |
| `adb_list_texts [XML]` | List all visible texts | XML dump + sed pipeline |
| `adb_screen_state SHOT [XML]` | Screenshot + XML in one call | screenshot + XML dump |
| `adb_scroll_to_text TEXT [MAX] [DIR]` | Scroll until text found | Manual swipe + XML dump loop |
| `adb_toggle_airplane_mode STATE` | Toggle airplane mode on/off | Manual adb shell commands |
| `adb_long_press X Y [DUR]` | Long press at coordinates | Zero-distance swipe hack |
| `adb_tap X Y` | Tap coordinates (primitive) | — |
| `adb_swipe X1 Y1 X2 Y2 [DUR]` | Swipe gesture (primitive) | — |

Dispatch each scenario to the right execution approach based on its `platform` tag. Use the interaction tools appropriate for each platform — the general pattern is always:

1. **Setup** — launch app/navigate to starting state
2. **Per step:**
   a. Observe current state (`adb_list_texts`, `adb_assert_text`, or `adb_screen_state`)
   b. Execute action (`adb_tap_text` or `adb_tap_and_wait`)
   c. Verify result (`adb_assert_text` or screenshot for visual evidence)
   d. Record: `report_add_pass` / `report_add_fail` / `report_add_error`

### Platform-Specific Guidance

**Android** (uses `adb.sh` helpers):
- **Prefer compound functions:** Use `adb_tap_text` over manual XML→parse→tap. Use `adb_wait_for_text` over hardcoded `sleep`. Use `adb_tap_and_wait` for screen transitions.
- **XML-first interaction (mandatory):** All compound functions use XML internally. Only fall back to manual `adb_get_screen_xml` + `adb_tap X Y` when elements lack unique text (use coordinates).
- **Zero-bounds elements:** Some frameworks (e.g., Jetpack Compose) report `bounds="[0,0][0,0]"` for child Text elements while the parent clickable View has real bounds. `adb_tap_text` automatically detects this and falls back to the nearest clickable parent. If fallback also fails, use `adb_tap X Y` with coordinates from the parent element in the XML dump.
- **Drag-and-drop limitations:** Compose `detectDragGestures` does not respond reliably to `adb shell input swipe`. For sorting/reorder interactions, prefer exhausting attempts (trial-and-error) or skip and document as "unsupported automation." This is a framework limitation, not an app defect.
- **Airplane mode on non-rooted devices:** `adb_toggle_airplane_mode` falls back to `svc wifi/data disable` if the broadcast is denied (common on Samsung Android 12+). This may disrupt ADB connections over WiFi. Test manually via Quick Settings if the fallback causes issues.
- Primitive actions (when compound won't work): `adb_tap`, `adb_swipe`, `adb_input_text`, `adb_press_back`
- Crash detection: `pidof` returns empty → capture `adb logcat -d -t 50`
- Recovery: `adb_launch_app` to restart after crash

**Web** (uses Playwright MCP tools):
- Prefer `browser_snapshot` (accessibility tree, cheap) for element discovery and state verification
- Use `browser_take_screenshot` sparingly — only when visual layout matters
- Actions: `browser_click(ref)`, `browser_type(ref, text)`, `browser_select_option(ref, values)`, `browser_press_key(key)`
- Key rule: always re-snapshot after navigation or state changes — `ref` numbers are ephemeral
- Error diagnosis: `browser_console_messages`, `browser_network_requests`
- **Deployment verification:** When verifying a fix on a live site, CDN/browser caching can show stale content. Append a cache buster (`?v=timestamp`) to the URL to bypass caches. Compare `curl` output (no cache) with browser behavior to distinguish caching issues from real bugs.

**Other platforms:** Read the project's testing documentation and use whatever tools are available (simulators, CLI utilities, MCP tools). Follow the same observe → act → verify pattern.

### Error Handling

| Situation | Action |
|-----------|--------|
| Step fails verification | Record FAIL, continue to next step |
| App/page crashes | Capture logs/errors, record ERROR, restart app/page, continue next scenario |
| Device/browser disconnects | Abort, `report_finish`, save partial report |
| Unexpected dialog/modal/popup | Dismiss it, retry original action once |
| Element has zero bounds (0,0) | `adb_tap_text` auto-falls back to clickable parent; if that fails, find parent in XML dump and tap by coordinates |
| Airplane mode broadcast denied | `adb_toggle_airplane_mode` falls back to `svc wifi/data disable`; if ADB disconnects, test manually via Quick Settings |

**Circuit breaker:** If 3 consecutive scenarios end in ERROR (crash/unrecoverable), abort remaining scenarios and proceed directly to Phase 4 with partial results.

**Airplane mode cleanup:** After any test that uses `adb_toggle_airplane_mode on`, ensure `adb_toggle_airplane_mode off` is called in cleanup — even if the test fails. Network-disabled state persists across app restarts and affects all subsequent tests.

### Exploratory Observations

**A good tester reports everything they observe, not just pass/fail on predefined steps.** During execution, actively watch for:

- **UX inconsistencies** — broken layouts, unstyled pages, inconsistent behavior between similar components (e.g., header vs footer language switchers)
- **Missing features** — no back navigation from error pages, dead-end states, missing loading indicators
- **Content issues** — typos, untranslated strings, incorrect data, placeholder content left in production
- **Accessibility gaps** — missing alt text, unlabeled buttons, poor contrast, keyboard traps
- **Console errors** — JS exceptions, failed network requests, deprecation warnings

Record these as `report_add_fail` with severity tags even if they weren't in the test plan. **A test session with "all pass, zero issues" on a real product is a red flag** — it likely means observations were missed or suppressed.

**This applies even in single-issue verification mode.** When navigating to a specific screen to verify a fix, you pass through many other screens along the way. The marginal cost of noting an anomaly is near zero — you're already looking at the screen. Don't tunnel-vision on the target bug.

### State Navigation (reaching deep screens efficiently)

Verifying a bug on a deeply nested screen (e.g., the 3rd topic's sorting question) can require many steps just to get there. Minimize navigation overhead:

1. **Deep links / intents:** If the app supports deep links (e.g., `adb shell am start -d "app://screen/id"`), use them to jump directly to the target. Check project docs for available deep link schemas.
2. **Chain aggressively:** When navigating through prerequisite screens, chain multiple actions in a single `eval` call. Skip screenshots and detailed verification until you reach the target screen.
3. **Reuse cached state:** If the app caches data locally (e.g., Room database), a previously analyzed discovery may still be available — no need to re-analyze. Check the Journal/history before creating a new analysis.
4. **Use the fastest correct answer:** For quiz questions you're just navigating through, pick the obviously correct answer without deliberating. Speed matters for navigation; accuracy matters for the target test.

After all scenarios: `report_finish`

## Phase 4: REPORT

Write `<session>/report.md`:

1. **Summary table** — date, input source, duration, pass/fail/error counts, verdict
2. **Per-scenario results** — table with step, action, platform, result, screenshot link
3. **Failure analysis** per failed step — what happened, likely cause (using Phase 1 context), severity (blocker/major/minor/cosmetic), suggested fix
4. **Exploratory findings** — bugs, UX issues, or inconsistencies discovered outside the test plan. Each with severity, description, and evidence. These are separate from test case failures — they represent the tester's observational value beyond checklist execution.
5. **Environment info** — per platform: device/browser model, OS/browser version, screen/viewport size

**Verdict:**
- All pass → PASS
- Only minor/cosmetic failures → PASS WITH WARNINGS
- Any blocker/major failure or crash → FAIL

Print summary to user.

## Phase 5: REFLECT

Write `<session>/lessons-learned.md`:

- **Testing effectiveness** — what went well, what was difficult
- **Codebase improvements** — missing accessibility labels, test IDs, overlapping touch targets
- **Documentation improvements** — missing screen docs, undocumented flows, stale info
- **Skill improvements** — patterns that couldn't be handled, new action types needed

**Testability score** (1-5 each):

| Dimension | Measures |
|-----------|----------|
| Element discoverability | Accessibility labels, test IDs, unique text |
| Navigation predictability | Deterministic screen/page transitions |
| State setup complexity | Effort to reach correct app/page state |
| Error observability | Crash detection, error logs, console output quality |
| Documentation coverage | Docs describe what needs testing |

## Exit

After all phases, print a structured summary for pipeline consumption:

```
QA_RESULT: {"verdict":"PASS|FAIL|PASS_WITH_WARNINGS","tests":N,"pass":N,"fail":N,"errors":N,"blockers":N,"session":"<session_dir>"}
```

This line allows calling agents or scripts to parse the outcome without reading the full report.
