# Foamy Monitor

Display arrangement, monitor controls, and wireless casting.

![Foamy Monitor screenshot](preview.png)

## Install

Requires Omarchy Quattro, Hyprland, Python 3, and `gsettings` for desktop
appearance settings.

For wireless casting, install FluxCast (`fluxcast-git`) and FFmpeg (`ffmpeg`).

```sh
omarchy plugin add https://github.com/foamrider/foamy-monitor.git --enable
```

Use one display-control plugin at a time; disable any previous local replacement.

## Use

- Left-click the widget to open display controls. Select a display or drag it into position.
- Use **Display** for resolution, refresh rate, scale, orientation, and brightness.
- Use **Advanced** for text size, cursor size, and GTK scale.
- Use **Wireless** to find a receiver and cast the selected display.
- Open the cog to change language. Plugin preferences are stored in `shell.json`.

**Save** starts a 15-second trial. Choose **Keep settings** to save, or **Revert**
to restore the previous configuration. The trial also reverts if it times out.
Brightness, text size, and cursor size apply immediately.

Saving GTK scale updates `GDK_SCALE` in the Hyprland and D-Bus/systemd user
environments. The plugin uses `systemctl --user show-environment` to preserve
the previous value and `systemctl --user unset-environment GDK_SCALE` when a
rollback must restore an unset value. These operations affect the user session;
they do not manage system services or require administrator privileges.

## Remove

Finish or revert any active display trial and stop wireless casting first.

```sh
omarchy plugin remove foamy.monitor
```

When removing an enabled replacement, Omarchy restores
`omarchy.monitor`. Saved display layouts, brightness, font size, cursor size,
and GTK scale remain as last configured; removal does not roll them back.
FluxCast and FFmpeg remain installed.

Omarchy manages the plugin entry in `shell.json`. Packages and data outside
the plugin directory are retained unless you remove them separately.

## License

Licensed under [MIT](LICENSE), with [Monitor Settings Extender](LICENSE-MONITOR-SETTINGS-EXTENDER),
[Omarchy](LICENSE-OMARCHY), and [Lucide](LICENSE-LUCIDE) notices.

Provided **as is**, without warranty or guaranteed support. Use at your own risk.
