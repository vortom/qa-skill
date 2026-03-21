# qa-skill

Generic QA testing plugin for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Runs autonomous end-to-end testing on any platform your project supports — Android, Web, iOS, desktop, etc.

## What it does

The skill discovers your project's platforms, reads your docs (CLAUDE.md, README), builds a test plan, then executes it using platform-appropriate tools:

- **Android** — ADB + UI Automator XML for element discovery and interaction
- **Web** — Playwright MCP for browser automation
- **iOS** — Simulator/device interaction (planned)
- **Desktop** — CLI/GUI testing (planned)

It produces JUnit XML reports, screenshots, and a lessons-learned analysis.

## Install

### Via Claude Code plugin marketplace (recommended)

```bash
# Add the marketplace
/plugin marketplace add vortom/qa-skill

# Install the plugin
/plugin install qa-test@qa-skill
```

### Manual installation

Clone or symlink into your project's `.claude/skills/` directory:

```bash
git clone https://github.com/vortom/qa-skill.git .claude/skills/qa-test
```

### Permission setup (recommended)

Add to `.claude/settings.local.json` to auto-approve QA runner commands:

```json
{
  "permissions": {
    "allow": [
      "Bash(/tmp/qa *)"
    ]
  }
}
```

This avoids repetitive permission prompts during test execution. The `/tmp/qa` symlink only exists during active QA sessions.

## Usage

In Claude Code:

```
# Test a PR
/qa-test --pr 123

# Test from a GitHub issue with test cases
/qa-test --issue 145

# Exploratory testing
/qa-test "test the login flow"

# Interactive (asks what to test)
/qa-test
```

## How it works

The skill runs in 5 phases:

| Phase | What happens |
|-------|-------------|
| **0. Setup** | Creates session directory, detects platforms, verifies prerequisites |
| **1. Discover** | Reads project docs, finds platform details (packages, URLs, routes) |
| **2. Plan** | Generates test scenarios from PR diff, issue, or description |
| **3. Execute** | Runs tests with observe → act → verify → record pattern |
| **4. Report** | Writes JUnit XML + markdown report with verdict |
| **5. Reflect** | Lessons learned + testability score |

## Android helpers

The plugin includes `scripts/adb.sh` with compound functions that reduce tool calls from 3-4 to 1:

| Function | Purpose |
|----------|---------|
| `adb_tap_text "Button"` | Find element by text in XML + tap its center |
| `adb_wait_for_text "Ready" 10` | Poll until text appears (with timeout) |
| `adb_tap_and_wait "Next" "Step 2"` | Tap + wait for screen transition |
| `adb_assert_text "Welcome"` | Assert text exists on screen |
| `adb_list_texts` | List all visible text elements |
| `adb_screen_state "shot.png"` | Screenshot + XML dump in one call |

Plus primitives: `adb_tap`, `adb_swipe`, `adb_input_text`, `adb_press_back`, `adb_screenshot`, etc.

## Plugin structure

```
qa-skill/
├── .claude-plugin/
│   └── plugin.json        # Plugin manifest
├── skills/
│   └── qa-test/
│       └── SKILL.md       # Skill definition
├── scripts/
│   ├── adb.sh             # Android platform helpers
│   └── report.sh          # JUnit XML report generation
├── README.md
└── LICENSE
```

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- **Android testing:** ADB installed, device/emulator connected
- **Web testing:** Playwright MCP server configured
- **macOS note:** Uses `sed`/`awk` (not `grep -P`) for portability. Screenshot resize uses `sips` (macOS) or `convert` (ImageMagick).

## License

MIT
