# AI Usage Bar — Omarchy Plugin 🤖📊

[![Omarchy Plugin](https://img.shields.io/badge/omarchy-plugin-blue.svg)](https://github.com/omacom/omarchy)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An old-school ASCII progress bar widget for the [Omarchy](https://github.com/omacom/omarchy) dock that tracks usage, quotas and rate limits for your installed AI providers — Claude Code, Grok, Codex, Antigravity and more — in real time.

```text
+-------------------------------------------------------------+
| Claude 5h [████████████████] 100%   4m                      |
| Grok Wk   [████████████████] 100% 1d4h                      |
+-------------------------------------------------------------+
```

![AI Usage Bar Preview](preview.png)

---

## ✨ Features

- **📺 Old-School ASCII Progress Bars**: Displays authentic terminal-style progress bars right in your Omarchy bottom dock.
- **⚡ Dual-Limit Tracking**: Track up to **2** different AI limits or providers simultaneously in a compact, two-line stacked HUD layout.
- **🔍 Auto-Discovery**: Automatically discovers and parses quota and rate-limit data from any installed Omarchy AI provider:
  - **Claude Code**: 5-hour session window, weekly 7-day quota, Fable weekly limits.
  - **Grok**: Weekly allowance, Grok Build, Grok Chat, Grok Tasks.
  - **Google Antigravity**: Thinking Models Quota, Flash Models Quota, Claude 5h Session Window.
  - **OpenAI Codex**, **Fireworks AI**, **OpenCode**, and custom agent integrations.
- **🎨 6 ASCII Styles**:
  - `blocks`: `[████████░░░░░░░░]` (Default modern blocks)
  - `shaded`: `[▓▓▓▓▓▓▓▓░░░░░░░░]` (Dithered shading)
  - `ascii`: `[=======>        ]` (Classic CLI arrow)
  - `retro`: `[########--------]` (80s BBS / Retro style)
  - `squares`: `[■■■■■■■■□□□□□□□□]` (Unicode square boxes)
  - `braille`: `[⣿⣿⣿⣿⣿⣿⣀⣀⣀⣀⣀⣀]` (High-density braille)
- **🎛️ Interactive Popup Dashboard**:
  - **Live Dock Preview**: Test and view your dock layout in real-time.
  - **Limit Selector**: Easily toggle and select which 2 limits appear in the dock.
  - **Collapsible Provider Panels**: Every limit is grouped under its provider. Click a provider header (or press `e` to fold/unfold them all) to collapse the group down to a single row showing its headline limit and how many of its limits are pinned to the dock.
  - **Arrange Each Panel**: Nudge a limit up or down with the `▲` / `▼` buttons on its row. The order is yours and is remembered (`limitOrder`), and the row you put **first becomes the provider's headline limit** — the one its header reports when the panel is folded, on both tabs. A marker down the left edge shows which row that is. Limits you never move stay in the collector's own order (busiest first), below the ones you arranged.
  - **All Providers Overview**: Detailed status cards with tokens, sessions, reset times, and raw allowance numbers — also grouped into collapsible panels.
  - **Style Customizer**: Interactive buttons to change bar styles, bar length (8 to 32 characters), and toggle labels, percentages, and reset countdowns.
- **📣 Depleted / Reset Announcements**:
  - When a limit hits 100%, a scrolling `<marquee>`-style banner announces it with a randomly picked quip (*"Ooops, tokens for Claude Code Session (5-hour) depleted!"*) over a pulsing red background.
  - When a limit rolls over into a fresh window, the same banner celebrates it with a sliding rainbow.
  - Each announcement runs for 15 seconds or until you click it; extras queue up behind it (the `✕ +N` badge shows how many).
  - While the popup is closed the **dock bar itself animates**: the ASCII bar of a depleted limit turns into a Larson scanner sweeping back and forth in pulsing red (with an occasional nudge sideways), and a limit that just reset plays a refill wave in cycling rainbow colours — all in your chosen bar style.
- **🖱️ Instant Mouse Controls**:
  - **Left Click**: Open / close full configuration dashboard.
  - **Right Click**: Instantly cycle between ASCII bar styles.
  - **Middle Click**: Force an immediate refresh from local agent state files.
- **📡 Omarchy IPC Support**: Full CLI scriptability via `omarchy-shell`.

---

## 📦 Requirements

- **Omarchy** with the Quickshell-based shell (plugin `schemaVersion` 1).
- **`python3`** on `PATH`. The collector (`collect.py`) uses only the standard library — no `pip` packages, no virtualenv.

It makes **no network requests**. Everything it shows is read from the usage JSON Omarchy's own agent integrations already write to `~/.local/state/omarchy/agents/usage/`. To keep that fresh it may run Omarchy's local updater (`~/.config/omarchy/agents/update` or `/usr/share/omarchy/bin/omarchy-agent-usage-update`) and, when the Antigravity usage plugin is installed, that plugin's own scanner — refreshing `antigravity.json` in the directory above. Providers you have not installed simply do not appear.

---

## 🚀 Installation

Install it with Omarchy's own plugin command — no cloning, no symlinks:

```bash
omarchy plugin install https://github.com/gladimdim/omarchy-ai-usage-bar.git --enable
```

(`omarchy plugin add` is the same command under its original name.)

Omarchy does the rest for you:

1. Shows the standard "plugins run unsandboxed code" warning and asks you to confirm the URL.
2. Clones the repo into `~/.config/omarchy/plugins/gladimdim.ai-limits` and validates it against the plugin manifest schema.
3. Asks which bar section to put it in — press Enter to accept the manifest default, `right`.
4. Enables it live. The widget shows up in your bar immediately; **no shell restart needed**.

### Unattended install

`--yes` skips both prompts and places the widget in the manifest's default section (`right`):

```bash
omarchy plugin install https://github.com/gladimdim/omarchy-ai-usage-bar.git --enable --yes
```

### Install now, enable later

Drop `--enable` to just add the plugin, then enable it whenever you like and choose exactly where it sits:

```bash
omarchy plugin install https://github.com/gladimdim/omarchy-ai-usage-bar.git
omarchy plugin enable gladimdim.ai-limits --section right
```

`omarchy plugin enable` also takes `--index`, `--before <widget-id>` and `--after <widget-id>` if you want it in a particular spot within that section.

### Optional: configure by hand

Everything is configurable from the popup dashboard, but you can also edit the widget's entry in `~/.config/omarchy/shell.json` directly:

```json
{
  "bar": {
    "layout": {
      "right": [
        {
          "id": "gladimdim.ai-limits",
          "barStyle": "blocks",
          "barLength": 16,
          "tracked": [
            "antigravity:thinking-models-quota",
            "claude:session-5-hour"
          ]
        }
      ]
    }
  }
}
```

If you ever need to reload the shell, use `omarchy restart shell`, **not** `omarchy refresh shell` — the latter resets `~/.config/omarchy/shell.json` to Omarchy defaults and discards your bar layout and plugin settings.

---

## 🔄 Updating

```bash
omarchy plugin update gladimdim.ai-limits
```

It fetches upstream, shows you the diff, fast-forwards the installed copy, and re-validates the manifest — rolling the update back if validation fails. Add `--yes` to skip the diff and the confirmation. Running `omarchy plugin update` with no id updates every git-managed plugin you have.

---

## 🗑️ Removal

```bash
omarchy plugin remove gladimdim.ai-limits
```

That one command does the whole job: it disables the widget (dropping it from your bar layout), deletes `~/.config/omarchy/plugins/gladimdim.ai-limits`, and rescans the shell. It asks for confirmation first; pass `--yes` to skip the prompt.

To take it out by hand instead:

```bash
omarchy plugin disable gladimdim.ai-limits
rm -rf ~/.config/omarchy/plugins/gladimdim.ai-limits
omarchy restart shell
```

The plugin's settings live inside its own entry in `~/.config/omarchy/shell.json`, which disabling removes.

The only file the collector writes outside that entry is a refreshed copy of Omarchy's own Antigravity usage cache, `~/.local/state/omarchy/agents/usage/antigravity.json`, and only when the [Antigravity usage plugin](https://github.com/jesseburlamaque/omarchy-antigravity-usage) is installed to produce it. That cache belongs to Omarchy's shared agent-usage state rather than to this plugin, so removal leaves it in place; delete it yourself if you want it gone.

---

## ⚙️ Configuration Reference

All settings can be tweaked directly in `~/.config/omarchy/shell.json` or via the interactive popup dashboard:

| Setting | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `tracked` | `array` | `["claude:session-5-hour", "grok:weekly"]` | Array of limit IDs to display in dock (up to 2). |
| `limitOrder` | `array` | `[]` | Limit IDs in the order you arranged them inside their provider panel. Only the providers you rearranged appear; unlisted limits keep the collector's order below them. A provider's **first** ID here is its headline limit. |
| `barStyle` | `string` | `"blocks"` | ASCII style: `blocks`, `shaded`, `ascii`, `retro`, `squares`, `braille`. |
| `barLength` | `integer` | `16` | Length of progress bar body in characters (8–32). |
| `showLabel` | `boolean` | `true` | Show short provider label (e.g. `Claude 5h`, `AGY Think`). |
| `showPercent` | `boolean` | `true` | Show percentage number (e.g. `92%`). |
| `showReset` | `boolean` | `true` | Show relative countdown until quota reset (e.g. `2h43m`). |
| `coloredBars` | `boolean` | `true` | Colorize progress bars using provider brand colors. |
| `refreshIntervalSec` | `integer` | `60` | Background refresh interval in seconds. |

---

## ⌨️ Omarchy IPC Commands

You can control or query the plugin from terminal, scripts, or Hyprland keybindings using `omarchy-shell`:

```bash
# Open popup dashboard
omarchy-shell gladimdim.ai-limits open

# Close popup dashboard
omarchy-shell gladimdim.ai-limits close

# Toggle popup dashboard
omarchy-shell gladimdim.ai-limits toggle

# Cycle to next ASCII progress bar style
omarchy-shell gladimdim.ai-limits nextStyle

# Force refresh data from agent logs
omarchy-shell gladimdim.ai-limits refresh

# Preview an announcement banner: depleted or reset
omarchy-shell gladimdim.ai-limits demoEvent depleted

# Get current status and active limits JSON
omarchy-shell gladimdim.ai-limits debugInfo
```

---

## 👤 Author

**Dmytro Gladkyi**
- GitHub: [@gladimdim](https://github.com/gladimdim)

## 📄 License

This project is licensed under the [MIT License](LICENSE).
