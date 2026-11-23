"""Starlark TOML Decoder implementation."""

load(
    ":datetime.bzl",
    "LocalDate",
    "LocalDateTime",
    "LocalTime",
    "OffsetDateTime",
    "datetime_to_string",
)

# --- Constants for Tokenization ---
# NOTE: Character sets passed to lstrip()/rstrip() are kept in ASCII order.
# Bazel builds a CharMatcher.anyOf(chars) on every call, which sorts the
# characters; pre-sorted input makes that per-call sort significantly cheaper.
_BARE_KEY_CHARS = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
_BARE_KEY_DOT_CHARS = "-.0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
_HEX_CHARS = "0123456789ABCDEFabcdef"
_NUM_DATE_CHARS = " +-.0123456789:ETZ_etz"
_VALID_ASCII_CHARS = "\t\n !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
_TOML_ESCAPES = {
    "b": "\b",
    "t": "\t",
    "n": "\n",
    "f": "\f",
    "r": "\r",
    "\\": "\\",
    "\"": "\"",
    "e": "\033",
}

# Table path states stored in state["path_state"].
_TABLE_IMPLICIT = 1  # Auto-created intermediate table from [a.b]
_TABLE_DOTTED = 2  # Created or extended via dotted key (a.b = 1)
_TABLE_HEADER = 3  # Explicitly defined via [a.b]
_TABLE_AOT = 4  # Array of tables defined via [[a.b]]

# Multiplier applied to input length to bound loops substituting for 'while'.
_MAX_ITERATIONS_MULTIPLIER = 2

# Unicode replacement character (U+FFFD) and UTF-8 BOM (U+FEFF).
_REPLACEMENT_CHAR = json.decode('"\\uFFFD"')
_UTF8_BOM = json.decode('"\\uFEFF"')

_DAYS_31 = (1, 3, 5, 7, 8, 10, 12)
_DAYS_30 = (4, 6, 9, 11)

# --- Parser State & Error Handling ---

def _parser(data, default, datetime_formatter, max_depth):
    """Initializes the parser state dictionary."""
    root_dict = {}
    return {
        "pos": 0,
        "len": len(data),
        "data": data,
        "root": root_dict,
        "current_table": root_dict,
        "current_path": [],
        "current_parent": None,
        "current_parent_path": None,
        "current_aot_list": None,
        "error": None,
        "is_safe": False,
        "has_default": default != None,
        "path_state": {(): _TABLE_DOTTED},
        "bare_keys": {},
        "datetime_formatter": datetime_formatter,
        "max_depth": max_depth,
    }

def _fail(state, msg):
    """Records a parsing error and fails unless a default value was provided."""
    if state["error"] == None:
        state["error"] = msg

    if not state["has_default"]:
        fail(msg)

def _skip_ws(state, skip_nl = False):
    """Skips whitespace and comments in the input stream."""
    pos = state["pos"]
    length = state["len"]
    if pos >= length:
        return
    data = state["data"]
    skip_chars = " \t\n" if skip_nl else " \t"

    # Fast path for 1-2 whitespace chars or short whitespace runs.
    char = data[pos]
    if char in skip_chars:
        pos += 1
        if pos >= length:
            state["pos"] = pos
            return
        nc = data[pos]
        if nc in skip_chars:
            pos += 1
            if pos >= length:
                state["pos"] = pos
                return
            nc = data[pos]
        if nc not in skip_chars and nc != "#":
            state["pos"] = pos
            return
        if nc != "#":
            chunk = data[pos:pos + 64]
            stripped = chunk.lstrip(skip_chars)
            pos += len(chunk) - len(stripped)
            if stripped and stripped[0] != "#":
                state["pos"] = pos
                return
    elif char != "#":
        return

    # Slow path: long whitespace (>64 chars) or comments.
    for _ in range(length):
        if pos >= length:
            break

        char = data[pos]
        if char in skip_chars:
            chunk = data[pos:pos + 256]
            pos += len(chunk) - len(chunk.lstrip(skip_chars))
            continue

        if char == "#":
            newline_pos = data.find("\n", pos)
            comment_end = newline_pos if newline_pos != -1 else length
            comment_text = data[pos:comment_end]

            state["pos"] = pos
            if not _validate_text(state, comment_text, "comment", False):
                return
            pos = comment_end
            continue
        break
    state["pos"] = pos

def _expect(state, char):
    """Asserts that the next character in the stream is `char` and consumes it."""
    if state["error"] != None:
        return
    pos = state["pos"]
    if pos >= state["len"] or state["data"][pos] != char:
        _fail(state, "Expected '%s' at %d" % (char, pos))
        return
    state["pos"] = pos + 1

# --- Validation & Utility Helpers ---

def _validate_text(state, text, context, allow_nl = False):
    """Validates that text contains only valid TOML characters and UTF-8."""
    if not allow_nl and "\n" in text:
        _fail(state, "Control char in %s" % context)
        return False

    if state["is_safe"] or not text.lstrip(_VALID_ASCII_CHARS):
        return True

    # Byte-level UTF-8 and control character validation.
    length = len(text)
    idx = 0
    for _ in range(length):
        if idx >= length:
            return True
        char = text[idx]

        byte_len = 0
        if char <= "\177":
            byte_len = 1
            if char == "\r":
                msg = "Bare CR in %s" % context if allow_nl else "Control char in %s" % context
                _fail(state, msg)
                return False
            if (char < " " and char != "\t" and char != "\n") or char == "\177":
                _fail(state, "Control char in %s" % context)
                return False
        elif char >= "\302" and char <= "\337":
            byte_len = 2
        elif char >= "\340" and char <= "\357":
            byte_len = 3
            if char == "\355" and idx + 1 < length:
                next_char = text[idx + 1]
                if next_char >= "\240" and next_char <= "\277":
                    _fail(state, "Surrogate in %s" % context)
                    return False
        elif char >= "\360" and char <= "\364":
            byte_len = 4
        elif char == _REPLACEMENT_CHAR:
            _fail(state, "Invalid UTF-8 in %s" % context)
            return False
        else:
            _fail(state, "Invalid UTF-8 in %s" % context)
            return False

        if byte_len > 1:
            for j in range(1, byte_len):
                if idx + j >= length or not (text[idx + j] >= "\200" and text[idx + j] <= "\277"):
                    _fail(state, "Truncated UTF-8 in %s" % context)
                    return False
        idx += byte_len

    return True

def _is_hex(hex_str):
    return not hex_str.lstrip(_HEX_CHARS)

def _to_hex(val, width):
    s = "%x" % val
    return ("0" * (width - len(s))) + s if len(s) < width else s

def _is_valid_codepoint(code):
    return (0 <= code and code <= 0x10FFFF) and not (0xD800 <= code and code <= 0xDFFF)

def _codepoint_to_string(code):
    """Converts a Unicode codepoint to a Starlark string."""
    if code <= 0xFFFF:
        return json.decode('"\\u' + _to_hex(code, 4) + '"')
    v = code - 0x10000
    hi = 0xD800 + (v // 1024)
    lo = 0xDC00 + (v % 1024)
    return json.decode('"\\u' + _to_hex(hi, 4) + "\\u" + _to_hex(lo, 4) + '"')

def _is_leap(year):
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)

def _get_days_in_month(month, year):
    if month in _DAYS_31:
        return 31
    if month in _DAYS_30:
        return 30
    if month == 2:
        return 29 if _is_leap(year) else 28
    return 0

def _validate_date(state, year, month, day):
    if year < 0 or year > 9999 or month < 1 or month > 12 or day < 1 or day > _get_days_in_month(month, year):
        _fail(state, "Invalid date: %d-%d-%d" % (year, month, day))
        return False
    return True

def _validate_time(state, hour, minute, second):
    if hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 60:
        _fail(state, "Invalid time: %d:%d:%d" % (hour, minute, second))
        return False
    return True

def _validate_offset(state, hour, minute):
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        _fail(state, "Invalid offset: %d:%d" % (hour, minute))
        return False
    return True

# --- String Parsing ---

def _decode_unicode_escape(data, pos, esc):
    """Decodes a \\x, \\u, or \\U escape starting at `pos`. Returns (str, new_pos) or (None, pos)."""
    size = 2 if esc == "x" else (4 if esc == "u" else 8)
    hex_str = data[pos:pos + size]
    if len(hex_str) == size and _is_hex(hex_str):
        code = int(hex_str, 16)
        if _is_valid_codepoint(code):
            return _codepoint_to_string(code), pos + size
    return None, pos

# buildifier: disable=list-append
def _parse_basic_string(state):
    """Parses a basic string (double quoted)."""
    data = state["data"]
    length = state["len"]
    pos = state["pos"]

    if pos >= length or data[pos] != '"':
        _fail(state, "Expected '\"' at %d" % pos)
        return ""
    pos += 1

    if state["error"] != None:
        return ""

    quote_idx = data.find('"', pos)
    if quote_idx == -1:
        _fail(state, "Unterminated string")
        return ""

    # Fast path: no backslash escapes.
    chunk = data[pos:quote_idx]
    if "\\" not in chunk:
        if state["is_safe"]:
            if "\n" in chunk:
                _fail(state, "Control char in string")
                return ""
        elif not _validate_text(state, chunk, "string", False):
            return ""
        state["pos"] = quote_idx + 1
        return chunk

    # Slow path: process escape sequences in chunks.
    chars = []
    for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
        if pos >= length:
            _fail(state, "Unterminated string")
            return ""

        q_idx = data.find('"', pos)
        if q_idx == -1:
            _fail(state, "Unterminated string")
            return ""

        e_idx = data.find("\\", pos, q_idx)
        next_idx = e_idx if e_idx != -1 else q_idx

        if next_idx > pos:
            chunk = data[pos:next_idx]
            if not _validate_text(state, chunk, "string", False):
                return ""
            chars += [chunk]
            pos = next_idx

        if e_idx == -1:
            state["pos"] = pos + 1
            return "".join(chars)

        pos += 1
        if pos >= length:
            _fail(state, "Unterminated string")
            return ""
        esc = data[pos]
        pos += 1
        if esc in _TOML_ESCAPES:
            chars += [_TOML_ESCAPES[esc]]
            continue
        if esc == "x" or esc == "u" or esc == "U":
            decoded, new_pos = _decode_unicode_escape(data, pos, esc)
            if decoded != None:
                chars += [decoded]
                pos = new_pos
                continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_literal_string(state):
    """Parses a literal string (single quoted)."""
    pos = state["pos"]
    data = state["data"]
    length = state["len"]
    if pos >= length or data[pos] != "'":
        _fail(state, "Expected \"'\" at %d" % pos)
        return ""
    pos += 1

    idx = data.find("'", pos)
    if idx == -1:
        _fail(state, "Unterminated literal string")
        return ""
    content = data[pos:idx]
    if not _validate_text(state, content, "literal string", False):
        return ""
    state["pos"] = idx + 1
    return content

# buildifier: disable=list-append
def _parse_multiline_basic_string(state):
    """Parses a multi-line basic string (triple double quoted)."""
    data = state["data"]
    length = state["len"]
    pos = state["pos"] + 3  # Caller verified opening '"""'

    if pos < length and data[pos] == "\n":
        pos += 1

    chars = []
    for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
        if pos >= length:
            _fail(state, "Unterminated multiline string")
            return ""

        q_idx = data.find('"""', pos)
        if q_idx == -1:
            _fail(state, "Unterminated multiline string")
            return ""

        e_idx = data.find("\\", pos, q_idx)
        next_idx = e_idx if e_idx != -1 else q_idx

        if next_idx > pos:
            chunk = data[pos:next_idx]
            if not _validate_text(state, chunk, "multiline string", True):
                return ""
            chars += [chunk]

        pos = next_idx
        if e_idx == -1:
            # Up to two extra quotes immediately before closing '"""' belong to content.
            pos += 3
            if pos < length and data[pos] == '"':
                chars += ['"']
                pos += 1
                if pos < length and data[pos] == '"':
                    chars += ['"']
                    pos += 1
            state["pos"] = pos
            return "".join(chars)

        pos += 1
        if pos >= length:
            break
        esc = data[pos]
        if esc in " \t\n\r":
            # Line-ending backslash: skip spaces/tabs to newline, then all whitespace/newlines.
            tp = pos
            for _ in range(length - tp):
                if tp >= length:
                    break
                c = data[tp]
                if c == " " or c == "\t":
                    tp += 1
                    continue
                break

            found_nl = False
            if tp < length and data[tp] == "\r":
                tp += 1
            if tp < length and data[tp] == "\n":
                tp += 1
                found_nl = True
                for _ in range(length - tp):
                    if tp >= length:
                        break
                    c = data[tp]
                    if c == " " or c == "\t" or c == "\n" or c == "\r":
                        tp += 1
                        continue
                    break
            if not found_nl:
                _fail(state, "Invalid backslash escape")
                return ""

            pos = tp
            continue

        if esc in _TOML_ESCAPES:
            chars += [_TOML_ESCAPES[esc]]
            pos += 1
            continue
        if esc == "x" or esc == "u" or esc == "U":
            decoded, new_pos = _decode_unicode_escape(data, pos + 1, esc)
            if decoded != None:
                chars += [decoded]
                pos = new_pos
                continue
        _fail(state, "Invalid escape")
        return ""
    return ""

def _parse_multiline_literal_string(state):
    """Parses a multiline literal string (triple single quoted)."""
    data = state["data"]
    length = state["len"]
    pos = state["pos"] + 3  # Caller verified opening "'''"

    if pos < length and data[pos] == "\n":
        pos += 1

    idx = data.find("'''", pos)
    if idx == -1:
        _fail(state, "Unterminated multiline literal string")
        return ""

    # Up to two extra single quotes immediately before closing "'''" belong to content.
    ex = 0
    if idx + 3 < length and data[idx + 3] == "'":
        ex = 1
        if idx + 4 < length and data[idx + 4] == "'":
            ex = 2
    content = data[pos:idx + ex]
    if not _validate_text(state, content, "multiline literal", True):
        return ""

    state["pos"] = idx + 3 + ex
    return content

def _parse_string(state):
    """Dispatches to the appropriate string parsing function based on quotes."""
    p = state["pos"]
    d = state["data"]
    if d[p] == '"':
        if p + 2 < state["len"] and d[p + 1] == '"' and d[p + 2] == '"':
            return _parse_multiline_basic_string(state)
        return _parse_basic_string(state)
    if d[p] == "'":
        if p + 2 < state["len"] and d[p + 1] == "'" and d[p + 2] == "'":
            return _parse_multiline_literal_string(state)
        return _parse_literal_string(state)
    return ""

# --- Keys & Tables ---

def _parse_key(state):
    """Parses a TOML key (bare, basic, or literal)."""
    pos = state["pos"]
    data = state["data"]
    length = state["len"]
    if pos >= length:
        _fail(state, "Expected key")
        return ""

    if data[pos] == '"':
        if pos + 2 < length and data[pos + 1:pos + 3] == '""':
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_basic_string(state)
    if data[pos] == "'":
        if pos + 2 < length and data[pos + 1:pos + 3] == "''":
            _fail(state, "Multiline key not allowed")
            return ""
        return _parse_literal_string(state)

    # Bare keys: [A-Za-z0-9_-]+
    start = pos

    # Fast path: most bare keys are < 64 chars.
    window = data[pos:pos + 64]
    stripped = window.lstrip(_BARE_KEY_CHARS)
    if stripped:
        if stripped == window:
            _fail(state, "Invalid key format")
            return ""
        end = pos + len(window) - len(stripped)
        state["pos"] = end
        return data[start:end]

    pos += len(window)
    for _ in range(length):
        if pos >= length:
            break
        window = data[pos:pos + 64]
        stripped = window.lstrip(_BARE_KEY_CHARS)
        consumed = len(window) - len(stripped)
        pos += consumed
        if consumed < len(window):
            break

    if pos > start:
        state["pos"] = pos
        return data[start:pos]

    _fail(state, "Invalid key format")
    return ""

# buildifier: disable=list-append
def _parse_dotted_key(state):
    """Parses a dotted key into a list of components."""
    pos = state["pos"]
    data = state["data"]
    length = state["len"]

    # Fast path: simple undotted bare key followed by " = ".
    eq = data.find(" = ", pos, pos + 64)
    if eq > pos:
        raw = data[pos:eq]
        bare_keys = state["bare_keys"]
        if raw in bare_keys:
            state["pos"] = eq + 1
            return [raw]
        if (state["is_safe"] and raw.isalnum()) or ("\n" not in raw and not raw.lstrip(_BARE_KEY_CHARS)):
            bare_keys[raw] = True
            state["pos"] = eq + 1
            return [raw]

    # Fast path: bare / dotted-bare keys (< 64 chars, no quotes or spaces around dots).
    if pos < length:
        window = data[pos:pos + 64]
        stripped = window.lstrip(_BARE_KEY_DOT_CHARS)
        if stripped and stripped != window:
            next_c = stripped[0]
            if next_c == "=" or next_c == "]" or (next_c == " " and stripped[1:2] == "="):
                end = pos + len(window) - len(stripped)
                raw = data[pos:end]
                if "." not in raw:
                    state["pos"] = end + (1 if next_c == " " else 0)
                    return [raw]
                if raw[0] != "." and raw[-1] != "." and ".." not in raw:
                    state["pos"] = end + (1 if next_c == " " else 0)
                    return raw.split(".")

    keys = []
    for _ in range(length):
        _skip_ws(state)
        k = _parse_key(state)
        if state["error"] != None:
            return keys
        keys += [k]
        _skip_ws(state)
        if state["pos"] < length and data[state["pos"]] == ".":
            state["pos"] += 1
            continue
        break
    return keys

# buildifier: disable=list-append
def _get_or_create_table(state, keys, is_array):
    """Navigates to or creates the table structure specified by the dotted keys."""
    cur_path = state["current_path"]

    # Shortcut: consecutive identical [[aot]] header appends directly to the active AOT list.
    if is_array and state["current_aot_list"] != None and keys == cur_path:
        new_elem = {}
        state["current_aot_list"] += [new_elem]
        state["current_table"] = new_elem
        return new_elem

    path_state = state["path_state"]
    full_path_tuple = tuple(keys)
    parent_path = keys[:-1]

    # Shortcut: sibling table under the same parent skips ancestor traversal.
    if state["current_parent"] != None and parent_path == state["current_parent_path"]:
        current = state["current_parent"]
    else:
        current = state["root"]
        for i in range(len(keys) - 1):
            key = keys[i]
            path_tuple = full_path_tuple[:i + 1]
            if key in current:
                if path_tuple not in path_state:
                    _fail(state, "Traversal conflict with %s" % key)
                    return {}
                st = path_state[path_tuple]
                existing = current[key]
                if st == _TABLE_AOT:
                    if not existing:
                        _fail(state, "Empty AOT conflict")
                        return {}
                    current = existing[-1]
                else:
                    current = existing
            else:
                new_tab = {}
                current[key] = new_tab
                current = new_tab
                path_state[path_tuple] = _TABLE_IMPLICIT

    last_key = keys[-1]
    path_tuple = full_path_tuple
    if is_array:
        if last_key in current:
            if path_tuple not in path_state or path_state[path_tuple] != _TABLE_AOT:
                _fail(state, "AOT conflict on %s" % last_key)
                return {}
            aot_list = current[last_key]
            new_elem = {}
            aot_list += [new_elem]
        else:
            new_elem = {}
            aot_list = [new_elem]
            current[last_key] = aot_list
            path_state[path_tuple] = _TABLE_AOT
        state["current_path"] = keys
        state["current_parent"] = current
        state["current_parent_path"] = parent_path
        state["current_aot_list"] = aot_list
        state["current_table"] = new_elem
        return new_elem

    if last_key in current:
        if path_tuple not in path_state or path_state[path_tuple] != _TABLE_IMPLICIT:
            _fail(state, "Redefinition or conflict on %s" % last_key)
            return {}
        path_state[path_tuple] = _TABLE_HEADER
        tab = current[last_key]
    else:
        tab = {}
        current[last_key] = tab
        path_state[path_tuple] = _TABLE_HEADER
    state["current_path"] = keys
    state["current_parent"] = current
    state["current_parent_path"] = parent_path
    state["current_aot_list"] = None
    state["current_table"] = tab
    return tab

def _parse_table(state):
    """Parses a table header [foo.bar] or [[foo.bar]]."""
    pos = state["pos"] + 1  # Caller already verified data[pos] == "["
    is_array_of_tables = False
    if pos < state["len"] and state["data"][pos] == "[":
        is_array_of_tables = True
        pos += 1
    state["pos"] = pos
    keys = _parse_dotted_key(state)
    _expect(state, "]")
    if is_array_of_tables:
        _expect(state, "]")
    if state["error"] != None:
        return
    _get_or_create_table(state, keys, is_array_of_tables)

def _parse_key_value(state, target):
    """Parses a key = value pair and inserts it into the target dictionary."""
    keys = _parse_dotted_key(state)
    if state["error"] != None or not keys:
        return

    # Inlined '=' and whitespace check (most lines use "key = value").
    data = state["data"]
    length = state["len"]
    pos = state["pos"]
    if pos >= length or data[pos] != "=":
        _fail(state, "Expected '=' at %d" % pos)
        return
    pos += 1
    if pos < length and data[pos] == " ":
        pos += 1
    state["pos"] = pos
    if pos < length and data[pos] in " \t":
        _skip_ws(state)
    value = _parse_value(state)
    if state["error"] != None:
        return

    current = target
    if len(keys) > 1:
        base_path = state["current_path"]
        path_state = state["path_state"]
        for i in range(len(keys) - 1):
            k = keys[i]
            path_tuple = tuple(base_path + keys[:i + 1])
            if k in current:
                st = path_state[path_tuple] if path_tuple in path_state else None
                if st != _TABLE_IMPLICIT and st != _TABLE_DOTTED:
                    _fail(state, "Key conflict with %s" % k)
                    return
                path_state[path_tuple] = _TABLE_DOTTED
                current = current[k]
            else:
                new_tab = {}
                current[k] = new_tab
                path_state[path_tuple] = _TABLE_DOTTED
                current = new_tab

    last_key = keys[-1]
    if last_key in current:
        _fail(state, "Redefinition of " + last_key)
    current[last_key] = value

# --- Scalar & Temporal Parsing ---

def _parse_int_base(state, prefix, valid_chars, base):
    """Parses a hex, octal, or binary integer."""
    pos = state["pos"] + len(prefix)
    data = state["data"]
    length = state["len"]
    start = pos

    idx = pos
    for _ in range(length):
        if idx >= length:
            break
        c = data[idx]
        if c == "_" or c in valid_chars:
            idx += 1
            continue
        break

    if idx == start:
        return None

    val_str = data[start:idx]
    if val_str.startswith("_") or val_str.endswith("_") or "__" in val_str:
        return None

    state["pos"] = idx
    return int(val_str.replace("_", ""), base)

def _scan_digits(text, idx, length):
    """Scans decimal digits with TOML single-underscore separators starting at `idx`.

    Caller must ensure text[idx] is a digit. Returns the end index, or -1 on invalid underscore.
    """
    for _ in range(length - idx):
        if idx >= length:
            break
        c = text[idx]
        if c.isdigit():
            idx += 1
        elif c == "_":
            if idx + 1 >= length or not text[idx + 1].isdigit():
                return -1
            idx += 1
        else:
            break
    return idx

def _parse_number_strict(text):
    """Returns True if `text` is a strictly valid TOML integer or float."""
    idx = 0
    length = len(text)

    # 1. Optional sign
    if idx < length and (text[idx] == "+" or text[idx] == "-"):
        idx += 1
    if idx >= length:
        return False

    # 2. Integer part
    if text[idx] == "0":
        idx += 1
        if idx < length and text[idx] not in ".eE":
            return False
    elif text[idx].isdigit():
        idx = _scan_digits(text, idx, length)
        if idx == -1:
            return False
    else:
        return False

    # 3. Optional fraction part
    if idx < length and text[idx] == ".":
        idx += 1
        if idx >= length or not text[idx].isdigit():
            return False
        idx = _scan_digits(text, idx, length)
        if idx == -1:
            return False

    # 4. Optional exponent part
    if idx < length and (text[idx] == "e" or text[idx] == "E"):
        idx += 1
        if idx < length and (text[idx] == "+" or text[idx] == "-"):
            idx += 1
        if idx >= length or not text[idx].isdigit():
            return False
        idx = _scan_digits(text, idx, length)
        if idx == -1:
            return False

    return idx == length

def _parse_datetime_strict(text):
    """Parses a TOML date or datetime string into component fields, or None."""
    if len(text) < 10 or text[4] != "-" or text[7] != "-":
        return None

    year_s = text[:4]
    month_s = text[5:7]
    day_s = text[8:10]
    if not (year_s.isdigit() and month_s.isdigit() and day_s.isdigit()):
        return None

    res = {
        "year": int(year_s),
        "month": int(month_s),
        "day": int(day_s),
        "hour": None,
        "minute": None,
        "second": None,
        "microsecond": 0,
        "offset": None,
    }

    if len(text) == 10:
        return res

    sep = text[10]
    if sep != "T" and sep != "t" and sep != " ":
        return None

    time_part = text[11:]
    if len(time_part) < 5 or time_part[2] != ":":
        return None

    hour_s = time_part[:2]
    minute_s = time_part[3:5]
    if not (hour_s.isdigit() and minute_s.isdigit()):
        return None

    res["hour"] = int(hour_s)
    res["minute"] = int(minute_s)
    res["second"] = 0

    processed_len = 5
    if len(time_part) >= 8 and time_part[5] == ":":
        second_s = time_part[6:8]
        if not second_s.isdigit():
            return None
        res["second"] = int(second_s)
        processed_len = 8

    rest = time_part[processed_len:]

    if rest.startswith("."):
        tail = rest[1:]
        rest = tail.lstrip("0123456789")
        frac_s = tail[:len(tail) - len(rest)]
        if not frac_s:
            return None
        res["microsecond"] = int((frac_s + "000000")[:6])

    if not rest:
        return res

    if rest == "Z" or rest == "z":
        res["offset"] = 0
        return res

    if len(rest) == 6 and (rest[0] == "+" or rest[0] == "-") and rest[3] == ":":
        oh_s = rest[1:3]
        om_s = rest[4:6]
        if not (oh_s.isdigit() and om_s.isdigit()) or int(om_s) >= 60:
            return None
        sign = 1 if rest[0] == "+" else -1
        res["offset"] = sign * (int(oh_s) * 60 + int(om_s))
        return res

    return None

def _parse_time_strict(text):
    """Parses a TOML local time string HH:MM(:SS(.frac)?)?."""
    if len(text) < 5 or text[2] != ":":
        return None

    hour_s = text[:2]
    minute_s = text[3:5]
    if not (hour_s.isdigit() and minute_s.isdigit()):
        return None

    res = {
        "hour": int(hour_s),
        "minute": int(minute_s),
        "second": 0,
        "microsecond": 0,
    }

    if len(text) == 5:
        return res

    if len(text) < 8 or text[5] != ":":
        return None

    second_s = text[6:8]
    if not second_s.isdigit():
        return None
    res["second"] = int(second_s)

    rest = text[8:]
    if rest.startswith("."):
        if not rest[1:].isdigit():
            return None
        res["microsecond"] = int((rest[1:] + "000000")[:6])
    elif rest:
        return None

    return res

def _parse_scalar(state):
    """Parses a scalar TOML value (boolean, number, inf/nan, or temporal)."""
    pos = state["pos"]
    data = state["data"]
    length = state["len"]
    char = data[pos]

    # Booleans and unsigned inf/nan.
    if char == "t":
        if data.startswith("true", pos):
            state["pos"] = pos + 4
            return True
    elif char == "f":
        if data.startswith("false", pos):
            state["pos"] = pos + 5
            return False
    elif char == "i":
        if data.startswith("inf", pos):
            state["pos"] = pos + 3
            return float("inf")
    elif char == "n":
        if data.startswith("nan", pos):
            state["pos"] = pos + 3
            return float("nan")
    elif char.isdigit() or char == "+" or char == "-":
        # Base-prefixed integers (0x, 0o, 0b).
        if char == "0" and pos + 1 < length:
            next_char = data[pos + 1]
            if next_char == "x":
                val = _parse_int_base(state, "0x", _HEX_CHARS, 16)
                if val != None:
                    return val
                _fail(state, "Invalid hex integer")
                return None
            if next_char == "o":
                val = _parse_int_base(state, "0o", "01234567", 8)
                if val != None:
                    return val
                _fail(state, "Invalid octal integer")
                return None
            if next_char == "b":
                val = _parse_int_base(state, "0b", "01", 2)
                if val != None:
                    return val
                _fail(state, "Invalid binary integer")
                return None

        # Signed inf/nan (+inf, -inf, +nan, -nan).
        if (char == "+" or char == "-") and pos + 1 < length:
            c2 = data[pos + 1]
            if c2 == "i" and data.startswith("inf", pos + 1):
                state["pos"] = pos + 4
                val = float("inf")
                return val if char == "+" else -val
            if c2 == "n" and data.startswith("nan", pos + 1):
                state["pos"] = pos + 4
                return float("nan")

        # Scan full number/date/time token using a single windowed lstrip.
        start = pos
        window = data[pos:pos + 64]
        idx = pos + len(window) - len(window.lstrip(_NUM_DATE_CHARS))
        if idx == pos + 64:
            for _ in range(length):
                if idx >= length or data[idx] not in _NUM_DATE_CHARS:
                    break
                idx += 1

        token_candidate = data[start:idx]

        # Fast path: plain decimal integer.
        if token_candidate.isdigit() and (token_candidate[0] != "0" or len(token_candidate) == 1):
            state["pos"] = idx
            return int(token_candidate)

        # Datetime / Date.
        if "-" in token_candidate and len(token_candidate) >= 10:
            clean_token = token_candidate.rstrip()
            dt = _parse_datetime_strict(clean_token)
            if dt:
                year, month, day = dt["year"], dt["month"], dt["day"]
                if not _validate_date(state, year, month, day):
                    return None

                hour = dt["hour"]
                if hour != None:
                    if not _validate_time(state, hour, dt["minute"], dt["second"]):
                        return None

                    offset = dt["offset"]
                    if offset != None:
                        if not _validate_offset(state, abs(offset) // 60, abs(offset) % 60):
                            return None
                        res = OffsetDateTime(year, month, day, hour, dt["minute"], dt["second"], dt["microsecond"], offset)
                    else:
                        res = LocalDateTime(year, month, day, hour, dt["minute"], dt["second"], dt["microsecond"])
                else:
                    res = LocalDate(year, month, day)

                state["pos"] += len(clean_token)
                if state["datetime_formatter"]:
                    return state["datetime_formatter"](res)
                return res

        # Local Time.
        if ":" in token_candidate and len(token_candidate) >= 5:
            token_no_space = token_candidate.split(" ")[0]
            tm = _parse_time_strict(token_no_space)
            if tm:
                if not _validate_time(state, tm["hour"], tm["minute"], tm["second"]):
                    return None

                res = LocalTime(tm["hour"], tm["minute"], tm["second"], tm["microsecond"])
                state["pos"] += len(token_no_space)
                if state["datetime_formatter"]:
                    return state["datetime_formatter"](res)
                return res

        # Number (signed int, underscored int, or float).
        first_part = token_candidate.split(" ")[0]
        if _parse_number_strict(first_part):
            state["pos"] += len(first_part)
            cleaned = first_part.replace("_", "")
            if "." in cleaned or "e" in cleaned or "E" in cleaned:
                return float(cleaned)
            return int(cleaned)

        _fail(state, "Invalid scalar (number/date) format: " + token_candidate)
        return None

    _fail(state, "Invalid scalar value")
    return None

# --- Arrays & Inline Tables ---

_MODE_ARRAY_VAL = 1
_MODE_ARRAY_COMMA = 2
_MODE_TABLE_KEY = 3
_MODE_TABLE_VAL = 4
_MODE_TABLE_COMMA = 5

# buildifier: disable=list-append
def _parse_complex_iterative(state, initial_array = None, initial_mode = _MODE_ARRAY_VAL):
    """Parses inline tables and arrays iteratively using a manual stack.

    When `initial_array` is provided, resumes parsing an already-opened array
    from `state["pos"]` in `initial_mode`.
    """
    data = state["data"]
    length = state["len"]
    pos = state["pos"]

    if initial_array != None:
        res = initial_array
        stack = [[res, initial_mode, None, {}]]
    else:
        char = data[pos]
        res = [] if char == "[" else {}
        stack = [[res, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
        pos += 1

    for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
        state["pos"] = pos
        if not stack or state["error"] != None:
            return res
        fr = stack[-1]
        cont = fr[0]
        mode = fr[1]

        if pos >= length:
            _fail(state, "EOF in complex")
            return res
        char = data[pos]
        if char == " ":
            # Fast path: single space separator (e.g. after "{", ",", or "=").
            pos += 1
            state["pos"] = pos
            if pos >= length:
                _fail(state, "EOF in complex")
                return res
            char = data[pos]
        if char == " " or char == "\n" or char == "\t" or char == "#":
            _skip_ws(state, True)
            pos = state["pos"]
            if pos >= length:
                _fail(state, "EOF in complex")
                return res
            char = data[pos]

        if mode <= 2:  # Array modes
            if mode == _MODE_ARRAY_VAL:
                if char == "]":
                    pos += 1
                    state["pos"] = pos
                    stack.pop()
                    continue
                if char == "[" or char == "{":
                    if state["max_depth"] != None and len(stack) >= state["max_depth"]:
                        _fail(state, "Max nesting depth exceeded")
                        return res
                    new_container = [] if char == "[" else {}
                    cont += [new_container]
                    pos += 1
                    state["pos"] = pos
                    stack += [[new_container, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
                    fr[1] = _MODE_ARRAY_COMMA
                    continue
                val = _parse_string(state) if char == '"' or char == "'" else _parse_scalar(state)
                pos = state["pos"]
                if val != None:
                    cont += [val]
                    fr[1] = _MODE_ARRAY_COMMA
                    continue
                _fail(state, "Value expected in array")
            else:  # _MODE_ARRAY_COMMA
                if char == "]":
                    pos += 1
                    state["pos"] = pos
                    stack.pop()
                    continue
                if char == ",":
                    pos += 1
                    state["pos"] = pos
                    fr[1] = _MODE_ARRAY_VAL
                    continue
                _fail(state, "Array comma expected")
        else:  # Inline table modes
            if mode == _MODE_TABLE_KEY:
                if char == "}":
                    pos += 1
                    state["pos"] = pos
                    stack.pop()
                    continue
                ks = _parse_dotted_key(state)
                if state["error"] != None:
                    return res

                pos = state["pos"]
                if pos >= length or data[pos] != "=":
                    _fail(state, "Expected '=' at %d" % pos)
                    return res
                pos += 1
                fr[2] = ks
                fr[1] = _MODE_TABLE_VAL
            elif mode == _MODE_TABLE_VAL:
                ks = fr[2]
                explicit_map = fr[3]

                top_k = ks[0]
                is_dotted = len(ks) > 1
                was_dotted = explicit_map[top_k] if top_k in explicit_map else None

                if was_dotted != None:
                    if not is_dotted:
                        _fail(state, "Duplicate key " + top_k)
                        return res
                    if not was_dotted:
                        _fail(state, "Key conflict " + top_k)
                        return res
                else:
                    explicit_map[top_k] = is_dotted

                is_nested = char == "[" or char == "{"
                if is_nested:
                    if state["max_depth"] != None and len(stack) >= state["max_depth"]:
                        _fail(state, "Max nesting depth exceeded")
                        return res
                    val = [] if char == "[" else {}
                else:
                    val = _parse_string(state) if char == '"' or char == "'" else _parse_scalar(state)
                    pos = state["pos"]
                    if state["error"] != None:
                        return res

                current = cont
                if is_dotted:
                    for k in ks[:-1]:
                        if k not in current:
                            current[k] = {}
                        current = current[k]
                        if type(current) != "dict":
                            _fail(state, "Key conflict")
                            return res
                last_k = ks[-1]
                if last_k in current:
                    _fail(state, "Duplicate key %s" % last_k)
                    return res
                current[last_k] = val

                if is_nested:
                    stack += [[val, _MODE_ARRAY_VAL if char == "[" else _MODE_TABLE_KEY, None, {}]]
                    fr[1] = _MODE_TABLE_COMMA
                    pos += 1
                    state["pos"] = pos
                else:
                    fr[1] = _MODE_TABLE_COMMA
            else:  # _MODE_TABLE_COMMA
                if char == "}":
                    pos += 1
                    state["pos"] = pos
                    stack.pop()
                    continue
                if char == ",":
                    pos += 1
                    state["pos"] = pos
                    fr[1] = _MODE_TABLE_KEY
                    continue
                _fail(state, "Inline table comma expected")
    return res

def _parse_value(state):
    """Dispatches parsing to scalars, strings, or complex structures.

    Callers must skip whitespace before calling this function.
    """
    pos = state["pos"]
    if pos >= state["len"]:
        _fail(state, "Value expected at EOF")
        return None
    char = state["data"][pos]
    if char == "[" or char == "{":
        return _parse_complex_iterative(state)
    if char == '"' or char == "'":
        return _parse_string(state)
    res = _parse_scalar(state)
    if res == None and state["error"] == None:
        _fail(state, "Value expected")
    return res

# --- toml-test Expansion ---

_TEST_TEMPORAL_TYPES = {
    "OffsetDateTime": "datetime",
    "LocalDateTime": "datetime-local",
    "LocalDate": "date-local",
    "LocalTime": "time-local",
}

def _format_scalar_for_test(v):
    """Formats a scalar value into the `toml-test` JSON-compatible structure."""
    t = type(v)
    if t == "bool":
        return {"type": "bool", "value": "true" if v else "false"}
    if t == "int":
        return {"type": "integer", "value": str(v)}
    if t == "float":
        s = str(v)
        if s == "+inf":
            s = "inf"
        return {"type": "float", "value": s}
    if t == "string":
        return {"type": "string", "value": v}
    if t == "struct":
        tt = getattr(v, "_toml_type", None)
        if tt in _TEST_TEMPORAL_TYPES:
            return {"type": _TEST_TEMPORAL_TYPES[tt], "value": datetime_to_string(v)}
    return None

def _expand_to_toml_test(raw, size_hint):
    """Converts a decoded Starlark structure into the `toml-test` format."""
    root = {} if type(raw) == "dict" else []
    stack = [[raw, root]]
    for _ in range(size_hint * 2 + 100):
        if not stack:
            break
        raw_node, target_node = stack.pop()
        if type(raw_node) == "dict":
            for key, value in raw_node.items():
                vt = type(value)
                if vt == "dict" or vt == "list":
                    child = {} if vt == "dict" else []
                    target_node[key] = child
                    stack.append([value, child])
                else:
                    target_node[key] = _format_scalar_for_test(value)
        else:
            for value in raw_node:
                vt = type(value)
                if vt == "dict" or vt == "list":
                    child = {} if vt == "dict" else []
                    target_node.append(child)
                    stack.append([value, child])
                else:
                    target_node.append(_format_scalar_for_test(value))
    return root

def _is_globally_safe(data):
    """Returns True if the document contains only printable ASCII, tabs, and newlines."""
    return not data.lstrip(_VALID_ASCII_CHARS)

def _consume_eol(state):
    """Verifies and consumes trailing whitespace, comment, and newline/EOF after a statement."""
    data = state["data"]
    length = state["len"]
    pos = state["pos"]
    if pos >= length:
        return
    if data[pos] == "\n":
        state["pos"] = pos + 1
        return
    _skip_ws(state)
    pos = state["pos"]
    if pos >= length:
        return
    char = data[pos]
    if char == "\n":
        state["pos"] = pos + 1
        return
    if char != "\r" and char != "#":
        _fail(state, "Expected newline or EOF")

def _parse_one_statement(state):
    """Parses one top-level statement at `state["pos"]` and consumes through its newline."""
    data = state["data"]
    length = state["len"]
    pos = state["pos"]
    if pos >= length:
        return
    char = data[pos]
    if char == " " or char == "\n" or char == "\t" or char == "#":
        _skip_ws(state, True)
        pos = state["pos"]
        if pos >= length:
            return
        char = data[pos]

    if char == "[":
        _parse_table(state)
    else:
        _parse_key_value(state, state["current_table"])

    if state["error"] != None:
        return
    _consume_eol(state)

def _is_bare_key_ascii(k, bare_keys):
    """Checks and caches whether `k` is a non-empty ASCII bare key (caller guarantees ASCII)."""
    if k in bare_keys:
        return True
    if k and (k.isalnum() or not k.lstrip(_BARE_KEY_CHARS)):
        bare_keys[k] = True
        return True
    return False

def _parse_flat_inline_table(body, bare_keys, allow_nested):
    """Fast-path parser for single-line flat inline tables in safe ASCII documents.

    Accepts `{ k = v, ... }` where keys are bare keys (or bare dotted keys like
    `version.ref` / `a.b.c`) and values are unescaped basic strings, plain decimal integers,
    booleans, or empty/single-string arrays (when `allow_nested` is True). Returns the decoded
    dict, or None to fall back.
    """
    if body and body[0] == " " and body[-1] == " ":
        body = body[1:-1]
    if body and (body[0] == " " or body[0] == "\t" or body[-1] == " " or body[-1] == "\t"):
        body = body.strip()
    if not body:
        return {}
    if "{" in body or "}" in body or "\\" in body:
        return None

    parts = [body] if ", " not in body else body.split(", ")
    d = {}
    for part in parts:
        pk, peq, pv = part.partition(" = ")
        if not peq or not pv:
            return None
        target = d
        if pk in bare_keys or _is_bare_key_ascii(pk, bare_keys):
            if pk in d:
                return None
        elif "." in pk:
            segs = pk.split(".")
            for seg in segs[:-1]:
                if seg not in bare_keys and not _is_bare_key_ascii(seg, bare_keys):
                    return None
                if seg in target:
                    target = target[seg]
                    if type(target) != "dict":
                        return None
                else:
                    new_d = {}
                    target[seg] = new_d
                    target = new_d
            pk = segs[-1]
            if (pk not in bare_keys and not _is_bare_key_ascii(pk, bare_keys)) or pk in target:
                return None
        else:
            return None

        pv0 = pv[0]
        if pv0 == '"':
            if pv[-1] != '"' or pv == '"':
                return None
            inner = pv[1:-1]
            if '"' in inner:
                return None
            target[pk] = inner
        elif pv0 >= "0" and pv0 <= "9":
            if not pv.isdigit() or (pv0 == "0" and pv != "0"):
                return None
            target[pk] = int(pv)
        elif pv == "true":
            target[pk] = True
        elif pv == "false":
            target[pk] = False
        elif pv0 == "[" and pv[-1] == "]" and allow_nested:
            sv = pv[1:-1]
            if not sv:
                target[pk] = []
            elif sv[0] == '"' and sv[-1] == '"' and sv != '"' and '"' not in sv[1:-1]:
                target[pk] = [sv[1:-1]]
            else:
                return None
        else:
            return None
    return d

def _parse_single_line_complex(elem, state, depth_offset):
    """Attempts to parse a self-contained single-line `{...}` or `[...]` value.

    Returns `(True, value)` on success when the entire `elem` is consumed, or `(False, None)`
    to let the caller fall back to the full document parser.
    """
    max_depth = state["max_depth"]
    mini = {
        "pos": 0,
        "len": len(elem),
        "data": elem,
        "error": None,
        "is_safe": True,
        "has_default": True,
        "bare_keys": state["bare_keys"],
        "datetime_formatter": state["datetime_formatter"],
        "max_depth": max_depth - depth_offset if max_depth != None else None,
    }
    val = _parse_complex_iterative(mini)
    if mini["error"] == None and mini["pos"] == mini["len"]:
        return True, val
    return False, None

# buildifier: disable=list-append
def _decode_fast(state):
    """Line-oriented fast path for safe ASCII documents, falling back to offset parsing."""
    data = state["data"]
    length = state["len"]
    lines = data.split("\n")
    num_lines = len(lines)
    bare_keys = state["bare_keys"]
    max_depth = state["max_depth"]
    allow_depth_1 = max_depth == None or max_depth >= 1
    allow_depth_2 = max_depth == None or max_depth >= 2
    allow_depth_3 = max_depth == None or max_depth >= 3

    line_idx = 0
    pos_line = 0
    pos_offset = 0
    current_table = state["current_table"]
    last_aot_line = ""
    last_aot_list = None

    for _ in range(num_lines):
        if line_idx >= num_lines:
            break
        line = lines[line_idx]
        if not line:
            line_idx += 1
            continue

        c0 = line[0]
        if c0 == " " or c0 == "\t":
            s = line.strip()
            if not s or s[0] == "#":
                line_idx += 1
                continue
            c0 = s[0]
        elif c0 == "#":
            line_idx += 1
            continue
        else:
            s = line

        # 1. Table / Array-of-tables header.
        if c0 == "[":
            # Fast path for repeated identical [[aot]] headers (e.g. [[package]]).
            if s == last_aot_line and last_aot_list != None:
                new_elem = {}
                last_aot_list += [new_elem]
                current_table = new_elem
                state["current_table"] = new_elem
                line_idx += 1
                continue

            if s[-1] == "]":
                is_aot = s[1:2] == "[" and s[-2:-1] == "]"
                if is_aot or s[1:2] != "[":
                    raw = s[2:-2] if is_aot else s[1:-1]
                    if "." not in raw:
                        parts = [raw] if (raw in bare_keys or _is_bare_key_ascii(raw, bare_keys)) else None
                    else:
                        parts = raw.split(".")
                        for p in parts:
                            if p not in bare_keys and not _is_bare_key_ascii(p, bare_keys):
                                parts = None
                                break
                    if parts != None:
                        current_table = _get_or_create_table(state, parts, is_aot)
                        if state["error"] != None:
                            return
                        if is_aot:
                            last_aot_line = s
                            last_aot_list = state["current_aot_list"]
                        else:
                            last_aot_line = ""
                            last_aot_list = None
                        line_idx += 1
                        continue
        else:
            # 2. Key-value statement: `bare_key = value`.
            k, eq, v = s.partition(" = ")
            if eq and v and k not in current_table and (k in bare_keys or _is_bare_key_ascii(k, bare_keys)):
                v0 = v[0]
                if v0 == '"':
                    if v[-1] == '"' and v != '"':
                        inner = v[1:-1]
                        if '"' not in inner and "\\" not in inner:
                            current_table[k] = inner
                            line_idx += 1
                            continue
                elif v == "true":
                    current_table[k] = True
                    line_idx += 1
                    continue
                elif v == "false":
                    current_table[k] = False
                    line_idx += 1
                    continue
                elif v0 >= "0" and v0 <= "9":
                    if v.isdigit() and (v0 != "0" or v == "0"):
                        current_table[k] = int(v)
                        line_idx += 1
                        continue
                elif v0 == "{" and v[-1] == "}" and allow_depth_1:
                    d = _parse_flat_inline_table(v[1:-1], bare_keys, allow_depth_2)
                    if d != None:
                        current_table[k] = d
                        line_idx += 1
                        continue
                elif v == "[" and allow_depth_1:
                    # Multiline array fast path.
                    arr = []
                    need_comma = False
                    closed = False
                    fallback_idx = -1
                    for i in range(line_idx + 1, num_lines):
                        raw_al = lines[i]
                        if not raw_al:
                            continue
                        if raw_al[:4] == "    ":
                            al = raw_al[4:]
                        elif raw_al[0] == " ":
                            al = raw_al[1:]
                        else:
                            al = raw_al
                        if not al:
                            continue
                        if al[0] == " " or al[0] == "\t" or al[-1] == " " or al[-1] == "\t":
                            al = al.strip()
                            if not al:
                                continue

                        ac0 = al[0]
                        if ac0 == "]":
                            if al == "]":
                                current_table[k] = arr
                                line_idx = i + 1
                                closed = True
                                break
                            fallback_idx = i
                            break
                        if need_comma:
                            fallback_idx = i
                            break

                        has_comma = al[-1] == ","
                        elem = al[:-1] if has_comma else al
                        if ac0 == '"':
                            if elem[-1] == '"' and elem != '"':
                                inner = elem[1:-1]
                                if '"' not in inner and "\\" not in inner:
                                    arr += [inner]
                                    need_comma = not has_comma
                                    continue
                        elif ac0 == "{" and elem[-1] == "}" and allow_depth_2:
                            d = _parse_flat_inline_table(elem[1:-1], bare_keys, allow_depth_3)
                            if d != None:
                                arr += [d]
                                need_comma = not has_comma
                                continue
                            ok, val = _parse_single_line_complex(elem, state, 1)
                            if ok:
                                arr += [val]
                                need_comma = not has_comma
                                continue

                        fallback_idx = i
                        break

                    if closed:
                        continue
                    if fallback_idx == -1:
                        _fail(state, "EOF in complex")
                        return

                    # Resume parsing the remaining array elements via the general parser.
                    if fallback_idx > pos_line:
                        pos_offset += len("\n".join(lines[pos_line:fallback_idx])) + 1
                    pos_line = fallback_idx
                    state["pos"] = pos_offset
                    _parse_complex_iterative(
                        state,
                        initial_array = arr,
                        initial_mode = _MODE_ARRAY_COMMA if need_comma else _MODE_ARRAY_VAL,
                    )
                    if state["error"] != None:
                        return
                    _consume_eol(state)
                    if state["error"] != None:
                        return
                    current_table[k] = arr
                    new_pos = state["pos"]
                    if new_pos >= length:
                        break
                    line_idx = fallback_idx + data.count("\n", pos_offset, new_pos)
                    pos_line = line_idx
                    pos_offset = new_pos
                    continue
                elif v0 == "[" and v[-1] == "]" and allow_depth_1:
                    if v == "[]":
                        current_table[k] = []
                        line_idx += 1
                        continue
                    if v[1:2] == "{" and v[-2:-1] == "}" and allow_depth_2:
                        d = _parse_flat_inline_table(v[2:-2], bare_keys, allow_depth_3)
                        if d != None:
                            current_table[k] = [d]
                            line_idx += 1
                            continue

        # Fallback: sync byte offset and parse one statement with the general parser.
        if line_idx > pos_line:
            pos_offset += len("\n".join(lines[pos_line:line_idx])) + 1
        pos_line = line_idx
        state["pos"] = pos_offset
        _parse_one_statement(state)
        if state["error"] != None:
            return
        new_pos = state["pos"]
        if new_pos >= length:
            break
        line_idx += data.count("\n", pos_offset, new_pos)
        pos_line = line_idx
        pos_offset = new_pos
        current_table = state["current_table"]
        last_aot_line = ""
        last_aot_list = None

def decode(data, default = None, datetime_formatter = None, max_depth = 128, expand_values = False):
    """Decodes a TOML string into a Starlark structure.

    Args:
        data: The TOML string to decode.
        default: Optional default value to return on failure.
        datetime_formatter: Optional function to format temporal values.
        max_depth: Maximum nesting depth for tables and arrays.
        expand_values: Whether to return a "toml-test" compatible format.

    Returns:
        The decoded Starlark structure, or the default value on failure.
    """
    if "\r" in data:
        data = data.replace("\r\n", "\n")

    if data.startswith(_UTF8_BOM):
        data = data[len(_UTF8_BOM):]

    state = _parser(data, default, datetime_formatter, max_depth)
    state["is_safe"] = _is_globally_safe(data)
    length = state["len"]

    if state["is_safe"]:
        _decode_fast(state)
    else:
        for _ in range(length * _MAX_ITERATIONS_MULTIPLIER):
            if state["pos"] >= length:
                break
            _parse_one_statement(state)
            if state["error"] != None:
                break

    if state["error"] != None:
        return default

    return _expand_to_toml_test(state["root"], length) if expand_values else state["root"]
