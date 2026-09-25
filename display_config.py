"""Read and update literal monitor rules without evaluating user Lua."""

from __future__ import annotations

import re
from typing import Any


FIELDS = ("output", "mode", "position", "scale", "transform", "disabled", "mirror")
TOKEN = re.compile(r'--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_][\w]*|\s+|.', re.S)


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
        call = tokens[i:i + 8]
        if len(call) != 8 or call[5][0] != "," or call[7][0] != ")" or not re.fullmatch(r'"[1-9][0-9]*"|\'[1-9][0-9]*\'', call[6][0]):
            raise ValueError("GTK scale must be a whole-number string in monitors.lua")
        found.append((int(call[6][0][1:-1]), (call[6][1], call[6][2])))
    if len(found) > 1:
        raise ValueError("Remove duplicate GDK_SCALE settings from monitors.lua")
    return found[0] if found else (1, None)


def update_gtk_scale(source: str, scale: int) -> str:
    if type(scale) is not int or not 1 <= scale <= 4:
        raise ValueError("GTK scale must be 1, 2, 3, or 4")
    _, span = gtk_scale_setting(source)
    if span:
        return source[:span[0]] + lua_string(str(scale)) + source[span[1]:]
    return source.rstrip() + '\nhl.env("GDK_SCALE", ' + lua_string(str(scale)) + ')\n'


def lua_string(value: str) -> str:
    # JSON and Lua share these escapes; encode controls using Lua decimal escapes.
    return '"' + ''.join('\\' + c if c in '\\"' else f'\\{ord(c):03d}' if ord(c) < 32 else c for c in value) + '"'


def selector(monitor: dict[str, Any]) -> str:
    return monitor["selector"]


def rule_fields(monitor: dict[str, Any], persistent: bool = False, monitors: list | None = None) -> dict[str, str]:
    mirror = monitor["mirrorOf"]
    if persistent and mirror and monitors:
        target = next((m for m in monitors if m["name"] == mirror), None)
        if target:
            mirror = selector(target)
    return {
        "output": lua_string(selector(monitor) if persistent else monitor["name"]),
        "mode": lua_string(f'{monitor["width"]}x{monitor["height"]}@{monitor["refreshRate"]:.5f}'),
        "position": lua_string(f'{monitor["x"]}x{monitor["y"]}'),
        "scale": format(monitor["scale"], ".10g"),
        "transform": str(monitor["transform"]),
        "disabled": "true" if monitor["disabled"] else "false",
        "mirror": lua_string(mirror),
    }


def monitor_rule(monitor: dict[str, Any]) -> str:
    return "hl.monitor({ " + ", ".join(f"{k} = {v}" for k, v in rule_fields(monitor).items()) + " })"


def update_config(source: str, monitors: list[dict[str, Any]], all_monitors: list[dict[str, Any]] | None = None) -> str:
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
            values = rule_fields(monitor, True, all_monitors or monitors)
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
            values = rule_fields(monitor, True, all_monitors or monitors)
            additions.append("hl.monitor({ " + ", ".join(f"{k} = {v}" for k, v in values.items()) + " })")
    if additions:
        source = source.rstrip() + "\n" + "\n".join(additions) + "\n"
    return source
