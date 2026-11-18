# Key Promoter

Shows the keyboard shortcut whenever you open something through the Omarchy
menu, the app launcher, or the dock that already has a keybinding. The toast
stays for 15 seconds, or until you click it or its close button.

Based on Forrest Knight's [omarchy-key-promoter](https://github.com/ForrestKnight/omarchy-key-promoter) (MIT), with these fixes for Omarchy 4.5:

- Lua bindings (`hl.dsp.global("omarchy:panel.…")`), so Emojis and Clipboard are recognized.
- The default browser is resolved through `omarchy-cmd-default-browser`, so `omarchy-browser.desktop` becomes the real browser.
- `omarchy-launch-editor`, `omarchy-launch-<app>` wrappers, and alternative chords (`A / B`) are handled.
- Dock and launcher-grid launches count, not only the menu.

## Install

```bash
omarchy plugin add https://github.com/Daferia/omarchy-key-promoter.git --enable
```

## Settings

These go inline on the plugin's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "daferia.key-promoter", "duration": 15000, "position": "bottom-right", "showCount": true }
```

## IPC

```bash
omarchy-shell key-promoter show "SUPER + B" "Browser"   # preview
omarchy-shell key-promoter state                         # last detection, armed, watcher
omarchy-shell key-promoter resolved                      # binds it can match
```
