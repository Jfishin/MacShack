# Unity Mono with a dual-mapped code manager

iOS (TXM devices, iOS 26+/27) never lets a page be written and executed at the same address; the only executable
memory is a region the attached debugger (MacShack's JIT helper or StikDebug) prepared, and the proven way to change it afterwards is a
`vm_remap` RW alias. Unity's Mono JIT writes and executes at one address, so its runtime is rebuilt with
`dualmap.patch`, which keeps every code pointer, return address and PC-relative displacement on the RX address
and routes every store into code through `mono_codeman_rw ()` (RX + fixed delta).

Where the code is written (all sites Mono's Apple Silicon support already bracketed with
`mono_codeman_enable_write`): `arm_emit`/`arm_set_ins_bits` (every emitted or patched instruction:
trampolines, thunks, call-site patching, breakpoints), `mono_codegen`'s memcpy of the method body and thunk
area, switch jump tables (mini.c, mini-runtime.c), the thunk target word (`emit_thunk`), the jump trampoline's
patch word and specific-trampoline argument (tramp-arm64.c). `mono_arch_flush_icache` cleans the RW alias
before invalidating RX. Dynamic code managers use pool chunks instead of dlmalloc (which writes its headers into
code memory).

Allocation: `mono-codeman.c` reads `SHACK_JIT_POOL=<rx>,<rw>,<size>` (hex), set by `ShackJITPoolSetup` in the
host after the debugger prepared the region, and bump-allocates chunks from it (frees stay on the size-keyed
freelist). `SHACK_JIT_POOL_MB=<n>` builds the same dual mapping locally on a Mac for testing without a debugger.
With neither variable the runtime behaves exactly as shipped.

## Identify the game's revision

`strings libmonobdwgc-2.0.dylib | grep -A1 '^6\.'` prints the version and `explicit/<commit>`; Silksong
(Unity 6000.0.50) ships 6.13.0 `explicit/43035fcf` = Unity-Technologies/mono `43035fcf9007b1393dab96463e4a3ef89b3a07b7`.
Big Hops Together (Steam build 25046464, Unity 6000.3.21f1) ships 6.13.0 `explicit/dc7ab1aa` =
`dc7ab1aa0dd66ca15d4ffc9776e058993d53dee5`. Match the revision, not the shared Mono 6.13.0 version.

## Build and embed

```
prep/unity-mono/build.sh 43035fcf9007b1393dab96463e4a3ef89b3a07b7
cp prep/unity-mono/build/libmonobdwgc-2.0.dylib <prepped Game.app>/Contents/Frameworks/libmonobdwgc-2.0.dylib
# then shackprep embed (or, for an already embedded guest, run thin_arm64/set_ios_platform/rewrite_links on the
# copy in host/Guests/<Name>/Contents/Frameworks/) and rebuild the host.
```

Embedding into `host/Guests` is the legacy path; on-device Prepare is the normal one, and it takes the runtime from the
catalog below.

## Verify on the Mac (system Mono 6.12 class libs work with this runtime)

```
MB=/Library/Frameworks/Mono.framework/Versions/6.12.0
export MONO_PATH=$MB/lib/mono/4.5 MONO_CFG_DIR=$MB/etc
SHACK_JIT_POOL_MB=64 <mono-src>/mono/mini/mono-boehm hello.exe
```
The pool's RX side is mapped without write permission, so any missed write site faults instead of silently
working. To simulate the phone's mmap (no executable memory at all), build a `__interpose` dylib that strips
`MAP_JIT`/`PROT_EXEC` and load it with `DYLD_INSERT_LIBRARIES`: the unpatched path then dies at its first
generated instruction, the pool path completes (interfaces, generics, dynamic methods, expression trees, 8 JIT threads,
exceptions, async).

## Host runtime catalog

Use a separate source directory per revision so rebuilding one runtime cannot overwrite another's patched source.
Stage the unretargeted macOS runtime under `build/mono-catalog/<8-character-revision>/`:

```bash
prep/unity-mono/build.sh dc7ab1aa0dd66ca15d4ffc9776e058993d53dee5 "$PWD/build/unity-mono-dc7ab1aa"
mkdir -p build/mono-catalog/dc7ab1aa
cp prep/unity-mono/build/libmonobdwgc-2.0.dylib build/mono-catalog/dc7ab1aa/
```

`build.sh` writes one shared output path, so stage each successful output before building another revision.
The prebuilt-deps download carries the catalog (currently 0c500f44, 43035fcf, 7de96da4, dc7ab1aa).

The host build invokes `prepare_catalog.py SOURCE DESTINATION SIGNING_IDENTITY`, using
`build/mono-catalog` as its source and `MacShack.app/Frameworks/MonoRuntimes` as its destination.
It checks the revision and dual-map markers, stages a copy, applies ShackPrep's arm64/platform/dependency edits,
signs and verifies it. The raw catalog stays macOS-targeted. On-device preparation selects the matching revision
and signs the installed guest copy with the host's identifier. Missing revisions must be reported before launch.

### Runtime-only build details

`dualmap.patch` applied to `dc7ab1aa` unchanged, its SDK 26 compile fixes (`_Bool`, `objc_super.super_class`)
included. `autogen.sh` fetches every managed-library submodule; only `external/bdwgc` and
its `libatomic_ops` submodule are needed for the JIT runtime. After configuring with the flags in `build.sh`, the
runtime and `mono-boehm` link. The later `mono/native` target fails without `external/corefx`, and the runtime does not
need it.

For an already configured checkout, build just the runtime prerequisites and runtime with the same compiler flags:

```bash
mono_src="$PWD/build/unity-mono-dc7ab1aa"
mono_cc="clang -arch arm64 -std=gnu11 -Wno-error=incompatible-function-pointer-types -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-function-declaration -Wno-error=implicit-int"
make -j"$(sysctl -n hw.ncpu)" -C "$mono_src/external/bdwgc"
for part in eglib utils metadata mini; do
  make -j"$(sysctl -n hw.ncpu)" -C "$mono_src/mono/$part" CC="$mono_cc" CCAS="$mono_cc"
done
mkdir -p build/mono-catalog/dc7ab1aa
cp "$mono_src/mono/mini/.libs/libmonoboehm-2.0.1.dylib" build/mono-catalog/dc7ab1aa/libmonobdwgc-2.0.dylib
strip -x build/mono-catalog/dc7ab1aa/libmonobdwgc-2.0.dylib
install_name_tool -id '@executable_path/../Frameworks/MonoEmbedRuntime/osx/libmonobdwgc-2.0.dylib' build/mono-catalog/dc7ab1aa/libmonobdwgc-2.0.dylib
```

Validation (`dc7ab1aa`): the rebuilt runtime exports exactly the shipped runtime's 2139 symbols. The existing stress
fixture passed with a 64 MB dual mapping and again with the interposer that strips executable mmap/mprotect
requests: `stress ok 40038350616`, six stripped requests. It covers dynamic methods, expression trees, interfaces,
generics, switch tables, exceptions, async, and eight JIT threads. The fixture used system Mono 6.12 class libraries
and the previously built arm64 `libmono-native.dylib` through the new prefix's `libmono-native-compat.dylib` symlink;
that helper is only for the Mac test and is not the replacement guest runtime.
