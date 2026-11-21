"""Datetime constructors and formatting for TOML temporal types."""

def OffsetDateTime(year, month, day, hour, minute, second, microsecond = 0, offset_minutes = 0):
    return struct(
        _toml_type = "OffsetDateTime",
        year = year,
        month = month,
        day = day,
        hour = hour,
        minute = minute,
        second = second,
        microsecond = microsecond,
        offset_minutes = offset_minutes,
    )

def LocalDateTime(year, month, day, hour, minute, second, microsecond = 0):
    return struct(
        _toml_type = "LocalDateTime",
        year = year,
        month = month,
        day = day,
        hour = hour,
        minute = minute,
        second = second,
        microsecond = microsecond,
    )

def LocalDate(year, month, day):
    return struct(
        _toml_type = "LocalDate",
        year = year,
        month = month,
        day = day,
    )

def LocalTime(hour, minute, second, microsecond = 0):
    return struct(
        _toml_type = "LocalTime",
        hour = hour,
        minute = minute,
        second = second,
        microsecond = microsecond,
    )

def _pad_num(n, width):
    s = str(n)
    return "0" * (width - len(s)) + s if len(s) < width else s

def _format_time(hour, minute, second, microsecond):
    s = "%s:%s:%s" % (_pad_num(hour, 2), _pad_num(minute, 2), _pad_num(second, 2))
    if microsecond > 0:
        s += "." + _pad_num(microsecond, 6).rstrip("0")
    return s

def format_temporal(dt):
    """Formats a TOML temporal struct as an ISO 8601 string, or returns None.

    Args:
        dt: A candidate temporal struct.

    Returns:
        ISO 8601 string if `dt` is a TOML temporal struct, or None otherwise.
    """
    t = getattr(dt, "_toml_type", None)
    if t == "OffsetDateTime":
        s = "%s-%s-%sT%s" % (
            _pad_num(dt.year, 4),
            _pad_num(dt.month, 2),
            _pad_num(dt.day, 2),
            _format_time(dt.hour, dt.minute, dt.second, dt.microsecond),
        )
        if dt.offset_minutes == 0:
            return s + "Z"
        om = abs(dt.offset_minutes)
        sign = "+" if dt.offset_minutes >= 0 else "-"
        return "%s%s%s:%s" % (s, sign, _pad_num(om // 60, 2), _pad_num(om % 60, 2))
    if t == "LocalDateTime":
        return "%s-%s-%sT%s" % (
            _pad_num(dt.year, 4),
            _pad_num(dt.month, 2),
            _pad_num(dt.day, 2),
            _format_time(dt.hour, dt.minute, dt.second, dt.microsecond),
        )
    if t == "LocalDate":
        return "%s-%s-%s" % (_pad_num(dt.year, 4), _pad_num(dt.month, 2), _pad_num(dt.day, 2))
    if t == "LocalTime":
        return _format_time(dt.hour, dt.minute, dt.second, dt.microsecond)
    return None

def datetime_to_string(dt):
    """Converts a datetime/date/time struct to an ISO 8601 string.

    Args:
        dt: The struct to convert.

    Returns:
        String representation of the datetime.
    """
    res = format_temporal(dt)
    if res != None:
        return res
    fail("Expected a TOML temporal struct, got %s" % type(dt))
