# Embench-IoT speed on AlphaOneSoC

Measured 2026-11-10 on the SoC bench (`tb/tb_sw.v`, Verilator), main `32cac47` (PR #16) at 62.5 MHz:
`make -C sw embench && sw/tools/run_embench.sh 3`, GCC 14.2 `-O2`, code and data in PSRAM, scale
factor 1. The clocks are exact (`mtime` counts the core clock); a benchmark's score is
`reference_ms / ms * gsf / MHz` against `baseline-data/speed.json` of the pinned Embench commit
(sw/fetch.sh), where the Cortex-M4 reference is 1.0, and the mean is geometric. The same numbers
came out on `a2f7285` at 60 MHz (the programs run from PSRAM, which streaming does not change).

```
benchmark              clocks ms@62.5MHz  score/MHz
aha-mont64          196610378     3145.8     0.0204
crc32               160757649     2572.1     0.0249
depthconv           163904696     2622.5     0.0234
edn                 156475309     2503.6     0.0256
huffbench           102739142     1643.8     0.0389
matmult-int         126845274     2029.5     0.0316
md5sum              104397749     1670.4     0.0377
nettle-aes          187345035     2997.5     0.0211
nettle-sha256       199549367     3192.8     0.0200
nsichneu            148273292     2372.4     0.0290
picojpeg            148335448     2373.4     0.0264
qrduino             133270265     2132.3     0.0295
sglib-combined      122756934     1964.1     0.0337
slre                117274060     1876.4     0.0341
statemate           175406122     2806.5     0.0366
tarfind              51544698      824.7     0.0777
ud                  117603050     1881.6     0.0335
wikisort             62121490      993.9     0.0583
xgboost             178986577     2863.8     0.0197
geometric mean over 19 of 19 benchmarks: 0.0306 Embench speed per MHz (1.0 = the Cortex-M4 reference)
```

All 19 benchmarks gave the correct result. `tarfind` is the best (0.078) and `xgboost` the worst
(0.020).
