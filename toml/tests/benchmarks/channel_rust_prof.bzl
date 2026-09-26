"""channel-rust-1.81.0.toml benchmarking"""

load("//toml:toml.bzl", "decode")
load(":channel_rust_data.bzl", "CHANNEL_RUST")

def _impl(ctx):
    for _ in range(5):
        decode(CHANNEL_RUST)
    out = ctx.actions.declare_file(ctx.label.name + ".out")
    ctx.actions.write(out, "done")
    return [DefaultInfo(files = depset([out]))]

channel_rust_benchmark_runner = rule(
    implementation = _impl,
)
