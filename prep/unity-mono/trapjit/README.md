# Mac check for host/ShackTrapJIT.c (stock Unity Mono, no rebuild)

`harness.c` (DYLD_INSERT_LIBRARIES) sets up the phone's memory model around the host's real `ShackTrapJIT.c`: a
dual-mapped pool in `SHACK_JIT_POOL`, executable mmaps served from it, SIGBUS/SIGSEGV kept first (as `shack_fault`
does). `embed.c` runs an .exe on a game's shipped `libmonobdwgc-2.0.dylib` the way Unity embeds it.

```bash
clang -arch arm64 -O2 -Ihost -dynamiclib prep/unity-mono/trapjit/harness.c host/ShackTrapJIT.c host/vendor/fishhook.c -o /tmp/tj.dylib
clang -arch arm64 -O2 prep/unity-mono/trapjit/embed.c -o /tmp/embed
mcs -out:/tmp/bench.exe prep/unity-mono/trapjit/bench.cs; mcs -out:/tmp/stress.exe prep/unity-mono/trapjit/stress.cs
# <mbe> = a dir with lib/libmono-native.dylib (symlink to the game's Frameworks copy) and etc -> <Game>/Contents/MonoBleedingEdge/etc
DYLD_INSERT_LIBRARIES=/tmp/tj.dylib /tmp/embed <Game>/Contents/Frameworks/libmonobdwgc-2.0.dylib \
  <Game>/Contents/Resources/Data/Managed <mbe> /tmp/stress.exe        # expect: stress ok 40038350616
```
Run `embed` directly, not through /bin/sh (SIP strips DYLD_*). `bench.exe <assemblies…>` JITs every method.

2026-09-27, Slots & Daggers' Mono `3ac25215`: stress ok; bench 54,541 methods 1.35 s native vs 2.8 s trapped
(~13 traps per method, ~2 us each; the generated code is identical). Found on the way: Unity passes `MAP_JIT` on every
mono_valloc (data too), so only `PROT_EXEC` maps go to the pool, or hazard pointers trap 400k times; the replay must
not use `stlr` for unaligned stores (alignment fault). Device: Slots & Daggers (~42 fps) and Death Must Die (~55 fps,
Unity 2021.3.11) played on their own runtimes.
