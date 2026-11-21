"""TOML Encoder implementation."""

load(":datetime.bzl", "format_temporal")

# Kept in ASCII order: lstrip() sorts its charset on every call, so pre-sorted input is cheaper.
_BARE_KEY_CHARS = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
_POS_INF = float("inf")
_NEG_INF = float("-inf")

def _escape_string(s):
    res = json.encode(s)

    # JSON allows raw DEL (0x7F), TOML forbids it.
    if "\177" in res:
        res = res.replace("\177", "\\u007F")
    return res

def _escape_key(k, cache):
    if k in cache:
        return cache[k]
    if k and (k.isalnum() or not k.lstrip(_BARE_KEY_CHARS)):
        res = k
    else:
        res = _escape_string(k)
    cache[k] = res
    return res

def _encode_scalar(v):
    t = type(v)
    if t == "string":
        return _escape_string(v)
    if t == "int":
        return str(v)
    if t == "bool":
        return "true" if v else "false"
    if t == "float":
        if v == _POS_INF:
            return "inf"
        if v == _NEG_INF:
            return "-inf"
        if v != v:  # nan
            return "nan"
        return str(v)
    if t == "struct":
        res = format_temporal(v)
        if res != None:
            return res
    fail("Unsupported scalar type: %s" % t)

# buildifier: disable=list-append
def _encode_inline_array(arr, max_tables, current_depth, key_cache):
    # Iterative encoding for inline arrays and inline tables.
    # Work stack entries are (value, depth); depth == -1 emits value verbatim.
    tokens = []
    work = [(arr, current_depth)]

    for _ in range(max_tables):
        if not work:
            break

        item, depth = work.pop()
        if depth < 0:
            tokens += [item]
            continue

        if depth > max_tables:
            fail("Max nesting depth exceeded in inline structure")

        t = type(item)
        if t == "list":
            work += [("]", -1)]
            for i in range(len(item) - 1, -1, -1):
                work += [(item[i], depth + 1)]
                if i > 0:
                    work += [(", ", -1)]
            work += [("[", -1)]
        elif t == "dict":
            work += [("}", -1)]
            keys = sorted(item.keys())
            for i in range(len(keys) - 1, -1, -1):
                k = keys[i]
                work += [(item[k], depth + 1), (_escape_key(k, key_cache) + " = ", -1)]
                if i > 0:
                    work += [(", ", -1)]
            work += [("{", -1)]
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
    for x in v[1:]:
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
    key_cache = {}

    # Stack entries: (header, dict_node, is_aot, depth)
    stack = [("", data, False, 0)]

    for _ in range(max_tables):
        if not stack:
            break

        header, current, is_aot, depth = stack.pop()

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
            elif t == "list" and _is_aot(v):
                arrays_of_tables += [(k, v)]
            else:
                simple_fields += [(k, v, t == "list")]

        if header:
            output += ["\n[[%s]]" % header if is_aot else "\n[%s]" % header]

        for k, v, is_list in simple_fields:
            if is_list:
                val_str = _encode_inline_array(v, max_tables, depth + 1, key_cache)
            else:
                val_str = _encode_scalar(v)
            output += ["%s = %s" % (_escape_key(k, key_cache), val_str)]

        prefix = header + "." if header else ""
        for k, v in reversed(tables):
            stack += [(prefix + _escape_key(k, key_cache), v, False, depth + 1)]

        for k, v_list in reversed(arrays_of_tables):
            aot_header = prefix + _escape_key(k, key_cache)
            for item in reversed(v_list):
                stack += [(aot_header, item, True, depth + 1)]

    if stack:
        fail("Max tables exceeded")

    return "\n".join(output)
