# OpenGL on Metal: metalgldrv

`vendor/metalgldrv` is [bomberfish/metalgldrv](https://github.com/bomberfish/metalgldrv) (MIT), desktop OpenGL 4.6 on
Metal 4. A Mac game whose `.args` has `--shack-env=SHACK_GL=metalgldrv` runs its GL there instead of ShackGL's ES 3
layer, through MacShack's CGL-over-EGL adapter (`shims/AppKit/ShackGLDrv.m`). Batman: Arkham Asylum gets it by default
(`host/AutoConfig.swift`).

`macshack.patch` holds what MacShack needs that upstream does not have:

- EGL contexts honor `EGL_CONTEXT_RELEASE_BEHAVIOR_NONE_KHR`: a context keeps its open render pass when released.
  Feral's ports set and clear their context around nearly every GL call; a flush on each release made every draw its
  own render pass (Batman: about 10 fps).
- `METALGLDRV_RELEASE_NONE=1` does the same for the driver's own CGL (the macOS hook, for testing on a Mac), and the
  swap interval is applied only when it changes.
- `METALGLDRV_OCCLUSION_EARLY_SUBMIT=1`: the first draw after a run of occlusion queries sends the work to the GPU, so a
  game that reads last frame's results early in the next frame (Unreal Engine 3 ports) finds them done instead of
  waiting for that frame's GPU work.

Each has a test in metalgldrv's suite (`cgl_release_none`, `occlusion_early_submit`) and an entry in its
`docs/ARCHITECTURE.md`.

## Build

Xcode runs `build.sh` for MacShack and MacShack Play (`project.yml`): it applies the patch to the submodule if it is
not applied, builds `libmetalgldrv.dylib` for the device or the simulator with CMake and Ninja (`brew install cmake
ninja`; about 15 s from clean), and the app's embed step copies and signs it into `Frameworks`. Without the submodule
or the tools the apps build without it and games stay on ShackGL.

metalgldrv's own tests run on a Mac:

```sh
cd vendor/metalgldrv
cmake -G Ninja -B build/mac-tests -DCMAKE_BUILD_TYPE=RelWithDebInfo && ninja -C build/mac-tests
./build/mac-tests/tests/mgltest   # also with METALGLDRV_RELEASE_NONE=1 METALGLDRV_OCCLUSION_EARLY_SUBMIT=1
```

After changing `vendor/metalgldrv`, regenerate the patch: `git -C vendor/metalgldrv diff > prep/metalgldrv/macshack.patch`.
