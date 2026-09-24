# Web engine acceptance fixtures

Run `bash ui/scripts/verify-web.sh` on macOS. The runner writes its evidence path and
command exit code; **a nonzero result is not acceptance**. No SKIP becomes PASS.

The Swift harness is appended to the unchanged production controller source in an
isolated temporary build, excluding only the application bootstrap. It uses real
WKWebView/AppKit/AVFoundation, an isolated HOME + CFFIXED_USER_HOME, a loopback
network canary with a positive control, OS-posted input, and window captures.
It does not install an application, change user active.json, or add a test bridge
to production. Captures are `web-a.png`, `web-b.png`, and `video.png`; assertions
and pause timer counts are in `runtime.log`, compiler output in `build.log`,
network requests in `network-requests.log`, the installed SDK's public suspension
API declarations in `webkit-api.log`, and the exit code in `result.log`.
The cursor and foreground application are restored on normal test completion.
OS-posted input is explicitly **not physical mouse evidence**.

`reactive-shader` is a local HTML/CSS/JS/WebGL example. Its default light demo uses a simple gradient with a small particle field; `?heavy=1` selects the reactive shader stress mode. Both modes cap rendering at 30 fps and render at half the display dimensions. The runner removes its CSP
in the temporary copy, ensuring the engine—not a cooperative fixture—enforces
security. A JS-colored HTML B package and an ffmpeg video package are generated
only in the isolated library. ffmpeg, screen recording and input-posting access
are necessary for their respective checks; missing evidence is not success.

## Current engine boundaries

- A private package snapshot is validated before replacing a working wallpaper.
  HTML receives an engine CSP before any package bytes; a per-package
  WKContentRuleList blocks every resource except that exact snapshot and data URLs.
  This extra file boundary is necessary: a real test found that `loadFileURL`
  read-access grants alone permitted a script outside the snapshot in `/tmp`. Persistent website storage is disabled.
- Snapshots reject symlinks (including internal links), special files, non-UTF-8
  HTML, more than 4096 entries or 256 MiB of assets. This is deliberately stricter
  than merely rejecting escaping symlinks. Package-local relative assets work;
  remote resources, frames, workers, forms, native bridges and choosers do not.
- `loadFileURL` read access is limited to the private validated package snapshot,
  not the original writable installation. Original files are not rewritten.
- Interaction temporarily raises windows to normal level, accepts input, and
  exits through the status menu or host Escape handling. Exit restores desktop
  level, click-through and the previous foreground app; it does not hide all
  wallpaper windows. Global Escape observation can require Accessibility access.
- A failed validation preserves the prior wallpaper. A WebKit process/load
  failure emits failure and releases input/windows to show the system desktop;
  it does not pretend the failed page is ready or automatically retry forever.
- **Public WKWebView APIs suspend media, not arbitrary JavaScript.** The engine
  suspends WebKit media and calls `window.wallbloom.pause()` / `resume()` when
  those functions exist. The fixture implements the cooperative hooks and a
  managed timer; the runner checks hook invocation and that its timer stops and
  resumes. A page without hooks may continue arbitrary JS timers; this is an
  explicit limitation, not a pause failure. Low-power mode has the same boundary:
  media and cooperative page work are paused, but full JS/CPU suspension is not
  guaranteed. No private API or process-wide SIGSTOP is used.
- All-display window counts are checked, but pixels/input on every monitor,
  Spaces switching, physical mouse input, actual low-power transition, product-UI
  3-second selection and CPU/RAM budgets still need separate acceptance evidence.
- Unreal/Unity standalone scenes and Windows runtimes are not implemented or
  validated here. The local shader is only a lightweight WebGL example.

Exit 1 means a runtime assertion failed. Exit 2 means assertions did not fail but
full acceptance evidence remains missing; it is not a full-acceptance PASS.
Exit 0 is intentionally unavailable until the remaining contracts are tested.
