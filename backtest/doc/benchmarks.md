# Reproducing benchmarks

Run benchmarks locally; measurements depend on the engine revision, machine,
thread settings, input size and other work on the host. Generated timing
results and profiles are not committed or used as correctness assertions.

From `backtest/`, generate synthetic daily/hourly snapshots and run the kernel,
hold and strategy workloads:

```sh
bench/run.sh out/bench 90 "12 100" "1d 1h"
```

`tools/synth_bars.py` creates deterministic synthetic inputs; `bench/run.sh`
records the engine metadata, elapsed time and peak RSS. Its header describes
optional Hyperfine and perf measurements and the available environment
variables. The CLI snapshot downloads are separate: `make data` verifies real
public market data against committed SHA256 manifests.

For already-sorted symbol keys and integer controls, run the standalone
[symbol-sort harness](../bench/symbol-sort/README.md). For append/amend paths,
use the [local-mutation workloads](../bench/local-mutation/README.md).

Keep results under `out/` or outside the checkout. Preserve input size, engine
revision, build flags and hardware context when reporting a measurement.
Check accounting and output equality before drawing performance conclusions:
`make test` runs the fixtures and scalar/vector equivalence checks; the
repository-root `make kernel-test` is the offline subset plus the independent
Python accounting oracle.
