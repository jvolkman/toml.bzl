"""TOML Encoder implementation."""

# TOML Encoder
# Starlark implementation of a TOML encoder.
# Note: Recursion is not supported in Starlark, so we use iterative stack-based approaches.

# Kept in ASCII order: lstrip() sorts its charset on every call, so pre-sorted input is cheaper.
_BARE_KEY_CHARS = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"

def _escape_string(s):
    res = json.encode(s)

    # JSON allows raw DEL (0x7F), TOML forbids it.
    if "\177" in res:
        res = res.replace("\177", "\\u007F")
    return res

def _escape_key(k):
    # Simple keys don't need quotes if they match [A-Za-z0-9_-]+
    # Otherwise quote.
    if k and not k.lstrip(_BARE_KEY_CHARS):
        return k
    return _escape_string(k)

def _pad_num(n, width):
    """Pads an integer with leading zeros."""
    s = str(n)
    return "0" * (width - len(s)) + s if len(s) < width else s

def _format_temporal(dt):
    """Formats a TOML temporal struct as a standardized string."""
    t = getattr(dt, "_toml_type", None)
    if t == "OffsetDateTime":
        s = "%s-%s-%sT%s:%s:%s" % (
            _pad_num(dt.year, 4),
            _pad_num(dt.month, 2),
            _pad_num(dt.day, 2),
            _pad_num(dt.hour, 2),
            _pad_num(dt.minute, 2),
            _pad_num(dt.second, 2),
        )
        if dt.microsecond > 0:
            s += "." + _pad_num(dt.microsecond, 6).rstrip("0")
        if dt.offset_minutes == 0:
            s += "Z"
        else:
            om = abs(dt.offset_minutes)
            s += ("+" if dt.offset_minutes >= 0 else "-") + "%s:%s" % (
                _pad_num(om // 60, 2),
                _pad_num(om % 60, 2),
            )
        return s
    if t == "LocalDateTime":
        s = "%s-%s-%sT%s:%s:%s" % (
            _pad_num(dt.year, 4),
            _pad_num(dt.month, 2),
            _pad_num(dt.day, 2),
            _pad_num(dt.hour, 2),
            _pad_num(dt.minute, 2),
            _pad_num(dt.second, 2),
        )
        if dt.microsecond > 0:
            s += "." + _pad_num(dt.microsecond, 6).rstrip("0")
        return s
    if t == "LocalDate":
        return "%s-%s-%s" % (_pad_num(dt.year, 4), _pad_num(dt.month, 2), _pad_num(dt.day, 2))
    if t == "LocalTime":
        s = "%s:%s:%s" % (_pad_num(dt.hour, 2), _pad_num(dt.minute, 2), _pad_num(dt.second, 2))
        if dt.microsecond > 0:
            s += "." + _pad_num(dt.microsecond, 6).rstrip("0")
        return s
    return None

def _encode_scalar(v):
    t = type(v)
    if t == "string":
        return _escape_string(v)
    elif t == "int":
        return str(v)
    elif t == "bool":
        return "true" if v else "false"
    elif t == "float":
        if v == float("inf"):
            return "inf"
        if v == float("-inf"):
            return "-inf"
        if v != v:  # nan
            return "nan"
        return str(v)
    elif t == "struct":
        # Check for our new rich temporal types
        res = _format_temporal(v)
        if res != None:
            return res

        # Check for TOML special types (datetime, etc.)
        if hasattr(v, "toml_type") and hasattr(v, "value"):
            return str(v.value)
    fail("Unsupported scalar type: %s" % t)

# buildifier: disable=list-append
def _encode_inline_array(arr, max_tables, current_depth = 0):
    # Iterative encoding for arrays/inline values.
    # Uses a stack to flatten the structure into tokens.

    tokens = []

    # Work stack: [item]
    # We maintain a list of items to process.
    # To output "[a, b]", we push "[", "a", ", ", "b", "]".
    # But since we pop from end, we push in reverse: "]", "b", ", ", "a", "[".

    # Work stack stores: (item, depth)
    work = [(arr, current_depth)]

    # Bounded loop for safety.
    for _ in range(max_tables):
        if not work:
            break

        item, depth = work.pop()
        t = type(item)

        if depth > max_tables:
            fail("Max nesting depth exceeded in inline structure")

        if t == "tuple" and item[0] == "OUT":
            tokens += [item[1]]
            continue

        if t == "list":
            # Array -> [ val, val ]
            work += [(("OUT", "]"), depth)]
            for i in range(len(item) - 1, -1, -1):
                work += [(item[i], depth + 1)]
                if i > 0:
                    work += [(("OUT", ", "), depth)]
            work += [(("OUT", "["), depth)]

        elif t == "dict":
            # Inline Table -> { key = val, ... }
            work += [(("OUT", "}"), depth)]
            keys = sorted(item.keys())
            for i in range(len(keys) - 1, -1, -1):
                k = keys[i]
                work += [(item[k], depth + 1)]
                work += [(("OUT", " = "), depth)]

                # We assume keys in inline tables should also be escaped if needed
                work += [(("OUT", _escape_key(k)), depth)]
                if i > 0:
                    work += [(("OUT", ", "), depth)]
            work += [(("OUT", "{"), depth)]

        elif t == "string" or t == "int" or t == "bool" or t == "float" or t == "struct":
            tokens += [_encode_scalar(item)]
        else:
            fail("Unable to encode type in inline structure: %s" % t)

    if work:
        fail("Max tables exceeded in inline structure")

    return "".join(tokens)

def _is_aot(v):
    if not v or type(v[0]) != "dict":
        return False
    for x in v:
        if type(x) != "dict":
            return False
    return True

# buildifier: disable=list-append
def encode(data, *, max_tables = 1000000):
    """Encodes a Starlark dictionary into a TOML string.

    Args:
        data: The dictionary to encode. Must be a top-level dictionary.
        max_tables: Maximum number of tables/iterations to process.

    Returns:
        A string containing the TOML representation of the data.
    """
    if type(data) != "dict":
        fail("Root must be a dictionary")

    output = []

    # Stack stores: (path_list, dict_node, is_aot, depth)
    stack = [([], data, False, 0)]

    # Max iterations safety
    for _ in range(max_tables):
        if not stack:
            break

        path, current, is_aot, depth = stack.pop()

        if depth > max_tables:
            fail("Max nesting depth exceeded")

        keys = sorted(current.keys())

        simple_fields = []
        tables = []
        arrays_of_tables = []

        for k in keys:
            v = current[k]
            t = type(v)

            if t == "dict":
                tables += [(k, v)]
            elif t == "list":
                if _is_aot(v):
                    arrays_of_tables += [(k, v)]
                else:
                    simple_fields += [(k, v)]
            else:
                simple_fields += [(k, v)]

        # 1. Write Header
        if path:
            header = ".".join([_escape_key(p) for p in path])
            if is_aot:
                output += ["\n[[%s]]" % header]
            else:
                output += ["\n[%s]" % header]

        # 2. Write Simple Keys
        for k, v in simple_fields:
            if type(v) == "list":
                val_str = _encode_inline_array(v, max_tables, depth + 1)
            else:
                val_str = _encode_scalar(v)
            output += ["%s = %s" % (_escape_key(k), val_str)]

        # 3. Queue Tables
        for i in range(len(tables) - 1, -1, -1):
            k, v = tables[i]
            new_path = path + [k]
            stack += [(new_path, v, False, depth + 1)]

        # 4. Handle Array of Tables
        for i in range(len(arrays_of_tables) - 1, -1, -1):
            k, v_list = arrays_of_tables[i]
            for j in range(len(v_list) - 1, -1, -1):
                item = v_list[j]
                new_path = path + [k]
                stack += [(new_path, item, True, depth + 1)]

    if stack:
        fail("Max tables exceeded")

    return "\n".join(output)
