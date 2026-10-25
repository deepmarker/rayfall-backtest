/ The runner substitutes __ROWS__ and __NUMERIC__; identical q/PeachQ source.
n:__ROWS__;
numeric:__NUMERIC__;
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
