"""uv.lock (apache/airflow) benchmarking"""

load("//toml:toml.bzl", "decode")
load(":uv_lock_data.bzl", "UV_LOCK")

def _impl(ctx):
    for _ in range(5):
        decode(UV_LOCK)
    out = ctx.actions.declare_file(ctx.label.name + ".out")
    ctx.actions.write(out, "done")
    return [DefaultInfo(files = depset([out]))]

uv_lock_benchmark_runner = rule(
    implementation = _impl,
)
