# toml.bzl

A pure Starlark TOML 1.1.0 encoder and decoder.

## Usage

For full API documentation, see [the API Reference](docs/toml.md).

For installation instructions, see [Releases](https://github.com/jvolkman/toml.bzl/releases).

### In a `.bzl` file

```starlark
load("@toml.bzl", "toml")

content = """
[database]
server = "192.168.1.1"
ports = [ 8000, 8001, 8002 ]
"""

# Decode
config = toml.decode(content)
print(config["database"]["server"])

# Encode
encoded = toml.encode(config)
print(encoded)
```

## Performance

`toml.bzl` is highly optimized for the Starlark interpreter, leveraging native string operations to achieve high throughput while maintaining 100% compliance with TOML 1.1.0.

### Benchmarks

Time per `decode()` call on an **Apple M3 Pro MacBook Pro** (Bazel 8.5.0, warm server):

| Document                     | Size   | Time per parse | Throughput |
| :--------------------------- | :----- | :------------- | :--------- |
| **Cargo.lock**               | 735 KB | **61 ms**      | ~12 MB/s   |
| **channel-rust-1.81.0.toml** | 824 KB | **61 ms**      | ~13 MB/s   |

To reproduce, build `//toml/tests/benchmarks:benchmark_prof` or
`//toml/tests/benchmarks:channel_rust_benchmark_prof` (each parses its document 5 times during
analysis) with `--nobuild --starlark_cpu_profile=<file>`, and inspect `decode` in the profile.

### Compliance

The implementation is verified against the [toml-test](https://github.com/toml-lang/toml-test) suite, passing all compliance tests (decoding and encoding).
