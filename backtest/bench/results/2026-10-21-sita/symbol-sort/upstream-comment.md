Cross-runtime measurement for this exact already-sorted `(timestamp, symbol)` workload, with a lexical-integer-rank control.

Same machine as the report (Ryzen AI 7 350, 16 logical CPUs), 2,630,400 rows, 100 symbols per timestamp. Versions: Rayforce `2.10.0.r206.g64645998`, PeachQ package `0.88-1`, KX q `5` build `2026.07.23`.

Each value is the median of three **fresh processes**, after a separate discarded warm-up process. Each process times exactly one `xasc`; construction, startup, validation and printing are excluded. q/PeachQ column attributes are explicitly cleared. This avoids subsequent sorts benefiting from cached ordering attributes.

| Runtime | Secondary workers requested | Symbols, ms | Integer ranks, ms |
|---|---:|---:|---:|
| rayforce | 0 | 53.707 | 21.090 |
| rayforce | 1 | 83.625 | 17.886 |
| rayforce | 4 | 287.313 | 13.885 |
| rayforce | 16 | 1175.980 | 13.314 |
| peachq | 0 | 33.140 | 33.282 |
| peachq | 1 | 28.892 | 27.752 |
| peachq | 4 | 27.718 | 27.321 |
| peachq | 16 | 43.227 | 46.462 |
| q | 0 | 35.132 | 31.915 |
| q | 1 | 33.753 | 33.171 |
| q | 4 | 28.175 | 26.796 |
| q | 16 | unavailable | unavailable |

The settings are **secondary workers requested**, not total cores: Rayforce uses `RAYFORCE_CORES=N`; PeachQ and q use `-s N`. Zero is the serial baseline. The local q license rejects values above four; its 16-worker cases are unavailable, not substituted.

At the common setting 4, Rayforce's symbol case is about **10× slower** than PeachQ/q, while its integer control is about **2× faster**. From setting 0 to 16, the Rayforce symbol case slows about **22×** while the integer control improves. Neither competitor shows a comparable symbol-specific collapse in this matrix. This is an operation-level comparison; it does not by itself establish their internal sorting algorithms or compare general database performance.

All 66 measured sorts and 22 warm-ups passed full key-value/row-count checks plus a small reversed-input control. Desktop load was not isolated; small differences between PeachQ and q should not be treated as a ranking.

The same q source was used for PeachQ and KX q (set `numeric:1` for the integer control):

```q
/ The runner substitutes 2630400 and 0; identical q/PeachQ source.
n:2630400;
numeric:0;
ids:til n;
syms:asc `$({"s",string x}each til 100);
/ Clear attributes explicitly; benchmark the first sort of fresh vectors.
ts:`#`timestamp$(ids div 100);
secondary:`#$[numeric;ids mod 100;n#syms];
b:([]ts:ts;sym:secondary);
t0:.z.p;
sorted:`ts`sym xasc b;
elapsedMs:("f"$("j"$(.z.p-t0)))%1000000;
valid:(n=count sorted)&(all ts=sorted`ts)&all secondary=sorted`sym;
/ Small reversed control, outside the timed region.
control:`ts`sym xasc reverse 6#b;
valid:valid&(all (6#ts)=control`ts)&all (6#secondary)=control`sym;
-1 "BENCH|",(string elapsedMs),"|",(string "j"$valid),"|",string count sorted;
-1 "META|version=",(string .z.K),"|build=",(string .z.k),"|secondary=",string system "s";
exit $[valid;0;2];

```

Run it as `q sorted-check.q -q -s 0` / `peachq sorted-check.q -q -s 0`, changing `-s` for the thread matrix. Rayforce uses the standalone reproducer already included in the issue, with the same symbols, timestamps and lexical-rank control.
