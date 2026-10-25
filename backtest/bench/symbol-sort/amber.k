/ The bare interpreter needs the q vocabulary; loading is outside timing.
\l __AMBER_LIBRARY__
`diag 0
n:__ROWS__
numeric:__NUMERIC__
ids:!n
/ Intern numeric spellings first, then put them in lexical order.
syms:asc `$'{"s",$x}'!100
ts:`mkp idiv[ids;100]
secondary:$[numeric;100!ids;n#syms]
b:([]ts:ts;sym:secondary)
t0:`t[]
sorted:xasc[`ts`sym;b]
elapsedMs:0.001*`t[]-t0
valid:(n=#sorted)&(ts~sorted`ts)&secondary~sorted`sym
/ Reverse the first six rows and require xasc to restore their order.
control:xasc[`ts`sym;reverse 6#b]
valid:valid&((6#ts)~control`ts)&(6#secondary)~control`sym
`0:"BENCH|",($elapsedMs),"|",($valid),"|",$#sorted
`0:"META|timestamp_type=",$@ts
`exit $[valid;0;2]
