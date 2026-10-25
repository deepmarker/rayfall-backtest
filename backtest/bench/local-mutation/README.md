# Local mutation (#950)

The workload appends 500 rows to an ordinary three-column table and amends
10 elements of a 500-element vector per step. Each run starts from empty
state. The logical rows and vector contents match across implementations;
physical storage and each language's append idiom can differ.

Build and run the native global/local comparison:

```sh
make -C ~/code/rayforce release -j4
~/code/rayforce/rayforce -c 1 -f backtest/bench/local-mutation/local_mutation.rfl
```

For a fresh-process local-state comparison with installed q, PeachQ and Amber:

```sh
python3 backtest/bench/local-mutation/compare.py --rayforce ~/code/rayforce/rayforce \
  --output /tmp/local-mutation-results.json
```

The runner detects `q`, `peachq`, and the bare `amberx` launcher on PATH;
explicit paths can be supplied with the corresponding options. Amber needs
its q libraries in `AMBER_HOME` or `--amber-home` (default `/usr/share/amber`).
The interactive `amber` wrapper is not used. Each engine warms up at 10
steps, then runs five alternating samples at each size in each of three
fresh processes. Engine order rotates between processes. All 120 samples
check the returned row count and final vector sum. Timings exclude startup,
library loading and printing. Rayforce uses `timeit`; the q-family script
uses `.z.p`. Other work on the host can affect these observations.

`functional.rfl` reproduces the old local workaround, rebinding the result
of functional insert and incrementing the vector functionally. Run it with an
unmodified release binary:

```sh
rayforce -c 1 -f backtest/bench/local-mutation/functional.rfl
```

Generate measurements on your own machine with the commands above. Results
and executable metadata are local output, not versioned test fixtures. The
workloads check row counts and vector sums; they do not assert elapsed time.
