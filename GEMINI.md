# GEMINI.md - Starlark Performance & Parsing Notes

## Starlark Performance Best Practices

Based on profiling within this codebase and others, the following patterns are significantly more efficient in Starlark:

### 1. Prefer Operators Over Method Calls

Operators are built-in to the Starlark interpreter and avoid the overhead of method lookup and dispatch.

- **List Append**: Use `list += [item]` instead of `list.append(item)`.
  - _Result_: `+= [item]` is approximately **3x faster** than `.append()` (Bazel 8.5). `x.method(...)` allocates a
    new bound `BuiltinFunction` and calls it reflectively; `list += list` is special-cased in the interpreter.
  - Buildifier's `list-append` lint prefers `.append()`; suppress it with `# buildifier: disable=list-append`
    above the `def`.
- **List Copy**: Use `list_copy = original[:]` instead of `list_copy = list(original)`.
  - _Result_: `[:]` slicing is approximately **2.5x faster** than `list()`.
- **Dict Lookup**: Prefer `d[k] if k in d else None` over `d.get(k)` in hot paths (same method-call overhead).

## Core Starlark Constraints

1.  **No `while` Loops**: Bazel's Starlark dialect does not support `while` loops or recursion.

    - _Workaround_: Use `for _ in range(MAX_ITERATIONS):` with `break` for "bounded while" loops.
    - _Strategy_: Design the parser to be linear single-pass or structured in hierarchical passes.

2.  **String Immutability & Concatenation**:

    - Strings are immutable.
    - Avoid repeated `s += part` in loops (O(N^2)).
    - _Best Practice_: Collect parts in a list and use `"".join(parts)` at the end.

3.  **Function Call Overhead**:
    - Starlark function calls have measurable overhead.
    - _Optimization_: Inline simple logic where performance is critical (e.g., inside the inner character loop of a parser).

## Parsing Performance

1.  **Native String Methods**:

    - Use `s.find()`, `s.rfind()`, `s.startswith()`, `s.endswith()`, `s.isdigit()` whenever possible.
    - These run in Java/C++ native code and are significantly faster than iterating characters in Starlark.
    - **`lstrip(chars)`/`rstrip(chars)` build a new `CharMatcher.anyOf(chars)` on every call**, which sorts the
      charset. Keep charset constants in ASCII order (roughly halves the cost), and prefer `isalnum()`/`isdigit()`
      (static matchers) when they express the check exactly.

2.  **Character Iteration**:

    - Iterating a string (`for char in string:`) is slow in Starlark.
    - _Alternative_: Split documents into lines with `data.split("\n")` and parse common statements with `partition()` / slicing, falling back to the offset parser for complex or multiline constructs.
    - _Alternative_: Cache validated bare keys in a per-call dict so repeated keys are validated with an O(1) `in` check instead of repeated `isalnum()` / `lstrip()` calls.

3.  **List Comprehensions**:

    - Generally faster than explicit `for` loops with `list.append()`.
    - `[x for x in data if condition]` > `for loop + append`.

4.  **Structs vs Providers**:
    - `struct()` is lightweight.
    - Providers (`provider()`) are typed and better for rule interfaces but strictly immutable once created.

## TOML Specifics

- TOML is line-oriented at the statement level, while multiline strings, arrays, and inline tables can cross lines.
- **Line-oriented fast path**: For pre-validated ASCII documents, a single `data.split("\n")` plus `partition(" = ")` avoids per-token `find()` and function-call overhead, syncing byte offsets lazily via `len("\n".join(lines[a:b])) + 1` only when falling back to the general offset parser.
- **Lookahead**: Since we can't easily peek/backtrack efficiently, prefer a predictive parser or a robust tokenizer.
