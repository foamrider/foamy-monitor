//! Reads and updates literal monitor rules in `monitors.lua` without
//! evaluating user Lua (formerly `display_config.py`). The source is split
//! into tokens with the old helper's tokenizer, and only literal
//! `hl.monitor({ … })` calls and the one `hl.env("GDK_SCALE", …)` setting
//! are read or rewritten; anything conditional, computed or ambiguous is
//! refused with the same messages.

use std::collections::HashSet;
use std::fmt::Write as _;

use serde_json::{Map, Value};

use crate::py;

const CONTROL: [&str; 5] = ["if", "for", "while", "repeat", "function"];
const SCALE_LOCAL: &str = "omarchy_monitor_scale";
const GTK_LOCAL_ERROR: &str = "GTK scale must use a standalone local whole number without reassignments or other uses in monitors.lua";

/// A token: its text and byte span in the source.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Token<'a> {
    pub text: &'a str,
    pub start: usize,
    pub end: usize,
}

/// End of a long bracket `[==[ … ]==]` opened at `at` (a `[`), if closed.
fn long_bracket(source: &str, at: usize) -> Option<usize> {
    let bytes = source.as_bytes();
    let mut i = at + 1;
    while bytes.get(i) == Some(&b'=') {
        i += 1;
    }
    if bytes.get(i) != Some(&b'[') {
        return None;
    }
    let close = format!("]{}]", "=".repeat(i - at - 1));
    source[i + 1..]
        .find(&close)
        .map(|found| i + 1 + found + close.len())
}

/// End of a quoted string opened at `at`, if closed (a backslash escapes
/// any character, newlines included).
fn quoted(source: &str, at: usize, quote: char) -> Option<usize> {
    let mut chars = source[at + 1..].char_indices();
    while let Some((i, c)) = chars.next() {
        if c == '\\' {
            chars.next()?;
        } else if c == quote {
            return Some(at + 1 + i + 1);
        }
    }
    None
}

/// Every token, whitespace and comments included: long comments, line
/// comments, long strings, quoted strings, identifiers, whitespace runs,
/// then any single character (the old pattern's alternatives, in order).
pub fn tokenize(source: &str) -> Vec<Token<'_>> {
    let mut tokens = Vec::new();
    let mut at = 0;
    while at < source.len() {
        let rest = &source[at..];
        let c = rest.chars().next().unwrap_or('\0');
        let end = if rest.starts_with("--") {
            let block = if rest.starts_with("--[") {
                long_bracket(source, at + 2)
            } else {
                None
            };
            block.unwrap_or_else(|| at + rest.find('\n').unwrap_or(rest.len()))
        } else if let Some(end) = (c == '[').then(|| long_bracket(source, at)).flatten() {
            end
        } else if let Some(end) = (c == '"' || c == '\'')
            .then(|| quoted(source, at, c))
            .flatten()
        {
            end
        } else if c.is_ascii_alphabetic() || c == '_' {
            at + c.len_utf8()
                + rest[c.len_utf8()..]
                    .find(|c: char| !py::is_word(c))
                    .unwrap_or(rest.len() - c.len_utf8())
        } else if py::is_space(c) {
            at + rest.find(|c: char| !py::is_space(c)).unwrap_or(rest.len())
        } else {
            at + c.len_utf8()
        };
        tokens.push(Token {
            text: &source[at..end],
            start: at,
            end,
        });
        at = end;
    }
    tokens
}

/// The tokens that are neither whitespace nor comments.
pub fn code_tokens(source: &str) -> Vec<Token<'_>> {
    tokenize(source)
        .into_iter()
        .filter(|t| !t.text.starts_with("--") && !t.text.chars().all(py::is_space))
        .collect()
}

fn line_start(source: &str, at: usize) -> usize {
    source[..at].rfind('\n').map_or(0, |i| i + 1)
}

fn whole_number_string(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() >= 3
        && (bytes[0] == b'"' || bytes[0] == b'\'')
        && bytes[bytes.len() - 1] == bytes[0]
        && (b'1'..=b'9').contains(&bytes[1])
        && bytes[2..bytes.len() - 1].iter().all(u8::is_ascii_digit)
}

fn identifier(text: &str) -> bool {
    let mut chars = text.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(py::is_word)
}

fn whole_number(digits: &str) -> Result<u64, String> {
    // A value beyond u64 is no GTK scale anyone sets; refuse it.
    digits.parse().map_err(|_| {
        "GTK scale must be a whole-number string or tostring of a local whole number in monitors.lua".to_owned()
    })
}

/// `^\s*local\s+NAME\s*=\s*([1-9][0-9]*)\s*;?\s*(?:--[^\n]*)?$` on one line:
/// the digits' span within the line.
fn local_declaration(line: &str, name: &str) -> Option<(usize, usize)> {
    let skip = |at: usize| {
        at + line[at..]
            .find(|c: char| !py::is_space(c))
            .unwrap_or(line.len() - at)
    };
    let mut at = skip(0);
    at += line[at..].starts_with("local").then_some(5)?;
    let spaced = skip(at);
    if spaced == at {
        return None;
    }
    at = spaced;
    at += line[at..].starts_with(name).then_some(name.len())?;
    at = skip(at);
    at += line[at..].starts_with('=').then_some(1)?;
    at = skip(at);
    let digits = line[at..].bytes().take_while(u8::is_ascii_digit).count();
    if digits == 0 || line.as_bytes()[at] == b'0' {
        return None;
    }
    let span = (at, at + digits);
    at = skip(span.1);
    if line[at..].starts_with(';') {
        at = skip(at + 1);
    }
    (at == line.len() || line[at..].starts_with("--")).then_some(span)
}

/// gtk_scale_local(): a `tostring(NAME)` argument resolves only to a
/// single-purpose `local NAME = <whole number>` on its own line.
fn gtk_scale_local(
    source: &str,
    tokens: &[Token<'_>],
    reference: usize,
) -> Result<(u64, (usize, usize)), String> {
    let error = || GTK_LOCAL_ERROR.to_owned();
    let name = tokens[reference].text;
    let uses: Vec<usize> = tokens
        .iter()
        .enumerate()
        .filter(|(_, t)| t.text == name)
        .map(|(i, _)| i)
        .collect();
    if uses.len() != 2
        || uses[1] != reference
        || tokens.iter().any(|t| t.text == "do" || t.text == "end")
    {
        return Err(error());
    }
    let declaration = uses[0];
    if declaration == 0 || tokens[declaration - 1].text != "local" {
        return Err(error());
    }
    let start = line_start(source, tokens[declaration - 1].start);
    let end = source[start..]
        .find('\n')
        .map_or(source.len(), |i| start + i);
    let (a, b) = local_declaration(&source[start..end], name).ok_or_else(error)?;
    let span = (start + a, start + b);
    let following = tokens.iter().find(|t| t.start >= span.1).map(|t| t.text);
    if matches!(
        following,
        Some(
            "+" | "-"
                | "*"
                | "/"
                | "%"
                | "^"
                | "."
                | "&"
                | "|"
                | "~"
                | "<"
                | ">"
                | "="
                | "and"
                | "or"
        )
    ) {
        return Err(error());
    }
    Ok((whole_number(&source[span.0..span.1])?, span))
}

/// The GTK scale monitors.lua sets (1 without a setting) and the span of
/// its literal, for an update in place.
pub fn gtk_scale_setting(source: &str) -> Result<(u64, Option<(usize, usize)>), String> {
    let tokens = code_tokens(source);
    let texts: Vec<&str> = tokens.iter().map(|t| t.text).collect();
    let mut found = Vec::new();
    for i in 0..tokens.len().saturating_sub(4) {
        if texts[i..i + 4] != ["hl", ".", "env", "("]
            || !matches!(texts[i + 4], "\"GDK_SCALE\"" | "'GDK_SCALE'")
        {
            continue;
        }
        let prefix = &source[line_start(source, tokens[i].start)..tokens[i].start];
        if !py::strip(prefix).is_empty() || texts.iter().any(|t| CONTROL.contains(t)) {
            return Err("GTK scale must be a standalone hl.env call in monitors.lua".into());
        }
        let call = &texts[i..(i + 11).min(texts.len())];
        if call.len() >= 8 && call[5] == "," && call[7] == ")" && whole_number_string(call[6]) {
            let token = tokens[i + 6];
            found.push((
                whole_number(&token.text[1..token.text.len() - 1])?,
                (token.start, token.end),
            ));
        } else if call.len() == 11
            && call[5..8] == [",", "tostring", "("]
            && call[9..] == [")", ")"]
            && identifier(call[8])
        {
            if texts.iter().filter(|&&t| t == "tostring").count() != 1 {
                return Err(
                    "GTK scale requires the unmodified tostring function in monitors.lua".into(),
                );
            }
            found.push(gtk_scale_local(source, &tokens, i + 8)?);
        } else {
            return Err(
                "GTK scale must be a whole-number string or tostring of a local whole number in monitors.lua".into(),
            );
        }
    }
    if found.len() > 1 {
        return Err("Remove duplicate GDK_SCALE settings from monitors.lua".into());
    }
    Ok(found
        .first()
        .map_or((1, None), |&(value, span)| (value, Some(span))))
}

/// monitors.lua with the GTK scale set to `scale` (1..=4, an int): the
/// literal is replaced in place, or an `hl.env` call is appended.
pub fn update_gtk_scale(source: &str, scale: &Value) -> Result<String, String> {
    let valid = match scale {
        Value::Number(n) if !n.is_f64() => n.as_i64().is_some_and(|v| (1..=4).contains(&v)),
        _ => false,
    };
    if !valid {
        return Err("GTK scale must be 1, 2, 3, or 4".into());
    }
    let text = py::to_str(scale);
    let (_, span) = gtk_scale_setting(source)?;
    Ok(match span {
        Some((a, b)) => {
            // Keep Omarchy's numeric local and its tostring call as they are.
            let value = if matches!(source.as_bytes()[a], b'"' | b'\'') {
                lua_string(&text)
            } else {
                text
            };
            format!("{}{value}{}", &source[..a], &source[b..])
        }
        None => format!(
            "{}\nhl.env(\"GDK_SCALE\", {})\n",
            py::rstrip(source),
            lua_string(&text)
        ),
    })
}

/// A Lua string literal: `\` and `"` escaped, control characters as
/// decimal escapes (`\009`).
pub fn lua_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        if c == '\\' || c == '"' {
            out.push('\\');
            out.push(c);
        } else if (c as u32) < 32 {
            let _ = write!(out, "\\{:03}", c as u32);
        } else {
            out.push(c);
        }
    }
    out.push('"');
    out
}

fn field<'a>(monitor: &'a Map<String, Value>, key: &str) -> &'a Value {
    monitor.get(key).unwrap_or(&Value::Null)
}

/// The output a saved rule names: built-in panels (eDP, LVDS, DSI) by
/// connector, which Omarchy's clamshell script looks up; everything else by
/// its stable selector (`desc:…` when unique).
pub fn selector(monitor: &Map<String, Value>) -> String {
    let name = py::to_str(field(monitor, "name"));
    if ["eDP-", "LVDS-", "DSI-"]
        .iter()
        .any(|p| name.starts_with(p))
    {
        return name;
    }
    py::to_str(field(monitor, "selector"))
}

/// The source with every comment blanked (newlines kept).
fn without_comments(source: &str) -> String {
    tokenize(source)
        .iter()
        .map(|t| {
            if t.text.starts_with("--") {
                t.text
                    .chars()
                    .map(|c| if c == '\n' { '\n' } else { ' ' })
                    .collect()
            } else {
                t.text.to_owned()
            }
        })
        .collect()
}

fn skip_blanks(line: &str, at: usize) -> usize {
    at + line[at..]
        .find(|c| c != ' ' && c != '\t')
        .unwrap_or(line.len() - at)
}

/// `^[ \t]*local[ \t]+omarchy_monitor_scale[ \t]*=[ \t]*("[^"\n]*"|[0-9.]+)[ \t]*;?[ \t]*$`
fn knob_declaration(line: &str) -> Option<&str> {
    let mut at = skip_blanks(line, 0);
    at += line[at..].starts_with("local").then_some(5)?;
    let spaced = skip_blanks(line, at);
    if spaced == at {
        return None;
    }
    at = spaced;
    at += line[at..]
        .starts_with(SCALE_LOCAL)
        .then_some(SCALE_LOCAL.len())?;
    at = skip_blanks(line, at);
    at += line[at..].starts_with('=').then_some(1)?;
    at = skip_blanks(line, at);
    let start = at;
    if line[at..].starts_with('"') {
        at += 1 + line[at + 1..].find('"')? + 1;
    } else {
        let length = line[at..]
            .bytes()
            .take_while(|b| b.is_ascii_digit() || *b == b'.')
            .count();
        if length == 0 {
            return None;
        }
        at += length;
    }
    let value = &line[start..at];
    at = skip_blanks(line, at);
    if line[at..].starts_with(';') {
        at = skip_blanks(line, at + 1);
    }
    (at == line.len()).then_some(value)
}

fn word_before(text: &str, at: usize) -> bool {
    text[..at].chars().next_back().is_some_and(py::is_word)
}

fn word_after(text: &str, at: usize) -> bool {
    text[at..].chars().next().is_some_and(py::is_word)
}

/// `(?m)^(?![ \t]*local\b).*\bomarchy_monitor_scale[ \t]*=(?!=)`
fn knob_reassigned(code: &str) -> bool {
    code.split('\n').any(|line| {
        let indented = skip_blanks(line, 0);
        if line[indented..].starts_with("local") && !word_after(line, indented + 5) {
            return false;
        }
        line.match_indices(SCALE_LOCAL).any(|(at, _)| {
            if word_before(line, at) {
                return false;
            }
            let after = skip_blanks(line, at + SCALE_LOCAL.len());
            line[after..].starts_with('=') && !line[after + 1..].starts_with('=')
        })
    })
}

fn skip_space(text: &str, at: usize) -> usize {
    at + text[at..]
        .find(|c: char| !py::is_space(c))
        .unwrap_or(text.len() - at)
}

fn line_end(text: &str, at: usize) -> usize {
    text[at..].find('\n').map_or(text.len(), |i| at + i)
}

/// `hl\.monitor\(\{[^\n]*output\s*=\s*""[^\n]*\bscale\s*=\s*omarchy_monitor_scale\b`
fn knob_catch_all(code: &str) -> bool {
    let scale_names_knob = |at: usize| {
        if word_before(code, at) || !code[at..].starts_with("scale") {
            return false;
        }
        let at = skip_space(code, at + 5);
        if !code[at..].starts_with('=') {
            return false;
        }
        let at = skip_space(code, at + 1);
        code[at..].starts_with(SCALE_LOCAL) && !word_after(code, at + SCALE_LOCAL.len())
    };
    code.match_indices("hl.monitor({").any(|(call, pattern)| {
        let from = call + pattern.len();
        code[from..line_end(code, from)]
            .match_indices("output")
            .any(|(offset, _)| {
                let at = skip_space(code, from + offset + 6);
                if !code[at..].starts_with('=') {
                    return false;
                }
                let at = skip_space(code, at + 1);
                if !code[at..].starts_with("\"\"") {
                    return false;
                }
                let after = at + 2;
                (after..line_end(code, after))
                    .filter(|&i| code.is_char_boundary(i))
                    .any(scale_names_knob)
            })
    })
}

/// Whether Omarchy's scale knob (`local omarchy_monitor_scale = …`, the
/// line omarchy-hyprland-monitor-scaling rewrites) drives the catch-all
/// rule, and its number when it is one.
pub fn monitor_scale_local(source: &str) -> (bool, Option<f64>) {
    let code = without_comments(source);
    let declarations: Vec<&str> = code.split('\n').filter_map(knob_declaration).collect();
    if declarations.len() != 1 || knob_reassigned(&code) || !knob_catch_all(&code) {
        return (false, None);
    }
    let value = declarations[0];
    if value.starts_with('"') {
        return (true, None);
    }
    match value.parse::<f64>() {
        Ok(number) => (true, Some(number)),
        Err(_) => (false, None),
    }
}

fn id_key(monitor: &Map<String, Value>) -> String {
    match field(monitor, "id") {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn scale_of(monitor: &Map<String, Value>) -> Result<f64, String> {
    py::number(field(monitor, "scale")).ok_or_else(|| "Display scale must be a number".to_owned())
}

/// The fields of a rule for `monitor`, in the old helper's order. A
/// persistent rule names the stable selector (also for a mirror source).
pub fn rule_fields(
    monitor: &Map<String, Value>,
    persistent: bool,
    monitors: &[Map<String, Value>],
    scale_local: bool,
) -> Result<Vec<(&'static str, String)>, String> {
    let mut mirror = field(monitor, "mirrorOf").clone();
    if persistent
        && py::truthy(&mirror)
        && !monitors.is_empty()
        && let Some(target) = monitors.iter().find(|m| py::eq(field(m, "name"), &mirror))
    {
        mirror = Value::String(selector(target));
    }
    let output = if persistent {
        selector(monitor)
    } else {
        py::to_str(field(monitor, "name"))
    };
    let mode = format!(
        "{}x{}@{}",
        py::to_str(field(monitor, "width")),
        py::to_str(field(monitor, "height")),
        py::fixed5(field(monitor, "refreshRate"))?
    );
    let position = format!(
        "{}x{}",
        py::to_str(field(monitor, "x")),
        py::to_str(field(monitor, "y"))
    );
    let scale = if scale_local {
        SCALE_LOCAL.to_owned()
    } else {
        py::general10(field(monitor, "scale"))?
    };
    Ok(vec![
        ("output", lua_string(&output)),
        ("mode", lua_string(&mode)),
        ("position", lua_string(&position)),
        ("scale", scale),
        ("transform", py::to_str(field(monitor, "transform"))),
        (
            "disabled",
            if py::truthy(field(monitor, "disabled")) {
                "true"
            } else {
                "false"
            }
            .to_owned(),
        ),
        ("mirror", lua_string(&py::to_str(&mirror))),
    ])
}

fn rule(values: &[(&str, String)]) -> String {
    let fields: Vec<String> = values.iter().map(|(k, v)| format!("{k} = {v}")).collect();
    format!("hl.monitor({{ {} }})", fields.join(", "))
}

/// A runtime rule for `hyprctl eval` (connector names).
pub fn monitor_rule(monitor: &Map<String, Value>) -> Result<String, String> {
    Ok(rule(&rule_fields(monitor, false, &[], false)?))
}

/// monitors.lua with literal rules for the `edited` monitors rewritten in
/// place (unmanaged fields, comments and other rules kept) and rules added
/// for those that have none. `all` is every display of the draft and `base`
/// the values before editing.
pub fn update_config(
    source: &str,
    edited: &[Map<String, Value>],
    all: &[Map<String, Value>],
    base: &[Map<String, Value>],
) -> Result<String, String> {
    let all = if all.is_empty() { edited } else { all };
    let (has_local, local_scale) = monitor_scale_local(source);
    let follows_local =
        |monitor: &Map<String, Value>, existing: Option<&str>| -> Result<bool, String> {
            // Keep a display on Omarchy's scale knob unless this save changes its scale.
            if !has_local {
                return Ok(false);
            }
            if let Some(knob) = local_scale {
                // A numeric knob is only safe to name when it is this display's scale.
                return Ok((scale_of(monitor)? - knob).abs() < 0.00001);
            }
            let key = id_key(monitor);
            let before = base.iter().rev().find(|m| id_key(m) == key);
            let unchanged = match before {
                Some(before) => (scale_of(before)? - scale_of(monitor)?).abs() < 0.00001,
                None => false,
            };
            Ok(unchanged && existing.is_none_or(|text| py::strip(text) == SCALE_LOCAL))
        };

    let tokens = code_tokens(source);
    let texts: Vec<&str> = tokens.iter().map(|t| t.text).collect();
    if texts.iter().any(|t| CONTROL.contains(t)) {
        return Err("Conditional monitor configuration must be edited in monitors.lua".into());
    }
    let edited_ids: HashSet<String> = edited.iter().map(id_key).collect();
    let mut replacements: Vec<(usize, usize, String)> = Vec::new();
    let mut found: HashSet<String> = HashSet::new();
    let n = tokens.len();
    let mut i = 0;
    while i < n {
        if texts[i..(i + 5).min(n)] != ["hl", ".", "monitor", "(", "{"] {
            if texts[i..(i + 3).min(n)] == ["hl", ".", "monitor"] {
                return Err(
                    "Use literal hl.monitor({...}) rules in monitors.lua before saving".into(),
                );
            }
            i += 1;
            continue;
        }
        let start = i;
        i += 5;
        let mut depth: i64 = 0;
        let mut fields: Vec<(&str, (usize, usize))> = Vec::new();
        while i < n && !(texts[i] == "}" && depth == 0) {
            if depth == 0 && i + 2 < n && texts[i + 1] == "=" {
                let key = texts[i];
                let value_start = i + 2;
                i = value_start;
                while i < n {
                    let t = texts[i];
                    if depth == 0 && matches!(t, "," | ";" | "}") {
                        break;
                    }
                    match t {
                        "{" | "(" | "[" => depth += 1,
                        "}" | ")" | "]" => depth -= 1,
                        _ => {}
                    }
                    i += 1;
                }
                if i > value_start {
                    if fields.iter().any(|(k, _)| *k == key) {
                        return Err(
                            "Duplicate monitor field; simplify monitors.lua before saving".into(),
                        );
                    }
                    fields.push((key, (tokens[value_start].start, tokens[i - 1].end)));
                }
            } else {
                i += 1;
            }
            if i < n && matches!(texts[i], "," | ";") {
                i += 1;
            }
        }
        if i + 1 >= n || texts[i + 1] != ")" {
            return Err("Cannot update this monitor rule in monitors.lua".into());
        }
        let span = |key: &str| {
            fields
                .iter()
                .find(|(k, _)| *k == key)
                .map(|&(_, span)| span)
        };
        let output_error = || "Monitor output must be a literal string in monitors.lua".to_owned();
        let (a, b) = span("output").ok_or_else(output_error)?;
        let literal = &source[a..b];
        let plain = |quote: char| {
            literal.len() >= 2
                && literal.starts_with(quote)
                && literal.ends_with(quote)
                && !literal[1..literal.len() - 1].contains([quote, '\\'])
        };
        if !plain('"') && !plain('\'') {
            return Err(output_error());
        }
        let output = &literal[1..literal.len() - 1];
        let matching: Vec<&Map<String, Value>> = all
            .iter()
            .filter(|m| {
                py::eq(field(m, "name"), &Value::String(output.to_owned()))
                    || output.strip_prefix("desc:").is_some_and(|wanted| {
                        field(m, "description")
                            .as_str()
                            .is_some_and(|d| d.starts_with(wanted))
                    })
            })
            .collect();
        if matching.len() > 1 && matching.iter().any(|m| edited_ids.contains(&id_key(m))) {
            return Err(
                "A monitor description matches multiple displays; use a unique description".into(),
            );
        }
        if let Some(monitor) = matching
            .into_iter()
            .find(|m| edited_ids.contains(&id_key(m)))
        {
            if found.contains(&id_key(monitor)) {
                return Err(format!(
                    "Duplicate rules for {}; remove the duplicate before saving",
                    py::to_str(field(monitor, "name"))
                ));
            }
            // Reject conditional or inline calls rather than silently changing their scope.
            let prefix = &source[line_start(source, tokens[start].start)..tokens[start].start];
            if !py::strip(prefix).is_empty() {
                return Err("Monitor rules must be standalone calls in monitors.lua".into());
            }
            let existing = span("scale").map(|(a, b)| &source[a..b]);
            let values = rule_fields(monitor, true, all, follows_local(monitor, existing)?)?;
            let mut missing = Vec::new();
            for (key, value) in &values {
                match span(key) {
                    Some((a, b)) => replacements.push((a, b, value.clone())),
                    None => missing.push(format!("{key} = {value}")),
                }
            }
            if !missing.is_empty() {
                let separator = if matches!(texts[i - 1], "," | ";" | "{") {
                    ""
                } else {
                    ", "
                };
                let at = tokens[i].start;
                replacements.push((at, at, format!("{separator}{} ", missing.join(", "))));
            }
            found.insert(id_key(monitor));
        }
        i += 2;
    }
    replacements.sort();
    let mut result = source.to_owned();
    for (a, b, value) in replacements.into_iter().rev() {
        result.replace_range(a..b, &value);
    }
    let mut additions = Vec::new();
    for monitor in edited {
        if !found.contains(&id_key(monitor)) {
            additions.push(rule(&rule_fields(
                monitor,
                true,
                all,
                follows_local(monitor, None)?,
            )?));
        }
    }
    if !additions.is_empty() {
        result = format!("{}\n{}\n", py::rstrip(&result), additions.join("\n"));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn texts(source: &str) -> Vec<&str> {
        code_tokens(source).iter().map(|t| t.text).collect()
    }

    fn monitor(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn tokens_follow_the_old_pattern() {
        assert_eq!(
            texts("hl.monitor({ output = \"a\\\"b\" })"),
            [
                "hl",
                ".",
                "monitor",
                "(",
                "{",
                "output",
                "=",
                "\"a\\\"b\"",
                "}",
                ")"
            ]
        );
        assert_eq!(
            texts("x = [==[ a ]] b ]==] -- c\n--[[ d\n]] y"),
            ["x", "=", "[==[ a ]] b ]==]", "y"]
        );
        // An unclosed long comment is a line comment; an unclosed string is a quote character.
        assert_eq!(texts("--[[ open\nz \"q"), ["z", "\"", "q"]);
        assert_eq!(texts("a12 = 12"), ["a12", "=", "1", "2"]);
        assert_eq!(texts("ä_x"), ["ä", "_x"]);
        let all = tokenize("a  --x\n b");
        assert_eq!(
            all.iter().map(|t| t.text).collect::<Vec<_>>(),
            ["a", "  ", "--x", "\n ", "b"]
        );
        assert_eq!(all[4].start, 8);
    }

    #[test]
    fn gtk_scale_literals_and_locals() {
        assert_eq!(
            gtk_scale_setting("hl.env(\"GDK_SCALE\", \"2\")").unwrap(),
            (2, Some((20, 23)))
        );
        let source = "local s = 3 -- note\nhl.env('GDK_SCALE', tostring(s))\n";
        assert_eq!(gtk_scale_setting(source).unwrap(), (3, Some((10, 11))));
        assert_eq!(
            update_gtk_scale(source, &json!(1)).unwrap(),
            source.replacen('3', "1", 1)
        );
        assert_eq!(gtk_scale_setting("").unwrap(), (1, None));
        assert_eq!(
            update_gtk_scale("x\n\n", &json!(4)).unwrap(),
            "x\nhl.env(\"GDK_SCALE\", \"4\")\n"
        );
        for bad in [
            json!(0),
            json!(5),
            json!(2.0),
            json!(true),
            json!("2"),
            json!(null),
        ] {
            assert!(update_gtk_scale("", &bad).is_err(), "{bad}");
        }
        assert!(
            gtk_scale_setting("local s = 3\ns = 4\nhl.env(\"GDK_SCALE\", tostring(s))").is_err()
        );
        assert!(gtk_scale_setting("local s = 3 + 1\nhl.env(\"GDK_SCALE\", tostring(s))").is_err());
        assert!(gtk_scale_setting("hl.env(\"GDK_SCALE\", \"99999999999999999999999\")").is_err());
    }

    #[test]
    fn lua_strings_escape_controls() {
        assert_eq!(
            lua_string("a\"b\\c\td\u{7f}é"),
            "\"a\\\"b\\\\c\\009d\u{7f}é\""
        );
    }

    #[test]
    fn knob_detection() {
        let omarchy = "local omarchy_monitor_scale = \"auto\"\nhl.monitor({ output = \"\", scale = omarchy_monitor_scale })\n";
        assert_eq!(monitor_scale_local(omarchy), (true, None));
        assert_eq!(
            monitor_scale_local(&omarchy.replace("\"auto\"", "1.5 ;")),
            (true, Some(1.5))
        );
        assert_eq!(
            monitor_scale_local(&omarchy.replace("\"auto\"", "1.")),
            (true, Some(1.0))
        );
        assert_eq!(
            monitor_scale_local(&omarchy.replace("\"auto\"", "1..5")),
            (false, None)
        );
        assert_eq!(
            monitor_scale_local(&format!("{omarchy}x.omarchy_monitor_scale = 2\n")),
            (false, None)
        );
        assert_eq!(
            monitor_scale_local(&format!("{omarchy}xomarchy_monitor_scale = 2\n")),
            (true, None)
        );
        assert_eq!(
            monitor_scale_local(&format!("{omarchy}  omarchy_monitor_scale = 2\n")),
            (false, None)
        );
        assert_eq!(
            monitor_scale_local(&format!("{omarchy}if omarchy_monitor_scale == 2\n")),
            (true, None)
        );
        assert_eq!(
            monitor_scale_local(&format!("{omarchy}localx omarchy_monitor_scale = 2\n")),
            (false, None)
        );
        assert_eq!(
            monitor_scale_local(&omarchy.replace("output = \"\"", "output =\n \"\"")),
            (true, None)
        );
        assert_eq!(
            monitor_scale_local(&omarchy.replace(
                "scale = omarchy_monitor_scale ",
                "scale = omarchy_monitor_scale2 "
            )),
            (false, None)
        );
        assert_eq!(
            monitor_scale_local(&omarchy.replace("hl.monitor", "-- hl.monitor")),
            (false, None)
        );
    }

    #[test]
    fn rules_are_rewritten_in_place() {
        let dp = monitor(
            json!({"id": "desc:A", "name": "DP-1", "selector": "desc:A", "description": "A",
            "width": 1920, "height": 1080, "refreshRate": 60.0, "x": 0, "y": 0, "scale": 1.5, "transform": 0,
            "disabled": false, "mirrorOf": ""}),
        );
        let source = "hl.monitor({ output = 'DP-1'; vrr = { 1, 2 }, scale = 2 }) -- keep\n";
        let result = update_config(
            source,
            std::slice::from_ref(&dp),
            std::slice::from_ref(&dp),
            &[],
        )
        .unwrap();
        assert_eq!(
            result,
            "hl.monitor({ output = \"desc:A\"; vrr = { 1, 2 }, scale = 1.5 , mode = \"1920x1080@60.00000\", \
            position = \"0x0\", transform = 0, disabled = false, mirror = \"\" }) -- keep\n"
        );
        assert_eq!(
            update_config(
                &result,
                std::slice::from_ref(&dp),
                std::slice::from_ref(&dp),
                &[]
            )
            .unwrap(),
            result
        );
        let added = update_config("-- none\n\n", std::slice::from_ref(&dp), &[], &[]).unwrap();
        assert_eq!(
            added,
            "-- none\nhl.monitor({ output = \"desc:A\", mode = \"1920x1080@60.00000\", position = \"0x0\", \
            scale = 1.5, transform = 0, disabled = false, mirror = \"\" })\n"
        );
        assert!(update_config("while true do end", std::slice::from_ref(&dp), &[], &[]).is_err());
        assert_eq!(
            monitor_rule(&dp).unwrap(),
            "hl.monitor({ output = \"DP-1\", mode = \"1920x1080@60.00000\", position = \"0x0\", scale = 1.5, \
            transform = 0, disabled = false, mirror = \"\" })"
        );
    }
}
