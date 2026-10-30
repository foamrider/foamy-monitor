"""Read and update literal monitor rules without evaluating user Lua."""

from __future__ import annotations

import re
from typing import Any


FIELDS = ("output", "mode", "position", "scale", "transform", "disabled", "mirror")
TOKEN = re.compile(r'--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_][\w]*|\s+|.', re.S)


def gtk_scale_local(source: str, tokens: list[tuple[str, int, int]], reference: int) -> tuple[int, tuple[int, int]]:
    name = tokens[reference][0]
    uses = [i for i, token in enumerate(tokens) if token[0] == name]
    error = "GTK scale must use a standalone local whole number without reassignments or other uses in monitors.lua"
    # Only resolve a single-purpose local constant; never evaluate arbitrary Lua.
    if len(uses) != 2 or uses[1] != reference or any(t[0] in ("do", "end") for t in tokens):
        raise ValueError(error)
    declaration = uses[0]
    if declaration == 0 or tokens[declaration - 1][0] != "local":
        raise ValueError(error)
    start = source.rfind("\n", 0, tokens[declaration - 1][1]) + 1
    end = source.find("\n", start)
    end = len(source) if end == -1 else end
    match = re.fullmatch(r'\s*local\s+' + re.escape(name) + r'\s*=\s*([1-9][0-9]*)\s*;?\s*(?:--[^\n]*)?', source[start:end])
    if not match:
        raise ValueError(error)
    span = (start + match.start(1), start + match.end(1))
    following = next((t[0] for t in tokens if t[1] >= span[1]), None)
    if following in ("+", "-", "*", "/", "%", "^", ".", "&", "|", "~", "<", ">", "=", "and", "or"):
        raise ValueError(error)
    return int(match[1]), span


def gtk_scale_setting(source: str) -> tuple[int, tuple[int, int] | None]:
    tokens = [(m.group(), m.start(), m.end()) for m in TOKEN.finditer(source)
              if not m.group().isspace() and not m.group().startswith("--")]
    found = []
    for i in range(len(tokens) - 4):
        if [t[0] for t in tokens[i:i + 4]] != ["hl", ".", "env", "("] or tokens[i + 4][0] not in ('"GDK_SCALE"', "'GDK_SCALE'"):
            continue
        prefix = source[source.rfind("\n", 0, tokens[i][1]) + 1:tokens[i][1]]
        if prefix.strip() or any(t[0] in ("if", "for", "while", "repeat", "function") for t in tokens):
            raise ValueError("GTK scale must be a standalone hl.env call in monitors.lua")
        call = tokens[i:i + 11]
        if len(call) >= 8 and call[5][0] == "," and call[7][0] == ")" and re.fullmatch(r'"[1-9][0-9]*"|\'[1-9][0-9]*\'', call[6][0]):
            found.append((int(call[6][0][1:-1]), (call[6][1], call[6][2])))
        elif len(call) == 11 and [t[0] for t in call[5:8]] == [",", "tostring", "("] and [t[0] for t in call[9:]] == [")", ")"] and re.fullmatch(r'[A-Za-z_]\w*', call[8][0]):
            if sum(t[0] == "tostring" for t in tokens) != 1:
                raise ValueError("GTK scale requires the unmodified tostring function in monitors.lua")
            found.append(gtk_scale_local(source, tokens, i + 8))
        else:
            raise ValueError("GTK scale must be a whole-number string or tostring of a local whole number in monitors.lua")
    if len(found) > 1:
        raise ValueError("Remove duplicate GDK_SCALE settings from monitors.lua")
    return found[0] if found else (1, None)


def update_gtk_scale(source: str, scale: int) -> str:
    if type(scale) is not int or not 1 <= scale <= 4:
        raise ValueError("GTK scale must be 1, 2, 3, or 4")
    _, span = gtk_scale_setting(source)
    if span:
        # Preserve Omarchy's numeric local declaration and its tostring call.
        value = lua_string(str(scale)) if source[span[0]] in ('"', "'") else str(scale)
        return source[:span[0]] + value + source[span[1]:]
    return source.rstrip() + '\nhl.env("GDK_SCALE", ' + lua_string(str(scale)) + ')\n'


def lua_string(value: str) -> str:
    # JSON and Lua share these escapes; encode controls using Lua decimal escapes.
    return '"' + ''.join('\\' + c if c in '\\"' else f'\\{ord(c):03d}' if ord(c) < 32 else c for c in value) + '"'


INTERNAL = re.compile(r"^(eDP|LVDS|DSI)-")
SCALE_LOCAL = "omarchy_monitor_scale"


def selector(monitor: dict[str, Any]) -> str:
    """The output a saved rule names.

    External displays are saved by EDID description (stable across docks and
    ports). Built-in panels keep their connector name: Omarchy's clamshell
    script (omarchy-hyprland-monitor-clamshell) looks up the internal panel's
    rule by `output = "<connector>"` to restore its scale and position.
    """
    if INTERNAL.match(str(monitor.get("name", ""))):
        return monitor["name"]
    return monitor["selector"]


def monitor_scale_local(source: str) -> tuple[bool, float | None]:
    """Whether Omarchy's scale knob drives the catch-all rule, and its number.

    omarchy-hyprland-monitor-scaling persists a scale by rewriting the line
    `local omarchy_monitor_scale = …`. Rules that name the local keep following
    it; a literal scale would silently pin that display.
    """
    code = re.sub(r"--[^\n]*", "", source)
    declarations = re.findall(r'(?m)^[ \t]*local[ \t]+' + SCALE_LOCAL + r'[ \t]*=[ \t]*("[^"\n]*"|[0-9.]+)[ \t]*;?[ \t]*$', code)
    reassigned = re.search(r'(?m)^(?![ \t]*local\b).*\b' + SCALE_LOCAL + r'[ \t]*=(?!=)', code)
    catch_all = re.search(r'hl\.monitor\(\{[^\n]*output\s*=\s*""[^\n]*\bscale\s*=\s*' + SCALE_LOCAL + r'\b', code)
    if len(declarations) != 1 or reassigned or not catch_all:
        return False, None
    value = declarations[0]
    try:
        return True, None if value.startswith('"') else float(value)
    except ValueError:
        return False, None


def rule_fields(monitor: dict[str, Any], persistent: bool = False, monitors: list | None = None,
                scale_local: bool = False) -> dict[str, str]:
    mirror = monitor["mirrorOf"]
    if persistent and mirror and monitors:
        target = next((m for m in monitors if m["name"] == mirror), None)
        if target:
            mirror = selector(target)
    return {
        "output": lua_string(selector(monitor) if persistent else monitor["name"]),
        "mode": lua_string(f'{monitor["width"]}x{monitor["height"]}@{monitor["refreshRate"]:.5f}'),
        "position": lua_string(f'{monitor["x"]}x{monitor["y"]}'),
        "scale": SCALE_LOCAL if scale_local else format(monitor["scale"], ".10g"),
        "transform": str(monitor["transform"]),
        "disabled": "true" if monitor["disabled"] else "false",
        "mirror": lua_string(mirror),
    }


def monitor_rule(monitor: dict[str, Any]) -> str:
    return "hl.monitor({ " + ", ".join(f"{k} = {v}" for k, v in rule_fields(monitor).items()) + " })"


def update_config(source: str, monitors: list[dict[str, Any]], all_monitors: list[dict[str, Any]] | None = None,
                  base: list[dict[str, Any]] | None = None) -> str:
    has_local, local_scale = monitor_scale_local(source)
    base_by_id = {m["id"]: m for m in base or []}

    def follows_local(monitor: dict[str, Any], existing: str | None) -> bool:
        # Keep a display on Omarchy's scale knob unless this save changes its scale.
        if not has_local:
            return False
        if local_scale is not None and abs(monitor["scale"] - local_scale) < 0.00001:
            return True
        before = base_by_id.get(monitor["id"])
        unchanged = before is not None and abs(before["scale"] - monitor["scale"]) < 0.00001
        return unchanged and (existing is None or existing.strip() == SCALE_LOCAL)

    tokens = [(m.group(), m.start(), m.end()) for m in TOKEN.finditer(source)
              if not m.group().isspace() and not m.group().startswith("--")]
    if any(t[0] in ("if", "for", "while", "repeat", "function") for t in tokens):
        raise ValueError("Conditional monitor configuration must be edited in monitors.lua")
    replacements: list[tuple[int, int, str]] = []
    found: set[str] = set()
    i = 0
    while i < len(tokens):
        if [t[0] for t in tokens[i:i + 5]] != ["hl", ".", "monitor", "(", "{"]:
            if [t[0] for t in tokens[i:i + 3]] == ["hl", ".", "monitor"]:
                raise ValueError("Use literal hl.monitor({...}) rules in monitors.lua before saving")
            i += 1
            continue
        start = i
        i += 5
        depth = 0
        fields: dict[str, tuple[int, int]] = {}
        while i < len(tokens) and not (tokens[i][0] == "}" and depth == 0):
            if depth == 0 and i + 2 < len(tokens) and tokens[i + 1][0] == "=":
                key = tokens[i][0]
                value_start = i + 2
                i = value_start
                while i < len(tokens):
                    t = tokens[i][0]
                    if depth == 0 and t in (",", ";", "}"):
                        break
                    if t in ("{", "(", "["):
                        depth += 1
                    elif t in ("}", ")", "]"):
                        depth -= 1
                    i += 1
                if i > value_start:
                    if key in fields:
                        raise ValueError("Duplicate monitor field; simplify monitors.lua before saving")
                    fields[key] = (tokens[value_start][1], tokens[i - 1][2])
            else:
                i += 1
            if i < len(tokens) and tokens[i][0] in (",", ";"):
                i += 1
        if i + 1 >= len(tokens) or tokens[i + 1][0] != ")":
            raise ValueError("Cannot update this monitor rule in monitors.lua")
        output_span = fields.get("output")
        if output_span is None:
            raise ValueError("Monitor output must be a literal string in monitors.lua")
        literal = source[slice(*output_span)]
        if not re.fullmatch(r'"[^"\\]*"|\'[^\'\\]*\'', literal):
            raise ValueError("Monitor output must be a literal string in monitors.lua")
        output = literal[1:-1]
        matching = [m for m in (all_monitors or monitors) if output == m["name"] or
                    (output.startswith("desc:") and m["description"].startswith(output[5:]))]
        edited_ids = {m["id"] for m in monitors}
        if len(matching) > 1 and any(m["id"] in edited_ids for m in matching):
            raise ValueError("A monitor description matches multiple displays; use a unique description")
        matching = [m for m in matching if m["id"] in edited_ids]
        if matching:
            monitor = matching[0]
            if monitor["id"] in found:
                raise ValueError(f'Duplicate rules for {monitor["name"]}; remove the duplicate before saving')
            # Reject conditional/inline calls rather than silently changing their scope.
            prefix = source[source.rfind("\n", 0, tokens[start][1]) + 1:tokens[start][1]]
            if prefix.strip():
                raise ValueError("Monitor rules must be standalone calls in monitors.lua")
            existing_scale = source[slice(*fields["scale"])] if "scale" in fields else None
            values = rule_fields(monitor, True, all_monitors or monitors, follows_local(monitor, existing_scale))
            for key, value in values.items():
                if key in fields:
                    a, b = fields[key]
                    replacements.append((a, b, value))
            missing = [f"{key} = {value}" for key, value in values.items() if key not in fields]
            if missing:
                before = tokens[i - 1][0]
                replacements.append((tokens[i][1], tokens[i][1],
                                     ("" if before in (",", ";", "{") else ", ") + ", ".join(missing) + " "))
            found.add(monitor["id"])
        i += 2
    for a, b, value in sorted(replacements, reverse=True):
        source = source[:a] + value + source[b:]
    additions = []
    for monitor in monitors:
        if monitor["id"] not in found:
            values = rule_fields(monitor, True, all_monitors or monitors, follows_local(monitor, None))
            additions.append("hl.monitor({ " + ", ".join(f"{k} = {v}" for k, v in values.items()) + " })")
    if additions:
        source = source.rstrip() + "\n" + "\n".join(additions) + "\n"
    return source
