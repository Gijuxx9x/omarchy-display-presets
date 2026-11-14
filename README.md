# Display Preset.9x

One click puts your apps on the right screens. A preset says which apps go on
which monitor. Applying it **reuses the matching windows that are already
open** (moving them where they belong) and **launches only what is missing**,
so pressing the same preset twice changes nothing.

An Omarchy bar widget with a panel, plus a small Python helper (`presetctl`)
that does the window work through `hyprctl`.

## Install

```sh
omarchy plugin add <repository-url> --enable
```

Then add the **Display Preset.9x** widget to your bar from the bar settings
(category *Compositor*), or open the panel from a keybinding (see below).

To remove it: `omarchy plugin remove gijux9x.presets`.

## Requirements

- Omarchy 4 (the Lua-configured Hyprland). The plugin sends Lua to Hyprland with
  `hyprctl eval` and `hyprctl dispatch`, so older Omarchy versions will not work.
- `python3` and `hyprctl`. Nothing else is installed: `presetctl` uses only the
  Python standard library.
- Optional: `omarchy-hyprland-workspace-layout-current`, `omarchy-shell` and
  `omarchy-notification-send` (falls back to `notify-send`) are used when present.

## What it does and what it touches

Plugins run unsandboxed with your permissions, so here is exactly what this one does:

- **Launches the commands you put in a preset** (the `exec` field of each app).
  It never launches anything you did not write or capture yourself.
- **Moves windows** between workspaces and, when asked to, minimizes the other
  windows (they are tagged so *Bring back windows* can restore them).
- **Reads and writes one file:** `~/.config/omarchy-presets/presets.json`
  (a `.bak` copy is kept on delete). Override the location with `PRESETCTL_CONFIG`.
- No network access, no `sudo`, no downloads, no background service.

## Using it

Open the panel from the bar. Each card is a preset.

| Key | Action |
| --- | --- |
| `Enter` | apply the selected preset |
| `1`–`9` | apply that preset directly (works on AZERTY too) |
| `N` or `+` | save the current layout as a new preset |
| `M` | edit the selected preset |
| `R` | rename it (its id stays the same, so keybindings keep working) |
| `E` | open `presets.json` in your editor |
| `X` | delete (press twice to confirm) |
| `Ctrl+↑` / `Ctrl+↓` | change the order |

**New → Capture** saves the windows currently visible on each screen.
**New → Empty** creates an empty preset you fill in with the editor.

### Keybindings

The panel can be driven from the shell, so you can bind it in
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + P", "Display Preset.9x", "omarchy-shell gijux9x.presets toggle")
o.bind("SUPER + ALT + 1", "Preset: work",    "presetctl apply work --notify")
```

IPC target `gijux9x.presets`: `open`, `close`, `toggle`, `refresh`,
`apply <id>`, `capture`, `edit <id>`.
For `presetctl` in a keybinding, use the full path to the script or put it on
your `PATH`.

## The `presetctl` command

```
presetctl list [--json]          presets, screens, and what is open now
presetctl apply <id> [--dry-run] [--json] [--notify]
presetctl capture [--name NAME]  save the current layout as a new preset
presetctl new [--name NAME]      create an empty preset
presetctl delete <id>
presetctl rename <id> <name>
presetctl move <id> <+1|-1>
presetctl show <id> --json       a preset as the editor sees it
presetctl save <id> --data JSON  write what the editor changed
presetctl restore-hidden         bring back windows a preset minimized
presetctl monitors               how screen names resolve on this machine
presetctl path                   print the presets file path
```

`apply <id> --dry-run` prints what would happen without touching any window.
`<id>` can be the id, the name or the number of the preset.

## The presets file

```json
{
  "version": 1,
  "presets": [
    {
      "id": "work",
      "name": "Work",
      "description": "Browser on the left, editor in the middle, terminals on the right",
      "focus": "middle",
      "screens": {
        "left":   { "apps": [ { "name": "Browser",  "exec": "omarchy-launch-browser" } ] },
        "middle": { "apps": [ { "name": "Editor",   "exec": "omarchy-launch-editor" } ] },
        "right":  { "apps": [ { "name": "Terminal", "exec": "foot" } ] }
      }
    }
  ]
}
```

A screen key can be:

- a position: `left`, `middle` (or `center`), `right`. French aliases
  (`gauche`, `milieu`, `centre`, `droite`) also work;
- a number: `1`, `2`, … counted from the left;
- a connector name such as `DP-1` or `HDMI-A-1`;
- `desc:<text>`, or a word from the monitor model (for example `Legion`).

Run `presetctl monitors` to see how these keys resolve on your machine.

An app takes:

| Field | Meaning |
| --- | --- |
| `name` | label shown in the panel |
| `exec` | command to launch when no matching window is open |
| `class` | optional regex for the window class. By default it is derived from `exec` |
| `title` | optional regex for the window title |
| `icon` | optional icon name |
| `count` | optional, how many windows (up to 12) |

Other preset fields: `focus` (which screen ends up focused) and `others`
(`keep` or `minimize` the windows that are not part of the preset). A screen can
also set `workspace` and `layout` (`dwindle`, `scrolling` or `floating`).

### Free layout

By default Hyprland tiles the apps of a screen as it sees fit. To pin every
window to a place, give the screen `tiles` instead of `apps`: a tree of splits,
each with `split` (`right` or `down`, where side `b` goes relative to side `a`),
an optional `ratio` (0.1 to 0.9) and two sides `a` and `b`, each either another
split or an app.

```json
"right": {
  "tiles": {
    "split": "right",
    "ratio": 0.5,
    "a": { "name": "Terminal", "exec": "foot" },
    "b": {
      "split": "down",
      "a": { "name": "Terminal", "exec": "foot" },
      "b": { "name": "Terminal", "exec": "foot" }
    }
  }
}
```

Limits: 16 tiles and 10 levels of nesting per screen. The editor can switch a
screen to this layout for you.

## Languages

English and French. Add `i18n/<code>.json` (copy `en.json`) to translate the
panel.

## Known limits

- Tested on one machine with three monitors. Single-screen and laptop setups
  are expected to work but have had less testing.
- An open window is matched by its class (derived from `exec`, or your `class`
  regex), so apps whose window class differs from their command name need a
  `class` regex.

## License

MIT. See [LICENSE](LICENSE).
