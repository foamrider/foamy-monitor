# Foamy Monitor

Display arrangement, monitor controls, and FluxCast wireless casting for
Omarchy Quattro. Plugin ID: `foamy.monitor`.

![Foamy Monitor](screenshot.png)

## Local installation

From this checkout:

```sh
ln -s "$PWD" "$HOME/.config/omarchy/plugins/foamy.monitor"
omarchy plugin enable foamy.monitor
omarchy restart shell
```

Use one display-control plugin at a time. When replacing a local monitor plugin,
disable its bar entry separately. This checkout does not modify or remove it.

Requires Omarchy Quattro, Quickshell, Hyprland, and Python 3. Brightness uses
Omarchy's display-brightness helper. Wireless discovery requires FluxCast;
desktop casting also requires FFmpeg. Missing dependencies appear in the panel.

## Use

- Open the monitor icon. Select a display in the arrangement diagram, then drag
  it into position. Edges and centers snap; arrow keys move by one logical pixel
  and Shift+arrow moves by ten. Enter or Space selects a focused display.
- **Identify** labels the physical outputs. Disabled, mirrored, and disconnected
  drafts remain selectable below the diagram.
- **Display** contains resolution, refresh rate, scale, orientation, brightness,
  enable/disable, and extend/mirror controls.
- **Advanced** contains system text size, cursor size, and GTK scale.
- **Wireless** discovers receivers, casts the selected output, and stops casting.
- The top-right cog opens **Plugin settings**. Language is **System**, **English**,
  or **Norsk bokmål**. System follows the locale, with English as the fallback.

Plugin preferences use the Omarchy manifest schema and the shell's
`setBarWidget` writer. Language is stored in the `foamy.monitor` bar entry in
`~/.config/omarchy/shell.json`, saves immediately, and does not apply or discard
pending display changes. There is no separate preferences file.

## Display changes

Resolution, refresh rate, scale, orientation, arrangement, mirroring, enabled
state, and GTK scale are staged. **Save** starts a 15-second trial. **Keep
settings** writes the machine-local `~/.config/hypr/monitors.lua`; **Revert** or
the timeout restores the earlier layout and GTK launch environment. Brightness,
system text size, and cursor size apply immediately.

A detached worker owns each trial. Closing the panel or restarting Quickshell
does not cancel rollback. Its private state is scoped to the Hyprland session
under `$XDG_RUNTIME_DIR/foamy-monitor-*`. Invalid modes, overlapping outputs,
disabling the last usable output, and conflicting external changes are rejected.
Monitor configuration updates preserve unrelated rules, comments, and values.
Dynamic or duplicate rules are rejected rather than guessed. GTK scale affects
new X11/XWayland GTK processes; reopen apps after keeping a change.

Keyboard: Tab moves through controls; Ctrl+S saves; W opens Wireless. In Wireless,
j/k or arrows select receivers and Enter casts. Escape closes a dropdown, reverts
an active trial, returns from plugin settings, or closes the panel, in that order.
The settings view preserves drafts and keeps trial controls visible.

IPC uses the `foamy.monitor` target, including `open`, `close`, `toggle`, `settings`,
`state`, `brightness`, `scanWireless`, and `stopWireless`.

## Validation

```sh
node --test tests/*.test.js
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
omarchy plugin validate .
```

The Python tests use isolated compositor and session-environment doubles,
including the real detached worker, timeout rollback, external edits, and GTK
scale handling. They do not change the running desktop. Use the Qt 6 `qmlformat`
for QML syntax checks; Qt 5 cannot parse the inline components.

## License

[MIT](LICENSE). Based on Monitor Settings Extender revision
`4fc6e55e6e87004cf808aad71bf263a79e1c0c80`, the local display transaction
integration, and shared Foamy presentation components. Retained notices:
[Monitor Settings Extender](LICENSE-MONITOR-SETTINGS-EXTENDER),
[Omarchy](LICENSE-OMARCHY), and [Lucide](LICENSE-LUCIDE).
