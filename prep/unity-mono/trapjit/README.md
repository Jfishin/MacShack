# Mac check for host/ShackTrapJIT.c (stock Mono, no rebuild)

`harness.c` (DYLD_INSERT_LIBRARIES) sets up the phone's memory model around the host's real `ShackTrapJIT.c`: a
dual-mapped pool in `SHACK_JIT_POOL`, executable mmaps served from it, execute permission dropped everywhere else
(`mprotect` succeeds without it, as on the phone), SIGBUS/SIGSEGV kept first (as `shack_fault` does). TrapJIT is its own
library so the harness's rules reach its calls too. `embed.c` runs an .exe on a game's shipped `libmonobdwgc-2.0.dylib`
the way Unity embeds it.

```bash
clang -arch arm64 -O2 -Ihost -dynamiclib host/ShackTrapJIT.c host/vendor/fishhook.c -install_name /tmp/libtrap.dylib -o /tmp/libtrap.dylib
clang -arch arm64 -O2 -Ihost -dynamiclib prep/unity-mono/trapjit/harness.c /tmp/libtrap.dylib -o /tmp/tj.dylib
clang -arch arm64 -O2 prep/unity-mono/trapjit/embed.c -o /tmp/embed
mcs -out:/tmp/bench.exe prep/unity-mono/trapjit/bench.cs; mcs -out:/tmp/stress.exe prep/unity-mono/trapjit/stress.cs
# <mbe> = a dir with lib/libmono-native.dylib (symlink to the game's Frameworks copy) and etc -> <Game>/Contents/MonoBleedingEdge/etc
DYLD_INSERT_LIBRARIES=/tmp/tj.dylib /tmp/embed <Game>/Contents/Frameworks/libmonobdwgc-2.0.dylib \
  <Game>/Contents/Resources/Data/Managed <mbe> /tmp/stress.exe        # expect: stress ok 40038350616
# A MonoKickstart game (Mono linked into <Game>.bin.osx), the game itself:
cd <Game>.app/Contents/MacOS && DYLD_INSERT_LIBRARIES=/tmp/tj.dylib ./<Game>.bin.osx   # expect: [ShackTrapJIT] stock Mono ...
```
Run `embed` and the game directly, not through /bin/sh or perl (SIP strips DYLD_* from them; perl can set it again in
`$ENV` before `exec`). `bench.exe <assemblies…>` JITs every method. The stress test needs `System.Linq.Expressions`,
which some Unity builds strip (Last Moon's: TypeLoadException); Hollow Knight's Managed has it.

2026-09-27, Slots & Daggers' Mono `3ac25215`: stress ok; bench 54,541 methods 1.35 s native vs 2.8 s trapped
(~13 traps per method, ~2 us each; the generated code is identical). Found on the way: Unity passes `MAP_JIT` on every
mono_valloc (data too), so only `PROT_EXEC` maps go to the pool, or hazard pointers trap 400k times; the replay must
not use `stlr` for unaligned stores (alignment fault). Device: Slots & Daggers (~42 fps) and Death Must Die (~55 fps,
Unity 2021.3.11) played on their own runtimes.

2026-10-28, Terraria 1.4.5.8 (MonoKickstart, mainline Mono 6.13 in `Terraria.bin.osx`, arm64): title screen with the
pool as the only executable memory (22 MB used after 35 s). Before TrapJIT knew `*.bin.osx`, the strict harness stopped
it at its first compiled method (`runtime_invoke_void`); the old harness let Mono `mprotect` its own pages executable.
Hollow Knight's Mono: stress ok with the strict harness.
