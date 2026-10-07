# StikJIT (vendored binary)

`StikJIT.xcframework` is the release asset of https://github.com/StikDebug/StikJIT **1.8.0**
(2026-09-25): `StikJIT.xcframework.zip`, SHA-256 `c8cab0974a2b5ef794978dadef0bed6f3560d4b90ab2eda396822373cec4ccad`.
MPL-2.0 (`LICENSE`); its bundled idevice is MIT. **Local change:** `StikJIT.framework/Info.plist` added (the release
has none, and iOS refuses to install a framework without one).

Used only by the `MacShackJIT` app extension (`jithelper/`), which attaches the debugger to MacShack and runs
`host/probe/macshack-jit.js`. The framework is embedded once, in `MacShack.app/Frameworks`; the extension finds it
through `@executable_path/../../Frameworks`. The host app does not link it.

Update: download the release zip, check its SHA-256, replace the folder, update this file.
