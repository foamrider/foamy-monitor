//! The bits of Python semantics the old helpers' contract rests on: string
//! stripping and line splitting, truthiness and equality of JSON values,
//! `str()`, `repr()` and `format(x, ".10g")` of numbers, `int()`/`float()`
//! conversions, text-mode newline translation, and `OSError` messages.

use std::fmt::Write as _;
use std::io;
use std::path::Path;

use serde_json::Value;

/// `str.isspace()` (and `\s` in a `str` pattern): Unicode White_Space plus
/// the information separators U+001C..U+001F.
pub fn is_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// `\w` in a `str` pattern: alphanumeric or `_`.
pub fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// `str.strip()`.
pub fn strip(text: &str) -> &str {
    text.trim_matches(is_space)
}

/// `str.rstrip()`.
pub fn rstrip(text: &str) -> &str {
    text.trim_end_matches(is_space)
}

/// What a text-mode read returns: `"\r\n"` and a lone `"\r"` become `"\n"`.
pub fn universal_newlines(text: &str) -> String {
    if !text.contains('\r') {
        return text.to_owned();
    }
    text.replace("\r\n", "\n").replace('\r', "\n")
}

/// `str.splitlines()`: splits on `\n`, `\r`, `\r\n`, `\v`, `\f`, U+001C..1E,
/// U+0085, U+2028 and U+2029; no empty last item for a trailing break.
pub fn splitlines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        let breaks = matches!(
            c,
            '\n' | '\r'
                | '\u{b}'
                | '\u{c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        );
        if !breaks {
            continue;
        }
        lines.push(&text[start..at]);
        let mut end = at + c.len_utf8();
        if c == '\r'
            && let Some(&(next, '\n')) = chars.peek()
        {
            chars.next();
            end = next + 1;
        }
        start = end;
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// Python truthiness of a JSON value.
pub fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|x| x != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

/// `isinstance(value, (int, float)) and not isinstance(value, bool)`.
pub fn is_number(value: &Value) -> bool {
    value.is_number()
}

/// The value as a number, with `bool` as 0/1 like Python's `int` subclass.
pub fn number(value: &Value) -> Option<f64> {
    match value {
        Value::Bool(b) => Some(f64::from(u8::from(*b))),
        Value::Number(n) => n.as_f64(),
        _ => None,
    }
}

fn integer(value: &Value) -> Option<i128> {
    match value {
        Value::Bool(b) => Some(i128::from(*b)),
        Value::Number(n) if n.is_i64() => n.as_i64().map(i128::from),
        Value::Number(n) if n.is_u64() => n.as_u64().map(i128::from),
        _ => None,
    }
}

/// Python `==` on decoded JSON (`1 == 1.0 == True`, deep for lists and dicts).
pub fn eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Null, Value::Null) => true,
        (Value::String(x), Value::String(y)) => x == y,
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| eq(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(key, p)| y.get(key).is_some_and(|q| eq(p, q)))
        }
        (Value::Bool(_) | Value::Number(_), Value::Bool(_) | Value::Number(_)) => {
            match (integer(a), integer(b)) {
                (Some(x), Some(y)) => x == y,
                _ => number(a) == number(b),
            }
        }
        _ => false,
    }
}

/// `math.isclose(a, b, abs_tol=0.00001)` (default `rel_tol=1e-09`).
pub fn isclose(a: f64, b: f64) -> bool {
    if a == b {
        return true;
    }
    if a.is_infinite() || b.is_infinite() {
        return false;
    }
    let diff = (b - a).abs();
    diff <= 1e-9 * b.abs() || diff <= 1e-9 * a.abs() || diff <= 0.00001
}

/// display_transaction.same(): numbers are close, everything else equal.
pub fn same(a: &Value, b: &Value) -> bool {
    if is_number(a) {
        return match (number(a), number(b)) {
            (Some(x), Some(y)) => isclose(x, y),
            _ => false,
        };
    }
    eq(a, b)
}

/// Splits `{:e}`/`{:.Ne}` output into (negative, digits, exponent).
fn scientific(text: &str) -> (bool, String, i32) {
    let (mantissa, exponent) = text.split_once('e').unwrap_or((text, "0"));
    let digits = mantissa.chars().filter(char::is_ascii_digit).collect();
    (
        mantissa.starts_with('-'),
        digits,
        exponent.parse().unwrap_or(0),
    )
}

/// Digits `d.ddd × 10^exponent` written out in positional notation.
fn positional(digits: &str, exponent: i32) -> String {
    if exponent >= 0 {
        let whole = exponent as usize + 1;
        if digits.len() <= whole {
            format!("{digits}{}", "0".repeat(whole - digits.len()))
        } else {
            format!("{}.{}", &digits[..whole], &digits[whole..])
        }
    } else {
        format!("0.{}{digits}", "0".repeat((-exponent - 1) as usize))
    }
}

fn exponent_form(negative: bool, digits: &str, exponent: i32) -> String {
    let mut text = String::from(if negative { "-" } else { "" });
    text.push_str(&digits[..1]);
    if digits.len() > 1 {
        text.push('.');
        text.push_str(&digits[1..]);
    }
    let sign = if exponent < 0 { '-' } else { '+' };
    let _ = write!(text, "e{sign}{:02}", exponent.unsigned_abs());
    text
}

fn special(x: f64) -> Option<&'static str> {
    if x.is_nan() {
        Some("nan")
    } else if x.is_infinite() {
        Some(if x > 0.0 { "inf" } else { "-inf" })
    } else {
        None
    }
}

/// `repr(float)`: the shortest round-trip digits, positional between 1e-4
/// and 1e16 (always with a fraction), otherwise `1e+16` style.
pub fn float_repr(x: f64) -> String {
    if let Some(text) = special(x) {
        return text.into();
    }
    if x == 0.0 {
        return if x.is_sign_negative() { "-0.0" } else { "0.0" }.into();
    }
    let (negative, digits, exponent) = scientific(&format!("{x:e}"));
    if (-4..16).contains(&exponent) {
        let mut text = positional(&digits, exponent);
        if !text.contains('.') {
            text.push_str(".0");
        }
        if negative { format!("-{text}") } else { text }
    } else {
        exponent_form(negative, &digits, exponent)
    }
}

/// `format(x, ".{precision}g")` for a float (or an int, which Python converts).
pub fn format_g(x: f64, precision: usize) -> String {
    if let Some(text) = special(x) {
        return text.into();
    }
    if x == 0.0 {
        return if x.is_sign_negative() { "-0" } else { "0" }.into();
    }
    let precision = precision.max(1);
    let (negative, digits, exponent) = scientific(&format!("{x:.*e}", precision - 1));
    let digits = digits.trim_end_matches('0');
    let digits = if digits.is_empty() { "0" } else { digits };
    if exponent < -4 || exponent >= precision as i32 {
        return exponent_form(negative, digits, exponent);
    }
    let mut text = positional(digits, exponent);
    if text.contains('.') {
        text = text.trim_end_matches('0').trim_end_matches('.').to_owned();
    }
    if negative { format!("-{text}") } else { text }
}

/// `format(x, ".5f")` for an int, float or bool.
pub fn fixed5(value: &Value) -> Result<String, String> {
    match number(value) {
        Some(x) => Ok(match special(x) {
            Some(text) => text.into(),
            None => format!("{x:.5}"),
        }),
        None => Err(format!(
            "Unknown format code 'f' for object of type '{}'",
            type_name(value)
        )),
    }
}

/// `format(x, ".10g")` for an int, float or bool.
pub fn general10(value: &Value) -> Result<String, String> {
    match value {
        Value::Number(n) if !n.is_f64() => Ok(format_g(n.as_f64().unwrap_or(0.0), 10)),
        _ => match number(value) {
            Some(x) => Ok(format_g(x, 10)),
            None => Err(format!(
                "Unknown format code 'g' for object of type '{}'",
                type_name(value)
            )),
        },
    }
}

/// Python's type name of a decoded JSON value.
pub fn type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "NoneType",
        Value::Bool(_) => "bool",
        Value::Number(n) if n.is_f64() => "float",
        Value::Number(_) => "int",
        Value::String(_) => "str",
        Value::Array(_) => "list",
        Value::Object(_) => "dict",
    }
}

/// `repr(str)`.
pub fn repr_str(text: &str) -> String {
    let quote = if text.contains('\'') && !text.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut out = String::new();
    out.push(quote);
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c == quote => {
                out.push('\\');
                out.push(c);
            }
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                let _ = write!(out, "\\x{:02x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push(quote);
    out
}

/// `str(value)` of a decoded JSON value.
pub fn to_str(value: &Value) -> String {
    match value {
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(n) if n.is_f64() => float_repr(n.as_f64().unwrap_or(0.0)),
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn parse_int(text: &str) -> Option<i64> {
    let text = strip(text);
    let (negative, digits) = match text.as_bytes().first() {
        Some(b'-') => (true, &text[1..]),
        Some(b'+') => (false, &text[1..]),
        _ => (false, text),
    };
    // Digits, with single underscores between them.
    if digits.is_empty()
        || digits.starts_with('_')
        || digits.ends_with('_')
        || digits.contains("__")
    {
        return None;
    }
    let digits: String = digits.chars().filter(|&c| c != '_').collect();
    if !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let magnitude: i64 = digits.parse().ok()?;
    Some(if negative { -magnitude } else { magnitude })
}

/// `int(value)`: truncates floats, parses numeric strings.
pub fn int(value: &Value) -> Result<i64, String> {
    match value {
        Value::Bool(b) => Ok(i64::from(*b)),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                return Ok(i);
            }
            let x = n.as_f64().unwrap_or(f64::NAN);
            if x.is_nan() {
                Err("cannot convert float NaN to integer".into())
            } else if x.is_infinite() {
                Err("cannot convert float infinity to integer".into())
            } else if x.abs() < 9.2e18 {
                Ok(x.trunc() as i64)
            } else {
                Err("integer is too large".into())
            }
        }
        Value::String(s) => parse_int(s)
            .ok_or_else(|| format!("invalid literal for int() with base 10: {}", repr_str(s))),
        other => Err(format!(
            "int() argument must be a string, a bytes-like object or a real number, not '{}'",
            type_name(other)
        )),
    }
}

/// `float(value)`.
pub fn float(value: &Value) -> Result<f64, String> {
    match value {
        Value::String(s) => {
            let text: String = strip(s).chars().filter(|&c| c != '_').collect();
            text.parse::<f64>()
                .map_err(|_| format!("could not convert string to float: {}", repr_str(s)))
        }
        other => number(other).ok_or_else(|| {
            format!(
                "float() argument must be a string or a real number, not '{}'",
                type_name(other)
            )
        }),
    }
}

/// glibc's `strerror` text, which Python's messages carry (musl words a few
/// of these differently).
fn strerror(code: i32) -> Option<&'static str> {
    Some(match code {
        libc::EPERM => "Operation not permitted",
        libc::ENOENT => "No such file or directory",
        libc::ESRCH => "No such process",
        libc::EINTR => "Interrupted system call",
        libc::EIO => "Input/output error",
        libc::E2BIG => "Argument list too long",
        libc::ENOEXEC => "Exec format error",
        libc::EBADF => "Bad file descriptor",
        libc::EAGAIN => "Resource temporarily unavailable",
        libc::ENOMEM => "Cannot allocate memory",
        libc::EACCES => "Permission denied",
        libc::EBUSY => "Device or resource busy",
        libc::EEXIST => "File exists",
        libc::EXDEV => "Invalid cross-device link",
        libc::ENOTDIR => "Not a directory",
        libc::EISDIR => "Is a directory",
        libc::EINVAL => "Invalid argument",
        libc::EMFILE => "Too many open files",
        libc::ETXTBSY => "Text file busy",
        libc::EFBIG => "File too large",
        libc::ENOSPC => "No space left on device",
        libc::EROFS => "Read-only file system",
        libc::ENAMETOOLONG => "File name too long",
        libc::ELOOP => "Too many levels of symbolic links",
        libc::EDQUOT => "Disk quota exceeded",
        _ => return None,
    })
}

/// `str(OSError)` for an error about `filename`: `[Errno 2] No such file or
/// directory: '/path'`.
pub fn os_error(error: &io::Error, filename: &Path) -> String {
    match error.raw_os_error() {
        Some(code) => {
            let text = match strerror(code) {
                Some(text) => text.to_owned(),
                None => {
                    let shown = error.to_string();
                    shown
                        .strip_suffix(&format!(" (os error {code})"))
                        .unwrap_or(&shown)
                        .to_owned()
                }
            };
            format!(
                "[Errno {code}] {text}: {}",
                repr_str(&filename.to_string_lossy())
            )
        }
        None => error.to_string(),
    }
}

/// `str(UnicodeDecodeError)` for bytes that are not UTF-8.
pub fn decode_error(bytes: &[u8], error: &std::str::Utf8Error) -> String {
    let at = error.valid_up_to();
    let byte = bytes.get(at).copied().unwrap_or(0);
    let reason = match error.error_len() {
        None => "unexpected end of data",
        Some(_) if (0x80..0xc2).contains(&byte) || byte >= 0xf5 => "invalid start byte",
        Some(_) => "invalid continuation byte",
    };
    format!("'utf-8' codec can't decode byte 0x{byte:02x} in position {at}: {reason}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn floats_print_like_python() {
        for (x, repr) in [
            (60.0, "60.0"),
            (59.951, "59.951"),
            (1e16, "1e+16"),
            (1e15, "1000000000000000.0"),
            (0.0001, "0.0001"),
            (0.00001, "1e-05"),
            (-1.5, "-1.5"),
            (1.25e-7, "1.25e-07"),
            (0.0, "0.0"),
        ] {
            assert_eq!(float_repr(x), repr, "{x}");
        }
        for (x, g) in [
            (1.0, "1"),
            (1.25, "1.25"),
            (1.6, "1.6"),
            (0.1 + 0.2, "0.3"),
            (1.0 / 3.0, "0.3333333333"),
            (12345678901.0, "1.23456789e+10"),
            (0.00001234, "1.234e-05"),
            (2.5, "2.5"),
            (-0.75, "-0.75"),
            (1234567890.0, "1234567890"),
        ] {
            assert_eq!(format_g(x, 10), g, "{x}");
        }
        assert_eq!(fixed5(&json!(60)).unwrap(), "60.00000");
        assert_eq!(fixed5(&json!(59.951)).unwrap(), "59.95100");
        assert_eq!(fixed5(&json!(0.015625)).unwrap(), "0.01562");
        assert!(fixed5(&json!("60")).is_err());
        assert_eq!(general10(&json!(2)).unwrap(), "2");
        assert_eq!(general10(&json!(true)).unwrap(), "1");
    }

    #[test]
    fn values_compare_like_python() {
        assert!(eq(&json!(1), &json!(1.0)));
        assert!(eq(&json!(true), &json!(1)));
        assert!(!eq(&json!("1"), &json!(1)));
        assert!(eq(&json!({"a": [1, 2.0]}), &json!({"a": [1.0, 2]})));
        assert!(!eq(&json!(null), &json!(0)));
        assert!(same(&json!(1.0), &json!(1.000001)));
        assert!(!same(&json!(1.0), &json!(1.0001)));
        assert!(same(&json!(1), &json!(true)));
        assert!(!same(&json!(true), &json!(1.000001)));
        assert!(same(&json!("a"), &json!("a")));
        assert!(!same(&json!(1), &json!("1")));
    }

    #[test]
    fn conversions() {
        assert_eq!(int(&json!(1920.7)), Ok(1920));
        assert_eq!(int(&json!(" 1_080 ")), Ok(1080));
        assert_eq!(int(&json!(-3)), Ok(-3));
        assert!(int(&json!("1.5")).is_err());
        assert!(int(&json!(null)).is_err());
        assert_eq!(float(&json!("59.94")), Ok(59.94));
        assert_eq!(float(&json!(60)), Ok(60.0));
        assert_eq!(to_str(&json!(1.0)), "1.0");
        assert_eq!(to_str(&json!(-1080)), "-1080");
        assert_eq!(to_str(&json!(null)), "None");
        assert_eq!(repr_str("it's"), "\"it's\"");
        assert_eq!(repr_str("/a b"), "'/a b'");
    }

    #[test]
    fn lines_and_spaces() {
        assert_eq!(
            splitlines("a\r\nb\rc\nd\u{2028}e\n"),
            ["a", "b", "c", "d", "e"]
        );
        assert_eq!(splitlines("a\n\nb"), ["a", "", "b"]);
        assert!(splitlines("").is_empty());
        assert_eq!(universal_newlines("a\r\nb\rc"), "a\nb\nc");
        assert_eq!(strip("\u{1f} x \u{a0}"), "x");
        assert_eq!(rstrip("x\t\n"), "x");
    }

    #[test]
    fn os_errors_read_like_python() {
        let error = io::Error::from_raw_os_error(libc::ENOENT);
        assert_eq!(
            os_error(&error, Path::new("/x/monitors.lua")),
            "[Errno 2] No such file or directory: '/x/monitors.lua'"
        );
        let bytes = std::hint::black_box(b"ab\xff".as_slice());
        let error = std::str::from_utf8(bytes).unwrap_err();
        assert_eq!(
            decode_error(bytes, &error),
            "'utf-8' codec can't decode byte 0xff in position 2: invalid start byte"
        );
    }
}
