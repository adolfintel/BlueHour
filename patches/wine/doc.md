# Wine nv-legacy patch series

`patches/wine/` holds two patches, applied by `build.sh` in name order:

| file | content | must compile alone |
|------|---------|--------------------|
| `0001-nv-legacy-features.patch` | the WGL/GLX surface and the presentation/input behaviour the demos need | **yes** |
| `0002-nv-legacy-diagnostics.patch` | traces and frame dumps | no, optional |

They are regenerated from the annotated development tree
(`tools/make_nv_patches.py --dev.../wine --tag wine-11.18...`); never edit the patch
files by hand. The series history and the marker rules are in `docs/wine-patch-series.md`
and `docs/patch-split.md`. The fullscreen-hack design history is in
`docs/fshack-mainline.md`.

No new files are added.  The two series currently touch:

```text
dlls/ntdll/exception.c
dlls/ntdll/unix/sync.c
dlls/opengl32/make_opengl
dlls/opengl32/thunks.c
dlls/opengl32/unix_thunks.c
dlls/opengl32/unix_wgl.c
dlls/opengl32/unixlib.h
dlls/opengl32/wgl.c
dlls/opengl32/winegl.xml
dlls/win32u/opengl.c
dlls/win32u/sysparams.c
dlls/win32u/window.c
dlls/winex11.drv/display.c
dlls/winex11.drv/event.c
dlls/winex11.drv/init.c
dlls/winex11.drv/mouse.c
dlls/winex11.drv/opengl.c
dlls/winex11.drv/window.c
dlls/winex11.drv/x11drv.h
dlls/winex11.drv/x11drv_main.c
dlls/winex11.drv/xinerama.c
dlls/wow64cpu/cpu.c
include/wine/opengl_driver.h
include/wine/wgl.h
```

`dlls/wow64cpu/cpu.c` is diagnostics-only.  The rest is shared by the feature series
and/or the diagnostics series.

---

## 1. Why these patches exist

The demos of this project talk to Wine through the WGL surface of 2001-2006, and Wine
today implements neither that surface nor the semantics those demos assume:

* `WGL_NV_render_texture` / `WGL_NV_render_depth_texture`: the pbuffer's colour or depth
  buffer **becomes** a texture, with no copy. Wine only knows `WGL_ARB_render_texture`.
* `WGL_NV_float_buffer`: a pbuffer in a floating-point format, used by the HDR/luminance
  chains.
* `WGL_NV_vertex_array_range` and the `wgl`-prefixed spellings of `glX...` functions that
  client libraries such as `cgGL.dll` resolve through `dlsym`.
* A fullscreen presentation model: the demo picks a mode from its own `args.txt`
  (1024x768, 1280x960, ...), expects it to be honoured, and expects the pointer to be
  warped/clipped inside it.
* The present path must not leak GL state into the application, and must scale and centre
  the frame on a modern monitor.
* Timing: some demos busy-wait on the QueryPerformanceCounter, whose modern behaviour
  differs from the 2005 hardware they were tuned against.

---

## 2. `0001-nv-legacy-features.patch`

### 2.1 What is advertised to the application

| extension | status |
|-----------|--------|
| `WGL_NV_render_texture`, `WGL_NV_render_texture_rectangle`, `WGL_ARB_render_texture` | **implemented**: `wglBindTexImageARB` / `wglReleaseTexImageARB` / `wglSetPbufferAttribARB` bound through `GLX_EXT_texture_from_pixmap`, so the pbuffer's colour buffer is the texture with no copy (`WINE_NV_RT_COLOR_TFP`, on) |
| `WGL_NV_render_depth_texture` | **implemented**: the pbuffer's depth is attached as the texture store; Wine keeps a **persistent, per-context FBO** for such a drawable (`drawable->draw_fbo`) because the GLX drawable's framebuffer is otherwise created and destroyed at every activation, and an FBO name is only valid in the context that created it |
| `WGL_NV_float_buffer`, `GLX_NV_float_buffer` | **implemented**: float pixel formats are duplicated and reported; `GLX_NV_float_buffer` is not always present in the server, so support is inferred from the ARB render type |
| `WGL_NV_vertex_array_range`, `GLX_NV_vertex_array_range` | **accepted and served**: allocation is client memory, and both the `wgl` and `gl` prefixed names are resolvable, because Wine's WGL layer does not know them and the clients look them up with `dlsym()` |
| gamma / `SetDeviceGammaRamp` paths | served where the demos use them: the present path reports whether the default gamma ramp is in effect (`gamma_default=` in the blit trace line) |

Advertising is conservative: `WINE_NV_ADVERTISE_DEPTH_TEXTURE` and
`WINE_NV_ADVERTISE_NV_FLOAT` gate the NV-specific strings so a plain Wine build does not
grow capabilities it cannot honour.

### 2.2 pbuffer and render-texture plumbing

* **Drawable handoff fix**: `get_target()` must be resolved *before* `p_context_activate()`
  in the win32u paths. Without it the pbuffer's drawable is never created, which is what
  made Dusk, Truck (Time Machine) and Toys render nothing (measured: no
  `GLX_ARB_create_context`-side drawable for the pbuffer).
* **Depth archive**: for `render_depth_texture` pbuffers Wine copies the depth buffer into
  the texture at the right moment and in the right context. Several paths exist and were
  measured one against the other: in-line at bind time (`WINE_NV_DEPTH_INLINE`), late at
  swap (`WINE_NV_PBUFFER_LATE=1|2`), from the drawer context
  (`WINE_NV_LATE_DEPTH_DRAWER_CTX`), from the full store (`WINE_NV_LATE_DEPTH_CONTENT`),
  keeping the current context to avoid re-attaching (`WINE_NV_DEPTH_KEEP_CURRENT`), and
  reading from the drawable's FBO instead of framebuffer 0 (`WINE_NV_PBUFFER_READ_FBO`,
  `WINE_NV_DEPTH_READBUF`). Nalu's soft shadows are the test case: without the right
  combination the depth map sampled by the shader was stale and the shadows stayed hard
  (`MESA_NV_DUMP_DEPTHTEX` on the Mesa side is what proved it).
* **Colour readback**: `wglQueryFramebufferChannelNV`-style reads and the
  render-texture store are served from the system framebuffer
  (`WINE_NV_RT_READ_FBO0`, on).
* **Perf**: `WINE_NV_MAP_ONCE` maps a vertex buffer once per buffer instead of once per
  draw (the Nalu/SteamID class of fix); `run.sh` enables it for `mermaid.exe`,
  `BugLooker.exe` and `PirateShip.exe`.

### 2.3 The fullscreen hack (FSHack)

The goal: every demo renders at the resolution written in its own `args.txt`, and Wine
scales and centres that image on the monitor the window manager chose, with correct
pointer input. It is a presentation hack, not an XRandR/CRTC change, so it also works
under Xwayland.

How it is turned on:

* the code itself is **off unless the environment asks** (`WINE_NV_FSHACK` unset = no
  hack, so an untouched Wine is unaffected);
* the project's launcher turns it **on by default** (`tools/nv_gates.sh`:
  `WINE_NV_FSHACK=1`, `WINE_NV_FSHACK_NOGRAB=1`) and derives the mode from the demo's
  argument file, so the mode is the demo's own choice rather than a global resolution;
* the presentation option `EmulateModeset` decides whether the framebuffer-surface path
  in `win32u/opengl.c` is used, i.e. whether a legacy fullscreen demo is shown scaled and
  centred with black bars or at native size in a corner. Upstream reads it from the registry
  only. Since 2026-11-04 the decision has three levels, taken in one place
  (`sysparams_init()`), with the same `IS_OPTION_TRUE` upstream uses:
    1. `WINE_NV_EMULATE_MODESET` (`y Y t T 1` = on, anything else = off);
    2. the registry value, upstream behaviour unchanged: `AppDefaults\<exe>\X11 Driver`
       first, then `HKCU\Software\Wine\X11 Driver`. This is the key the Wine control panel
       (`desk.cpl`) writes, so the control panel keeps working;
    3. if neither source decided, the FSHack machinery decides it: when `nv_fshack_init()`
       has really enabled the virtual desktop, the option turns on by itself.
  Level 3 is not a convenience: it removes a state that cannot work. Measured 2026-11-04
  with the release build, a prefix holding `EmulateModeset=Y` while the machinery is
  switched off leaves `vulcan.exe` with **no pixel above threshold** (black); with the
  machinery on, the same demo renders scaled and centred - content 2880x2160 with 480 px
  bars on a 3840x2160 desktop, 1440x1080 with 240 px bars on 1920x1080. With
  `WINE_NV_FSHACK=0` level 3 does not fire, so the `gamescope` path keeps the native
  presentation (`fbsurf=0`, not black). The recommended prefix state is **no**
  `EmulateModeset` entry at all: measured on such a prefix, the nine fullscreen demos come
  out scaled and centred from the environment alone (toys, which asks for 1280x1024, gets
  2712x2160 content with 564 px bars), while `blobby` keeps its own window because that is
  how the demo itself presents.
  Kept from upstream, and worth knowing: with this option on, `GetDeviceGammaRamp` and
  `SetDeviceGammaRamp` (`dlls/win32u/dc.c`) report failure, because Wine is not doing a
  real modeset.

What it changes, and the measurement behind each rule:

* **Fake mode list** (`WINE_NV_FSHACK_MODES`, `WINE_NV_FSHACK_GEOM`): the application must
  see its own mode. Pinning the framebuffer to the desktop size while the window is
  1920x1080 and the GL buffer 1440x1080 produced the "off-centre and cropped" complaint;
  `tools/nv_coerenza.sh` measures window-vs-framebuffer coherence for every demo.
* **Monitor choice** (`WINE_NV_FSHACK_MONITOR`): the monitor is chosen by maximum overlap
  between the **X window geometry** and the Xinerama monitor rectangles in **root
  coordinates**. `DisplayWidth()/DisplayHeight()` is the union of all screens, which on a
  4K + 1080p machine split one demo across both monitors (measured: content from x=1440 to
  x=5757 on a 5760x2160 desktop). Wine's host monitor list was also unusable for this:
  its rectangles are per-adapter, not root coordinates (measured: the 4K reported at
  `(-3840,0)` while X had it at `(0,0)`).
* **Which windows are scaled**: decided geometrically, not by `data->is_fullscreen`
  (unreliable under the hack) and not by monitor size alone. A window is treated as
  scaled when its X geometry is larger than the application mode **and** covers at least
  90% of the monitor on both axes. That single rule fixes two opposite bugs: GasStation,
  which is not marked fullscreen but is presented scaled, and Blobby Dancer's
  configuration window (281x397, presented 1:1), whose mouse input was being rescaled and
  clamped to nonsense points (`214,360 -> 0,256`).
* **Pointer input**: when a window is scaled, the pointer coordinates, the clip rectangle
  and the raw events are translated through the fit rectangle and offset by the monitor
  origin. Cursor clipping/grabbing is **refused by default** (`WINE_NV_FSHACK_NOGRAB=1`),
  because with raw-delta pointer warping a grab corrupts the input; `..._NORAW=1` was
  measured worse and stays off.
* **Present fit** (`WINE_NV_FSHACK_FIT=letterbox|stretch|integer`, default letterbox
  centred) and filter (`WINE_NV_FSHACK_FILTER=nearest`).
* **GL state isolation around the present**: the framebuffer-surface present internals
  (surface resize, blit with the fit rectangle, occasional read-backs) run in the
  application's context and mutate viewport, scissor, clear colour, draw/read buffers,
  programs, bindings and pixel store. The application does not call `glViewport` per
  frame (GLUT only does it on reshape), so it inherited a 1440x1080 viewport at (240,0)
  from Wine: invisible UI, washed-out colours, distorted picture. The patch saves and
  restores that state around `opengl_drawable_flush`. The hook must be at the *entrance*
  of the flush: saving inside the blit captures an already-altered baseline.
* **sRGB stays off** (`WINE_NV_FSHACK_SRGB`): enabling `GL_FRAMEBUFFER_SRGB` in the
  present path measured as double encoding, i.e. visibly too bright.
* **The blit-only branch stays off** (`WINE_NV_FSHACK_BLITONLY`): forcing it produced a
  black screen.

### 2.4 Timing: the synthetic QPC

`WINE_QPC_STEP=<ns>`, `WINE_QPC_QUANT=<ns>`, `WINE_QPC_REPORT` make
`QueryPerformanceCounter` advance like the counter those demos were tuned against. The
Vulcan spin loop (`docs/vulcan-perf.md`) is the reason: with a free-running modern
counter the animation and the frame pacing diverge.

### 2.5 Environment knobs

The launcher (`run.sh` through `tools/nv_gates.sh`) sets some of these per executable; a
value you export yourself always wins. Unless the table says otherwise the default is
**off/unset**, i.e. plain upstream behaviour.

Fullscreen hack

| knob | default | effect |
|------|---------|--------|
| `WINE_NV_FSHACK=1\\|0` | off in the code, **on in run.sh** | master switch; requires `WINE_NV_FSHACK_MODE` or a mode derived from the demo's args |
| `WINE_NV_FSHACK_MODE=WxH` | unset | the fake desktop mode; the launcher derives it from the demo's `args.txt` |
| `WINE_NV_FSHACK_MODES=native` | fake list | lets the application enumerate the real modes instead |
| `WINE_NV_FSHACK_GEOM=fake` | off | report the fake geometry as the real one (measured: breaks the present chain on several demos) |
| `WINE_NV_FSHACK_PIN=1\\|0` | measured default | pin the X window to the monitor origin and size |
| `WINE_NV_FSHACK_WIN=0` | on when the hack is on | window geometry / monitor-rect forcing |
| `WINE_NV_FSHACK_FIT=letterbox\\|stretch\\|integer` | letterbox, centred | how the frame is scaled onto the monitor |
| `WINE_NV_FSHACK_FILTER=nearest` | linear | scaling filter of the present blit |
| `WINE_NV_FSHACK_MONITOR=primary` | automatic | force the primary monitor instead of the one chosen by geometry |
| `WINE_NV_FSHACK_SRGB=1` | off | enable `GL_FRAMEBUFFER_SRGB` during the present (measured double encoding) |
| `WINE_NV_FSHACK_BLITONLY=1` | off | force the blit branch of the present (measured black) |
| `WINE_NV_FSHACK_VP=0` | on | recompute the application viewport from the client surface |
| `WINE_NV_FSHACK_MOUSE=0` | on when the hack is on | translate pointer coordinates through the fit rectangle |
| `WINE_NV_FSHACK_NOGRAB=1` | off in code, **on in run.sh** | refuse pointer grab/clip (raw-delta warping corrupts input) |
| `WINE_NV_FSHACK_NORAW=1` | off | suppress raw pointer events (measured worse) |
| `WINE_USE_EGL=0` | forced by `run.sh` | Wine's EGL backend does not advertise the extensions above; GLX is required |
| `WINE_NV_EMULATE_MODESET=<0|1>` | unset: the FSHack machinery decides (2.3) | explicit control of the presentation option; `0` restores the native corner presentation even with FSHack on, and `1` forces it even with FSHack off, which is the combination that shows nothing |

pbuffers, render textures, float formats

| knob | default | effect |
|------|---------|--------|
| `WINE_NV_ADVERTISE_DEPTH_TEXTURE=1` | off | advertise `WGL_NV_render_depth_texture` |
| `WINE_NV_ADVERTISE_NV_FLOAT=1` | off | advertise `WGL_NV_float_buffer` |
| `WINE_NV_TFP=<path>` | automatic | which `texture_from_pixmap` path to use for `wglBindTexImageARB` |
| `WINE_NV_TFP_BACK=<buf>` | front | which GLX buffer feeds the texture |
| `WINE_NV_RT_COLOR_TFP=0` | **on** | colour render textures without a copy (set 0 to force the copy) |
| `WINE_NV_RT_READ_FBO0=0` | **on** | read from the system framebuffer |
| `WINE_NV_RT_FOLLOW_TEX_FORMAT=1` | off | the colour delivery takes the channel width from the texture the application allocated: when that texture is RGBA16F, RGB16F, RGBA32F or RGB32F the delivery stays wide instead of redefining the storage to 8 bits
| `WINE_NV_PBUFFER_FLIP_SIZES=<WxH[,WxH]>` | every size | limits the row flip of `WINE_NV_PBUFFER_FLIP` to the listed sizes |
| `WINE_NV_PBUFFER_RT_FBO=1` | off | persistent FBO for render-to-texture pbuffers |
| `WINE_NV_PBUFFER_CUBE_LATCH=1` | off (run.sh turns it on for Mad Mod Mike) | at `wglSetPbufferAttribARB`, copy the pbuffer surface into the cube face the application is leaving, so the six per-face passes of one frame are not lost; reads the surface only while this pbuffer is the drawable of the calling context, and puts back `GL_READ_BUFFER` and the scissor test (measured on Mad Mod Mike: without it one 96x96 cube showed the same wall view in all six faces, L1 of 0.00 per channel) |
| `WINE_NV_PBUFFER_CUBE_LATCH=2` | off (run.sh uses this shape for Mad Mod Mike) | save-and-restore cube latch: after the leaving face is copied into the cube, the entering face is copied from the cube back into the single pbuffer surface. This is what real hardware gives when the demo revisits a face later in the same frame, and it stops Mike's RGB and alpha soft-cube passes from mixing the state of different faces. |
| `WINE_NV_PBUFFER_CUBE_FACE_FBO=1` | off | other shape of the same fix: attach the named cube face as the colour attachment of the framebuffer this context uses for the pbuffer, created at face selection and never at make-current (an attempt hooked at make-current produced an access violation inside `wglMakeContextCurrentARB`), and skip the delivery copy while it is active It also covers depth cubes: for a pbuffer made through WGL_NV_render_depth_texture and never bound as colour, the selected face is attached as GL_DEPTH_ATTACHMENT and the depth copy is skipped (CUBE-DEPTH-ASSOC, CUBE-DEPTH-SKIP); needed because Mad Mod Mike's 96x96 depth cube has 6013 face selections and 2 binds per frame in the reference trace and zero face deliveries in ours |
| `WINE_NV_CUBE_STORE_DEPTH=1` | off in the code, **on for Mad Mod Mike through run.sh** | lets the two cube-face levers above also take over **depth** cube pbuffers. The measurement of 2026-11-12 that kept it off: Mad Mod Mike's 96x96 depth cube (object 8 in the census, the omni shadow store) is attached face by face by the application itself - the new `MESA_NV_TRACE_FBATTACH` probe shows 1416 attachments on +X, 1416 on -Z and 708 on each of the remaining four faces for that one object in a 708-swap run - and what the survey read in those faces was a symmetric distance blob: depth mean 0.0743, 0.0000..0.2824, identical on all six faces. With the levers applied to that pbuffer the six faces hold something else instead (mean 0.1180 with the store, 0.4664 with store and latch together, structured with hard black areas). That reading is withdrawn as of 2026-11-13: it came from a chain that was delivering the cube badly, and the face dump shows what the guard closed actually leaves behind. Two runs with identical probes and the same dump, guard closed then open: on the 96x96 faces the fraction of texels under 2 percent of luminance goes 55.06 to 0.00 and 56.62 to 0.00, distinct colours go 152 to 482 and 292 to 1116, on the 80x80 face 1396 to 2851. A phase-controlled pair (1280x720 window, every exchange captured) is byte identical at exchanges 0 and 2 and separates at exchange 4, where 27.44 percent of the sampled pixels change, 6.23 percent brighter and 5.93 percent darker; at exchange 6 it is 67.33 percent, 20.68 brighter and 21.39 darker. Brighter where the indirect lighting fills in, darker where the shadow lands. The judgment at the screen asked for this to stay on for the demo, and the hard omni shadows, the jetpack spikes and the composite tile were not fixed by it.
| `WINE_NV_PBUFFER_SPLIT_FMT=1` | off | do not let the depth-texture request erase the colour bind format (Luna asks both on one pbuffer) |
| `WINE_NV_PBUFFER_PROMOTE_FLOAT=1` | off | give render-to-texture pbuffers real float storage even when the pixel format is fixed-point (measured on Luna: engages, but the copies come out empty, so the draws do not land in the store we own) |
| `WINE_NV_PBUFFER_RT_ALIAS=1` | off (gate sets it for `mermaid.exe`) | alias the pbuffer render texture |
| `WINE_NV_PBUFFER_READ_FBO=1` | off | read the pbuffer through its FBO |
| `WINE_NV_PBUFFER_BLIT=1` | off | blit instead of `ReadPixels` for the pbuffer copy |
| `WINE_NV_PBUFFER_COPY=<mode>` | measured default | copy vs zero-copy per frame (Nalu: both give the same content) |
| `WINE_NV_PBUFFER_LATE=1\\|2` | off | late copy using Wine's internal (1) or the client (2) context |
| `WINE_NV_PBUFFER_DETACH_COPY=1` | off | copy at detach time |
| `WINE_NV_PBUFFER_SYNC=1` | off | `glFinish` before reading pbuffer pixels back |
| `WINE_NV_PBUFFER_FLIP=1` | off | flip the row order of the pixels read from a colour pbuffer before uploading them; measured on Mad Mod Mike it must stay off, the delivered store is already oriented like the scene |
| `WINE_NV_PBUFFER_SOURCE=<f\\|b\\|d\\|n>` | front -> `GL_BACK` | which source buffer feeds the ptexture: `f`ront, `b`ack, `d`ouble, `n`one |
| `WINE_NV_PBUFFER_COPY=<mode>` | the zero-copy path | `f`ront / `b`ack / `d`ouble / `n`one copy mode; on Nalu both paths give the same content per frame |
| `WINE_NV_PBUFFER_FLOAT_FALLBACK=1` | off (gate sets it for `BugLooker.exe`) | accept a float pbuffer request that the format list cannot satisfy, together with `MESA_NV_LEGACY_BUFFERS` |
| `WINE_NV_WGL_FLOAT_TYPE_RGBA=1` | off (the run script sets it for Luna only) | make the duplicated float pixel formats declare themselves as WGL_TYPE_RGBA_ARB and bindable as RGBA float textures; without this the demo's wglChoosePixelFormatARB request (pixel type RGBA, float components, bind to texture RGBA) can never match our float copies, which used to report WGL_TYPE_RGBA_FLOAT_ATI with texture binding off, and its float pbuffer chain fails |
| `WINE_NV_FLOAT_FBO=<...>`, `WINE_NV_FLOAT_PFB=<0\\|1>`, `WINE_NV_FLOAT_DUP_MAX=<n>` | automatic; `FLOAT_PFB` follows `WINE_NV_PBUFFER_FLOAT_FALLBACK` unless set to `0`; the run script sets `WINE_NV_FLOAT_PFB=0` for Mad Mod Mike, where the substitute float store is the two bloom colour stores and the demo's draws never land in them (measured 2026-11-11: 0 of 803 reads with content with the substitute in place, 794 of 801 once it is refused) | float pbuffer plumbing and format duplication |
| `WINE_NV_DEPTH_INLINE=1`, `WINE_NV_DEPTH_KEEP_CURRENT=1`, `WINE_NV_DEPTH_PICK_CTX=1`, `WINE_NV_DEPTH_BIND_CTX=1`, `WINE_NV_DEPTH_FORCE_READBACK=1` | off | the depth-archive paths of section 2.2 |
| `WINE_NV_DEPTH_READBUF=<mode>` | automatic | which read buffer the depth copy uses |
| `WINE_NV_LATE_DEPTH_CONTENT=1`, `WINE_NV_LATE_DEPTH_DRAWER_CTX=1` | off | where the late depth content comes from |
| `WINE_NV_MAP_ONCE=1\\|all\\|yes` | off (gate on for three demos) | map each vertex buffer once instead of once per draw |

Timing

| knob | default | effect |
|------|---------|--------|
| `WINE_QPC_STEP=<ns>` | off | make the QPC advance by a fixed step (synthetic clock) |
| `WINE_QPC_QUANT=<ns>` | off | quantise the QPC to a period, like 2005 hardware |
| `WINE_QPC_REPORT=<n>` | off | print QPC read statistics (`WINE_QPC_*` live in `ntdll/unix/sync.c`) |

---

## 3. `0002-nv-legacy-diagnostics.patch`

Same marker mechanism as the Mesa series (`nvdbg:begin/end`, `nvdbg:keep-begin/end`);
this patch only prints and captures, it must not change what a demo draws. Everything
goes to `stderr` under an `nvlegacy <LABEL>:` prefix, capped per call site.

| knob | what it does |
|------|--------------|
| `WINE_NV_FSHACK_DUMP=<dir>` | dumps the presented frames on the Wine side |
| `WINE_NV_FSHACK_DUMP_MAX=<n>` | cap for the dump count |
| `WINE_NV_RT_DUMP_DIR=<dir>`, `WINE_NV_RT_DUMP_EVERY`, `_MAX`, `_SIZE` | dump the render-texture store as read back by Wine (used to prove the depth archive was stale) |
| `WINE_NV_TRACE_MONITOR=1` | prints the monitor-geometry decision per window. **Off by default**: a short GasStation run produced 189142 lines / 37 MB |
| `WINE_NV_TRACE_SWAP=<n>` | one line per swap/present, capped at `n` |
| `WINE_NV_TRACE_RT_FBO=1` | prints which per-context store framebuffer the copy really reads, with both context pointers: the key used by the lookup is glReserved2, not glContext |
| `WINE_NV_TRACE_WGL=1` | traces the WGL entry points (`wglMakeCurrent`, `wglBindTexImageARB`, ...) |
- With `WINEDEBUG=+seh`, ntdll's first-chance dispatcher additionally prints `nvlegacy EXCDUMP` blocks for access violations: exception code and address, the faulting access and target, the guest registers and raw hex windows of the stack and of the memory each register points at. It exists because an attached debugger changes which failure happens first on Luna, so the only valid observation of that crash is one taken from an unattached process. Capped at 40 dumps per image; diagnostics series only, absent from a release build.
  Measured caveat, added the 8th of November 2026 while working on Mad Mod Mike (PE32 i386): for a 32-bit app under WoW64 the *address* in the record is right and the *registers* are not. `BTCpuResetToConsistentState` in `dlls/wow64cpu/cpu.c` rewrites the context a dozen lines before the guest's handler chain runs (`Rip` becomes `syscall_32to64`, `Rsp` becomes `R14`, the code selector becomes the 64-bit one), so what the ntdll dumper printed for Mike was `addr=004A03AF` together with `eip=7bc41110`, i.e. Wine's own code. The earlier claim in this bullet that 32-bit demos simply run on the i386 ntdll and are therefore covered was wrong: the i386 values that are real are produced inside that wow64cpu function by `copy_context_64to32`, so the dump has to be taken there.
- `nvlegacy EXC32` (same gate, `TRACE_ON(seh)`, diagnostics series): the dump of the guest i386 state at that one place - the full register set, cs/ss selectors, 48 words of the guest stack starting at `Esp`, and a -0x20..+0x50 window around every register value, with any word that points at printable text also printed as text. Windows are relative on purpose: absolute heap addresses in this engine family have already misled us once, and without the text printing the only name that mattered (`const_bias`, the constant parameter being applied when the demo faults) would have shown up as four ASCII bytes by luck. Two constraints found the hard way and recorded in the code: `__TRY`/`__EXCEPT` cannot be used in `wow64cpu.dll` at all (the macros pull in `libs/winecrt0/exception.o` and the link of `dlls/wow64cpu/x86_64-windows/wow64cpu.dll` fails with an undefined reference), so memory reads go through `NtReadVirtualMemory` on the current process with shrinking request sizes because a single read can straddle a page end; and in that build the i386 context fields are 32-bit while pointers are 64, so casts pass through `ULONG_PTR`. Wine-side faults are skipped - measured in one Mike run: 230 access violations, 90 of them Wine's own probes at 7BCD2B60, 46 inside the translation layer, and only 2 at the demo's crash site - and the dump is capped at 40.
- Usage trap, measured the same day: `WINEDEBUG=-all+seh` prints NOTHING from either dumper, while plain `WINEDEBUG=+seh` printed 770 lines. Observing a fault needs the channel enabled without `-all`.
| `WINE_NV_TRACE_ACTIVATE=1` | traces context activation, capped at 40 lines |
| `WINE_NV_TRACE_SIZE=1` | traces window/drawable size decisions |

Three more trace switches read their variable inside keep-regions of the features patch
(`WINE_NV_TRACE_DEPTHBIND`, `WINE_NV_TRACE_FBO`, `WINE_NV_TRACE_MKCUR`) because the code
that reports the state lives with the feature; they behave the same way (set to any
non-empty value, capped line count).

---

## 4. Checking a change to these patches

```sh
bash tools/nv_allinea_wine.sh /home/wine/tmp/nv-legacy-src/wine
python3 tools/make_nv_patches.py --dev /home/wine/tmp/nv-legacy-src/wine --tag wine-11.18 \
        --work /home/wine/tmp/nv-wine-patchgen --out "$(pwd)/patches/wine"
python3 tools/nv_check_nvdbg_balance.py
python3 tools/nv_codice_file.py wine 060e1d8            # code identical to a validated state
python3 tools/nv_codice_file.py wine HEAD --scheletro   # only strings/comments changed
python3 tools/nv_codice_file.py wine HEAD --nomi        # only identifier names changed
python3 tools/nv_audit_localizzazione.py
./build.sh --wine-only --no-patches          # dev tree already annotated
./build.sh --wine-only --no-wine-diag        # proves 0001 stands alone
bash tools/nv_allinea_wine.sh /home/wine/tmp/nv-legacy-src/wine   # restore the annotated dev tree
bash tools/nv_fs_sweep.sh                    # 10 fullscreen demos: frames presented, no GL errors
bash tools/nv_sweep_contenuto.sh             # 12 demos: content signal, exceptions 0
bash tools/nv_smoke.sh <exe> [argsfile] [tag]   # which libraries are loaded, known failure counters
bash tools/nv_fs_guarda.sh <dir>             # presented size, fit rectangle, blit branch
bash tools/nv_blobby_menu_probe.sh           # key D, then pointer input on the config window
bash tools/nv_wine_stop.sh                   # never leave Wine running (OLED panel)
```

`nv_fs_sweep.sh` and `nv_smoke.sh` count log labels written by this patch. Renaming a
label means updating those greps - that has already happened once
(`BLIT-RAMO` -> `BLIT-BRANCH`, `DEPTH-BIND-SALTATA` -> `DEPTH-BIND-SKIPPED`).

## Magazzino di profondita su richiesta per i pbuffer: WINE_NV_PBUFFER_DEPTH_STORE

`WINE_NV_PBUFFER_DEPTH_STORE=1  (spento di default ) crea il framebuffer per contesto di un pbuffer dentro
il solo legame della sua profondita come render texture (`bind_depth_buffer_to_texture ), senza accendere il
percorso globale `WINE_NV_PBUFFER_RT_FBO, che su Luna ribattezza anche i magazzini a colori e produce una
palla di luce satura. Serve perche la misura mostrava che il legame di profondita entrava con `draw_fbo=0
e `read_fbo=0: senza un framebuffer non c'era nulla a cui allegare la texture della demo, le mappe di
profondita campate dagli shader restavano zera (dump `min=0 max=0  sul 2048x2048  e sul 1024x1024 ) e il
confronto d'ombra non poteva rilevare occlusione.

Stato misurato aggiornato, in due passi.

Primo passo, il magazzino nasce: la traccia `nvlegacy PFB-RT: persistent FBO #2... (map=1)  compare per i
pbuffer 1024x1024, 2048x2048 e 256x256. Prima mancava perche l'helper pretendeva il contrassegno di render
texture, che ora viene posto al legame di profondita, e perche la ricerca `nv_rt_fb(pbuffer)  risolveva il
magazzino di un contesto diverso da quello del legame: ora si usa `nv_rt_fb_per_ctx(drawable, context ).

Secondo passo, l'attacco della texture della demo come `DEPTH_ATTACHMENT  di quel magazzino funziona  e la
consegna avviene: le mappe 512x512 passano da tutte zera  a `min=0.34902 max=1  media `0.992039, che é
la forma attesa di una mappa di profondita azzerata a 1  con la geometria sotto. Traccia dedicata
`nvlegacy DEPTH-ALIAS: texture=3 nel framebuffer=3 per il pbuffer 2048x2048  (fino a 16 righe, gate
`WINE_NV_TRACE_DEPTHBIND /`WINE_NV_TRACE_WGL ).

Pero l'aliasing applicato a tutti i pbuffer rompe la composizione: giudizio visivo dell'utente su questa
run, "si vede solo un pezzo 512x512 centrato ", e la lettura dei dati lo spiega: gli stessi magazzini dei
pbuffer 512x512  e 256x256  vengono legati anche come colore (`nvlegacy BIND: buffer 0x2083  con
`texture_format=0x1902, 6510 legami ) e riattaccandogli la profondita si sposta il punto in cui la catena
di composizione scrive e legge.

Quindi la strada che la misura indica NON e attaccare l'allegato di profondita. E consegnare il contenuto del
buffer di profondita dentro la texture che la demo stessa alloca come GL_DEPTH_COMPONENT24 (quattro da
256x256, identiche numero per numero fra trace di riferimento e nostro) con una copia: lettura
GL_DEPTH_COMPONENT dal framebuffer del pbuffer e glTexSubImage2D nel formato della texture. Cosi non si
toccano gli allegati dei framebuffer e non si tocca la composizione. Il knob attuale resta spento di default
e lesecuzione accettata di Luna non viene modificata.

Matrice di knob gia esistenti, rieseguita dopo aver separato le modalita (STORE=1 crea e basta, STORE=2
attacca), con dump delle mappe di profondita in ogni variante: base (nessun knob), STORE=1, STORE=1 con
RT_READ_FBO0=0, DEPTH_PICK_CTX=1 con STORE=1, PBUFFER_READ_FBO=1, DEPTH_INLINE=1. Le due texture di profondita
che gli shader leggono davvero, tex 3 da 2048x2048 e tex 6 da 1024x1024, restano min=0 max=0 mean=0 in tutte
e sei esecuzioni. Cambia invece il numero di legami saltati: 284 nella base, 6727 con STORE=1, 6657 con
STORE=1 e RT_READ_FBO0=0, 1691 con DEPTH_PICK_CTX=1, 283 con PBUFFER_READ_FBO=1, 285 con DEPTH_INLINE=1.
Nessuna combinazione esistente consegna quindi il contenuto; laspetto aperto resta la copia del buffer di
profondita letto nel contesto che ha disegnato la mappa, che richiede il percorso per contesto gia usato per
Nalu (i campi nv_contexts e nv_context_full) e non e una modifica da poche righe.

Copia del buffer di profondita, implementata e misurata, esito visivo negativo. Nuovo knob
WINE_NV_PBUFFER_DEPTH_COPY, spento di default: valore 1 legge il magazzino di Wine del contesto che ha
disegnato, valore 2 legge il framebuffer di sistema (framebuffer 0) di quel contesto; in entrambi i casi
carica con glReadPixels GL_DEPTH_COMPONENT GL_FLOAT e glTexSubImage2D dentro la texture della demo, senza
toccare nessun allegato. Le esecuzioni di prova danno 16 copie su 16 riuscite, che coprono proprio le
texture giuste: tex 3 da 2048x2048, tex 6 da 1024x1024 e le mappe 256x256 tex 30, 31, 32 e 33. La mappa
campionata smette di essere tutta zera: con valore 1 min=0 max=1, copertura nz da 0.011 a 0.038; con
valore 2 la copertura sale a nz da 0.080 a 0.098, cioé il doppio. La media resta pero bassa, 0.040-0.049,
quindi il fondo della mappa é vicino a zero e non vicino a 1.

Giudizio visivo dell'utente su questa run: non é migliorato. Il quadro che resta dai censimenti, e che le
misure sulla consegna non hanno contraddetto: le unita campate dai programmi delle ombre sono texture a
colore 256x256 con formato base GL_RGBA e senza modalita di confronto (cmp=#x0), mentre i due formati di
profondita compaiono solo come allegati del framebuffer di disegno. La copia dunque finisce dentro texture di
profondita che potrebbero non essere gli oggetti letti dai programmi. I knob restano spenti, la
configurazione accettata di Luna non cambia.
## Render texture a colori: adesione con il pname privato 0x8fff0002

### Modalita 2: la texture della demo diventa il magazzino del pbuffer, senza copia

`WINE_NV_RT_COLOR_ALIAS=2  non fa ladozione lato Mesa e non copia niente: nel ramo colori di
`wglBindTexImageARB  cerca il framebuffer che quel contesto usa per disegnare il pbuffer (`nv_rt_fb,
e in subordine `pbuffer->drawable->draw_fbo ) e ci attacca la texture della demo come
`COLOR_ATTACHMENT0  con `glFramebufferTexture2D. Se lo stato del framebuffer e completo il legame e
riuscito, e la copia viene saltata perche non serve: i disegni della demo finiscono dentro la texture
che i suoi shader leggeranno piu tardi nello stesso fotogramma. E la stessa forma del percorso di
profondita (`bind_depth_buffer_to_texture ), e la semantica che il driver d'epoca aveva con
`WGL_NV_render_texture. Se quel framebuffer non esiste il codice non fa nulla e resta la copia di
prima, quindi la modalita 2 si puo provare senza rischio di regressione sul percorso gia in uso. La
stampa diagnostica e `nvlegacy COLOUR-ATTACH, limitata a 400 righe per contare tutta lesecuzione e
non solo lavvio.

La modalita 2 attiva da sola anche il percorso a framebuffer per contesto del pbuffer
(`nvlegacy_pbuffer_rt_fbo  ritorna vero ): senza di esso la maggior parte dei legami non trova un
framebuffer da riattaccare e ricade sulla copia vecchia. Misura dallestensione, con il solo
`WINE_NV_RT_COLOR_ALIAS=2  in 24 secondi: attaccamenti riusciti saliti da 25 a 249 su 400 tentativi,
149 sul tipo 256x256 e 100 sul tipo 512x512, tentativi ancora senza framebuffer scesi da 375 a 151,
zero errori GL e zero cadute. Restano invariati i due divieti misurati: `WINE_NV_PBUFFER_RT_FBO,
preso da solo, scurisce la scena, e la modalita 1 porta Luna a uneccezione di accesso.

Misura che ha chiuso il difetto visivo di Luna, con il solo knob a 2: 400 tentativi in 22 secondi
(tetto della stampa, quindi il totale reale e piu alto), 25 attaccamenti riusciti e tutti sul magazzino
a colori 512x512 che la demo usa come campo di spessore, 375 tentativi ricaduti sulla copia, nessuna
caduta. Venature e trasparenza del tessuto ricompaiono, e il giudizio di correttezza arrivato
guardando lo schermo. `run.sh  imposta 2 nel solo ramo Luna; la modalita 1 non viene usata perche
andava in eccezione, e `WINE_NV_PBUFFER_RT_FBO  da solo scurisce la scena.

`WINE_NV_RT_COLOR_ALIAS=1  (spento di default ) nel ramo colori di `wglBindTexImageARB  dichiara la texture
della demo alla nostra Mesa con `glTexParameteri(target, 0x8fff0002, nome_framebuffer: il valore e il nome del
framebuffer in cui quel pbuffer viene disegnato nel contesto corrente, risolto da `nv_rt_fb( pbuffer ). Mesa
raccoglie ladozione in `main/texparam.c  (sia la forma scalare sia la `iv ) e ripete la consegna del contenuto
al momento del campionamento invece che al legame: senza questa adesione i passaggi di post-elaborazione di Luna
rileggono la superficie piu tardi nello stesso fotogramma e trovano il contenuto del legame precedente. Perche
ce ne sia bisogno, misura: il legame a zero copia del driver sui pbuffer a colori non porta contenuto su questo
strato, 36251 righe `nvlegacy BIND-TFP  con `ret=-1  su una esecuzione di Luna. La stampa `nvlegacy
COLOUR-ALIAS  e nella serie di diagnostica (0002 ).

## Consegna delle ombre di Luna: che cosa hanno misurato i percorsi di prova (notte 7-8 novembre)

Pagina aggiornata con le misure prese sul percorso delle render texture di profondita e a colori,
dopo le due prove di consegna accettate in precedenza. Tutti i knob nuovi restano SPENTI di default
e `run.sh  non é toccato: nessuna delle altre demo passa da questi percorsi.

### `WINE_NV_PBUFFER_DEPTH_STORE: modalita 1, 2, filtro di taglie

- modalita 1: crea il magazzino per contesto del pbuffer quando viene legata la sua profondita;
- modalita 2: aliasing vero, la texture della demo diventa `DEPTH_ATTACHMENT  del framebuffer del
  pbuffer (come faceva il driver del 2004 ).
- `WINE_NV_PBUFFER_DEPTH_STORE_SIZES=<WxH[,WxH] >: limita la modalita 2 ai magazzini delle taglie
  elencate. Senza filtro la modalita 2 riattaccava la profondita anche ai magazzini usati da altri
  passaggi e Luna mostrava solo un pezzo 512x512 centrato; con `2048x2048  (la mappa che la lookup
  `SHADOW2D  campiona ) la composizione resta intatta  e la parete a LED é corretta.
- Misura con la modalita 2 limitata a 2048x2048, fotogrammi presentati con clock deterministico e
  FSHACK spento: media del fotogramma della cupola 0.1296  (base  0.1330 ).

### `WINE_NV_RT_CHANNELS=<dir>` e `WINE_NV_RT_CHANNELS_MAX=<n>`: contenuto per canale delle superfici consegnate

Sonda di sola diagnosi. Rilegge la superficie che Wine sta per copiare nella texture della demo e
stampa, per ogni legame, media e frazione di texel non zero di ciascun canale; scrive anche un PGM
dell'alfa e un PPM del colore. `WINE_NV_RT_CHANNELS_MAX` (default 12) dice quante sonde fare.

Nota di misura sul tetto, perché prima era un mio errore di osservazione: con 12 sonde si vedono solo
le prime cornici, e la catena di bloom di Mad Mod Mike disegna piu tardi. Alzando il tetto a 400 su
una corsa da 13 s (416 scambi, 400 sonde, 0 cadute) il quadro cambia solo in parte:

    hdc=0x1010077 428x268   98 legami campionati   con contenuto: 0 su 98
    hdc=0x1010078 428x268   49 legami campionati   con contenuto: 0 su 49
    hdc=0x1010073 912x576   49 legami             con contenuto: 49 su 49  (media rossa 0,240)
    hdc=0x101006e 96x96     49 legami             con contenuto: 49 su 49
    hdc=0x101006f 80x80     49 legami             con contenuto: 49 su 49
    hdc=0x1010070 80x80     49 legami             con contenuto: 49 su 49
    hdc=0x1010071 96x96     49 legami             con contenuto: 49 su 49
    hdc=0x201006b 256x256    4 legami             con contenuto: 4 su 4   (media rossa 0,888)
    hdc=0x101006c 256x256    4 legami             con contenuto: 0 su 4

Quindi i due pannelli 428x268 restano vuoti su tutti e quattro i canali in 147 legami su 147, su
tutta la corsa: non era un artefatto del tetto. Vuoto resta anche uno dei due 256x256.

### `WINE_NV_PBUFFER_DEPTH_COPY: modalita 1, 2, 3, 4, 5, 6 e le rampe 7, 8, 9

Il percorso di copia legge la profondita e la carica nella texture della demo con
`glReadPixels(GL_DEPTH_COMPONENT ) + `glTexSubImage2D. Tagli misurati:

- modalita 1 legge il magazzino di Wine; 2 e 3 leggono il framebuffer di sistema del contesto che ha
  disegnato (3 rimappa anche i texel vuoti al valor di lontano); 4 inietta un pattern noto; 5 come 3
  ma salta i pbuffer legati anche a colori; 6 legge il framebuffer proprio del drawable con una
  guardia che rifiuta la lettura se lallegato non ha la dimensione giusta.
- `WINE_NV_PBUFFER_DEPTH_COPY_SIZES=<WxH[,WxH]|all >`: limita la copia alle taglie elencate. Serve
  perche la copia su tutti i magazzini costa 16 caricamenti fino a 16 MB per fotogramma e porta Luna
  da circa 3.8 a circa 0.5 fotogrammi al secondo, il che rende anche impossibile arrivare
  allindice di fotogramma cercato.
- `WINE_NV_PBUFFER_DEPTH_COPY_LEVEL=<0..1 >: con modalita 4 scrive un valore costante su tutta la
  mappa. Misura decisiva: sei esecuzioni con livelli 0.05, 0.2, 0.4, 0.6, 0.8, 0.97  (copia
  limitata a 2048x2048 ) danno fotogrammi presentati identici  (media 168: 0.56586, 0.51713,
  0.53060, 0.50998, 0.55345  e 0.10255 /0.102514 /0.102546 /0.102546 /0.102516  nellaltro
  parametro di fotogramma ) -> la nostra scrittura non arriva a cio che il programma legge, perche
  la demo ridisegna la mappa nello stesso oggetto.
- modalita 7, 8, 9: rampe lungo x, lungo y, lungo y invertito, per leggere orientamento e scala.
  Le tre varianti non cambiano quasi la scena disegnata.

* `WINE_NV_RT_COLOR_FLOAT_STORE=1` - **off** - in `nv_render_tex_bound`: allocate the pbuffer
  render-texture colour store as `WGL_TYPE_RGBA_FLOAT_ATI` / 16 bits per channel (RGBA16F) instead
  of the width the duplicated GLX config advertises, and let float-marked pbuffers reach the
  function at all (win32u only sets `nv_render_tex` on the plain creation path; measured
  `428x268 render_tex=0 float=1`). Measured 2026-11-14 on Mad Mod Mike: the two bloom stores then
  exist (witness `PFB-RT-IDENTITA: ... fbo=6 attaccamento=0x1702 nome=24 lato=428 float=1`), and
  with `WINE_NV_RT_COLOR_ALIAS=4 WINE_NV_RT_COLOR_ALIAS_SIZES=428x268` they are attached to the
  application texture (sampled alpha mean 15.06/15.60 against 14.72/15.23 in the product path,
  share above the demo heat gate 34/255 up to 18.38% from 16.95%, alpha peak 97 against 118, zero
  exceptions). This does NOT remove the composite heat rectangle: correctness of the colour space
  and of object identity, not the visual defect.
  * `WINE_NV_RT_HALF_READBACK=1` - **off** - in the pbuffer render-texture colour copy: ask the
    readback for `GL_HALF_FLOAT` (0x140B) instead of `GL_FLOAT`, matching the RGBA16F storage of
    the store we build, size the payload accordingly (two bytes per channel) and decode the
    payload statistics through a half-to-float converter. Measured 2026-11-16 on Mad Mod Mike:
    with `WINE_NV_FLOAT_PFB=1 WINE_NV_PBUFFER_RT_FBO=1 WINE_NV_RT_COLOR_FLOAT_STORE=1
    WINE_NV_PBUFFER_READ_FBO=1` the copy really switches to `type=0x1406 internal=0x881a`, the
    readback answers `err_read=0x502` and the payload is uninitialized memory (channels negative
    or NaN: `payload_r_nz=1.000` with means 0.0000 over 1643520 bytes). With this knob the copy
    asks `type=0x140b`, the payload has the right size (821760 bytes = 428x240x4x2) and 615101
    of its bytes are non-zero, but the readback STILL answers `err_read=0x502` and the values
    stay negative or NaN. So the blocker is not the readback type: the wide store built for the
    float pbuffer is not readable from where the copy reads, and the half-float bloom chain is an
    open item. No product path turns any of these on; with them on the picture gets worse
    (mean luminance 32.1/33.5/47.5 against the 8-bit control 33.9/67.5/46.6 on the same swaps)
    because the bloom receives no content.

  * `WINE_NV_RT_8BIT_READ=1` - **off** - measuring instrument, not a rendering choice: keeps the
    colour readback of a pbuffer render texture at `GL_UNSIGNED_BYTE` (and the application's
    texture at `GL_RGBA8`) even when the store was built wide, so that the share of colour bytes
    pinned at 255 can be read out of the `payload_sat255` field of the COPY witness: reading a
    wide store as bytes converts and clamps at one, so 255 would be the fingerprint of values
    above one. Measured 2026-11-16 on Mad Mod Mike with the float store and `READ_FBO` on: the
    copy asks `type=0x1401 internal=0x8058` again, and `payload_sat255` is 0.0000 on every one of
    the last 400 deliveries and of the whole run, i.e. no colour byte is pinned at 255. The
    readback of those deliveries answers `err_read=0x502` (26319 of 26324), so the payload numbers
    of that arm are the content of a failed read, not the content of the store; the few deliveries
    with `err_read=0` are early in the run and show alpha mean 0.0001 with coverage 0.003, the same
    picture as the 8-bit product path. Negative result for the clamped-HDR hypothesis in the
    configuration tried; the blocker stays the invalid readback of the wide store.

* `WINE_NV_TRACE_RT_REASON=<lines>` - off - one `PFB-RT-REASON` line per drawable reaching
  `nv_render_tex_bound`, printed BEFORE any gate, naming size, `render_tex`, `float`, context
  presence and the three entry gates: it tells "never called" from "refused by a gate", which is
  where the store hunt had gone wrong.

### `WINE_NV_RT_COLOR_ALIAS: modalita 3 e 4 con `WINE_NV_RT_COLOR_ALIAS_SIZES

- modalita 2  (gia accettata ) attacca la texture della demo al framebuffer che il pbuffer ha gia:
  su Luna erano 25 attacchi riusciti su 400 tentativi, tutti il magazzino 512x512, e basta per le
  venature.
- modalita 3: attacca solo le taglie elencate, disattivando le altre (utile per isolare, ma perde
  lattacco 512x512  che tiene vive le venature ).
- modalita 4: tiene il comportamento della modalita 2  e in piu crea il magazzino e attacca per le
  taglie elencate. Misura con `TAGLIE=256x256: la media del fotogramma della cupola passa da
  0.11953  a 0.09813; guardando il fotogramma  lombra sotto gli arti delle creature diventa unombra
  vera invece che una macchia grigia. Controindicazione misurata: sposta il riquadro della seconda
  visuale nella composizione, quindi non ancora accettabile come default.
- Il magazzino 256x256 che i programmi dei mostri, dellocchio e della cupola campiona allunita 5
  (fp059, fp056, fp072, fp019 ) arriva allo shader con i canali rosso/verde/blu quasi vuoti
  (`colore min=0 max=41 media=0.96  nelle inquadrature iniziali, poi fino a `max=255 media~19 ) mentre
  il canale alfa e strutturato  (`min=0 max=255 media 56..184 ). I programmi usano entrambi: `H4.xyz
  entra come termine di luce (`MADH H15.xyz, H5, c[22].x, H4 ) e `H4.w  come coefficiente.

### Azzzeramento del magazzino di profondita allegato

Dopo un aliasing riuscito, il nuovo codice azzera laggetto di profondita al valor di lontano
(`glDepthFunc(GL_LEQUAL ), `glClearDepth(1 ), `glDepthMask(TRUE ), `glClear  di un bit di profondita ).
Motivo misurato: la texture allocata dalla demo parte a zero  e la demo azzera a 1  la superficie su
cui disegna in quel momento, non la texture; la mappa campionata dalla lookup `SHADOW2D  risulta cosi
`mean=0.040  con `nz=0.080, quasi tutti texel a zero. Effetto sulla cupola: media del fotogramma
da 0.1330  a 0.0880, quindi le ombre si fanno piu scure; il profilo nero duro  che sul feramento
reale taglia la cupola bianca (foto `luna_shadows_238.png ) pero non compare ancora.

### Strumento nuovo: `tools/nv_shadow2d.c

Riproducitore isolato, senza Wine, che chiede a Mesa di progetto (zink ) esattamente la forma usata
da Luna: `OPTION ARB_fragment_program_shadow  + `TEX result.color.x, program.local[0], texture[0],
SHADOW2D  su una texture di profondita con `GL_TEXTURE_COMPARE_MODE=GL_COMPARE_REF_TO_TEXTURE  e
`GL_TEXTURE_COMPARE_FUNC=GL_LEQUAL, riempita con 0.4  su una meta e 1.0  sullaltra. Risultato:
texel 0.4 con reference 0.3  da 1.000, con 0.9  da 0.000; texel 1.0 con reference 0.3  da 1.000  e
con 0.9  da 1.000. Quindi in questo stack il confronto `SHADOW2D  avviene davvero  ed e binario:
le ombri troppo leggere di Luna non sono un bug del confronto, ma un problema di valori/portata dei
coordinate della mappa.

### Tabella dei knob provati per le ombre di Luna, con esito visivo misurato

Tutti i knob qui sono spenti di default e `run.sh` non e toccato. Le medie sono dei fotogrammi presentati
con clock deterministico (`WINE_QPC_STEP=16666666`), FSHACK spento e geometria originale della demo
(`NV_LUNA_CONFIG=none`); le coppie di fotogrammi sono appaiate per contenuto e non per numero, perche i
knob cambiano il costo dei passaggi e quindi la fase dellanimazione.

| variante | media del fotogramma della cupola | che cosa si vede |
|---|---|---|
| base | 0.1330 | ombre presenti ma leggere |
| `WINE_NV_PBUFFER_DEPTH_STORE=2` con `WINE_NV_PBUFFER_DEPTH_STORE_SIZES=2048x2048` | 0.1296 | composizione intatta, parete a LED giusta, nessuna ombra netta in piu |
| stessa modalita 2 dopo laggiunta dellazzeramento del magazzino allegato | 0.0880 | la scena si scurisce in modo evidente, le pozze sotto le creature si rafforzano, ma il profilo nero duro della foto reale non compare |
| `MESA_NV_LEGACY_SHADOW_SWAP=0` | 0.1521 | viene piu chiara della base: il cambio funzione/modo che il nostro innesto fa e quello giusto |
| `MESA_NV_FORCE_TFILTER_SET=0x2600:0x2600` con `MESA_NV_FORCE_TFILTER_DIM=2048x2048` | 0.0929 | a fotogrammi appaiati la differenza visiva e minima |
| vicino secco sulla mappa + modalita 2 filtrata a 2048x2048 | 0.0850 | come la riga sopra, senza ombre nette nuove |
| `WINE_NV_RT_COLOR_ALIAS=4` con `WINE_NV_RT_COLOR_ALIAS_SIZES=256x256` | 0.0981 (base in quella serie 0.1195) | sotto gli arti delle creature compare unombra vera al posto della macchia grigia, pero il riquadro della seconda visuale nella composizione si sposta |
| copia della profondita modalita 2 e 3, aliasing di profondita globale, `WINE_NV_PBUFFER_RT_FBO=1`, `WINE_NV_PBUFFER_PROMOTE_FLOAT=1`, `WINE_NV_PBUFFER_SPLIT_FMT=1` | - | provati in precedenza: peggiorano o rompono la composizione |

Chiusura della pista "la mappa dombra e vuota": era un artefatto del nostro stesso ispettore (blit
profondita-colore che non copia nulla e non segnala errori). Letta in modo valido, la mappa campionata dalla
lookup `SHADOW2D` ha `min=0.106 max=1 mean=0.943 nz=1.000`, quindi e popolata. Il confronto `SHADOW2D` nel
nostro stack e binario e prende il reference dalla terza componente della coordinata, provato col tool
isolato `tools/nv_shadow2d.c` su quattro combinazioni di allocazione (16 bit piena, 16 bit vuota poi
riempita con `glTexSubImage2D`, 24 bit piena, 24 bit vuota poi riempita): in tutti i casi texel 0.4 con
reference 0.5 rende 0.000 e texel 1.0 rende 1.000, e il Mesa di sistema da gli stessi numeri. Le coordinate
proiettate della lookup non sono sballate: sostituire la lookup con una lettura banale della mappa, con la
coordinata u o con la coordinata di profondita cambia lintensita dei fotogrammi in modo diverso fra loro
(0.1437, 0.1361 e 0.1027 contro 0.1330 della base).

Stato accettato per Luna, invariato: `WINE_NV_RT_COLOR_ALIAS=2` (le venature), `MESA_NV_TEX3D_DEPTH_MAJOR=all`
(la distorsione), i quattro knob della catena dei formati a virgola mobile. Nessuno dei knob sopra entra nel
default perche nessuno ha dato un miglioramento visivo accettabile senza effetti collaterali misurati.

### Filtro per nome e filtro per taglia sulla correzione del formato separato

Due knob nuovi, spenti di default, nati per provare a consegnare le rese a colori dei magazzini
256x256 con la stessa zero-copy che il driver del 2004 usava, senza toccare gli altri magazzini.

- `WINE_NV_RT_COLOR_ALIAS_TEX=<nome[,nome...]|all>`: dentro le taglie gia accettate da
  `WINE_NV_RT_COLOR_ALIAS_SIZES`, allega solo le texture della demo con uno di questi nomi. Misura:
  su Luna i magazzini 256x256 che la modalita 4 allega sono cinque, con i nomi 11, 26, 27, 28, 29;
  chiedendo di allegare solo il nome 56 non si ottiene nessun allegato (0 tentativi). Il nome di una
  texture GL non e stabile fra esecuzioni diverse, perche la demo ne crea in numero diverso a seconda
  dei knob di diagnosi accesi (lo stesso magazzino, nel censimento dei legamenti fatto con le sonde
  Mesa accese, porta il numero 56). Il filtro per nome serve quindi come sonda una volta, dopo aver
  letto i nomi reali con `WINE_NV_TRACE_WGL=1`, e non come impostazione da lasciare acceso.
- `WINE_NV_PBUFFER_SPLIT_FMT_SIZES=<LargexAlta[,LargexAlta]|all>`: limita a certe taglie la
  correzione per cui la richiesta di texture di profondita (WGL_DEPTH_TEXTURE_FORMAT_NV) non
  cancella piu la richiesta a colori (WGL_TEXTURE_RGBA_ARB) sullo stesso pbuffer. Default: tutte le
  taglie, quindi `WINE_NV_PBUFFER_SPLIT_FMT` si comporta come prima. Misura con filtro a 256x256:
  la media dei fotogrammi presentati sale (0.1271 contro 0.1839 allo stesso indice, +44 per cento),
  quindi la correzione parziale schiarisce la scena invece di scurirla, e non e accettabile.

### Censimento degli allegati a colori, e che cosa fa davvero la modalita 4

La sonda `COLOUR-ATTACH` viene stampata solo con `WINE_NV_TRACE_WGL=1` (prima di questa misura il
dettaglio non era scritto da nessuna parte e le esecuzioni senza trace non dicevano nulla). Con la
trace accesa, 46 secondi di Luna:

| configurazione | tentativi di allegato | allegati riusciti | chi |
|---|---|---|---|
| `WINE_NV_RT_COLOR_ALIAS=2` (default accettato per Luna) | 400 | 25 | la texture 5, magazzino 512x512 |
| `WINE_NV_RT_COLOR_ALIAS=4` con `WINE_NV_RT_COLOR_ALIAS_SIZES=256x256` | 400 | 213 | le texture 11, 26, 27, 28, 29, tutte 256x256 |

Giudizio visivo sulla seconda riga, con quattro coppie di fotogrammi appaiate globalmente per
contenuto (distanze 6.3, 7.8, 18.6, 19.3 su una scala di 255): i due fotogrammi del volto restano
identici, mentre nei due fotogrammi con la ragazza sopra la parete a LED la parete scompare
(`coppie-migliori-mode4su256.png`): il magazzino 256x256 che porta il termine di ombra e luce porta
anche la parete a LED, quindi allegarlo in zero-copy fa comparire ombre vere sotto gli arti delle
creature ma toglie la parete. Con i nomi che cambiano da esecuzione a esecuzione, stanotte non e
possibile allegare solo il magazzino giusto.

Prossimo passo segnato per una seduta successiva, non eseguito stanotte: identificare il magazzino
dalloshader che lo scrive invece che dal nome (il passaggio che scrive lombra usa un solo programma,
riconosciuto dalla lunghezza 851 byte e dallistruzione SHADOW2D, e disegna dentro un framebuffer
legato a un pbuffer con una taglia e un HDC precisi), poi allegare in zero-copy solo quello.

### Modalita 5 dellalias a colori, e perche non scatta

Aggiunta la modalita `WINE_NV_RT_COLOR_ALIAS=5`: allega in zero-copy non in base alla taglia ma al
marcatore che Mesa mette sul magazzino scritto da un programma con lookup SHADOW (`MESA_NV_SHADOW_MARK`,
paginia Mesa). Wine chiede il marcatore con il pname privato 0x8FFF0004 tramite `glGetTexParameteriv`
sulla texture della demo, che in quel momento e proprio la texture legata al target (la funzione di bind
aveva fatto `glBindTexture` poche righe prima), e se il marcatore non c'e passa normalmente alla copia.

Misura su Luna, con `WINE_NV_TRACE_WGL=1 MESA_NV_SHADOW_MARK=1 WINE_NV_RT_COLOR_ALIAS=5`, clock
deterministico, FSHACK spento, geometria originale: 0 tentativi di allegato, contro i 400 tentativi (25
riusciti) della modalita 2 e i 400 tentativi (213 riusciti) della modalita 4 con taglie 256x256. Il
marcatore lato Mesa non viene mai messo (zero righe `MESA-NV SHADOW-MARK`), quindi la modalita 5 non
entra mai nel ramo di allegato. Non e quindi un canale utilizzabile cosi com'e: il marcatore va spostato
dalloggetto texture al framebuffer o al drawable del pbuffer. Nota di igiene emersa dalla misura: la
domanda del marcatore chiama `glGetError` e therefore consuma un errore GL che altrimenti
arriverebbe alla demo; finche il canale non funziona la modalita 5 va lasciata spenta.

Stato accettato di Luna, ancora una volta verificato dopo tutte le ricostruzioni della notte: con la
configurazione di default del ramo Luna (modalita 2, `MESA_NV_TEX3D_DEPTH_MAJOR=all`, la catena dei
formati a virgola mobile) il velo della tuta mostra le venature marmorizzate e la scena e integra, zero
errori gravi.

## Verdetto del mattino dell'8 novembre sulle due varianti di consegna, con la correzione della modalita 4

L'utente ha guardato le due varianti dal vivo, con la geometria originale della demo
(`NV_LUNA_CONFIG=none`, `args.txt` ripristinato all'originale installato: 2698 byte, impronta
`129d82a06552d1cc`, riga attiva `1024   0  0    0    1.0 true`) e presentazione con FSHACK attivo.
Prima delle prove il file era stato riscritto da `tools/nv_luna_config.sh` (2639 byte, senza CR):
ripristinato a mano, perche il confronto va fatto alla stessa inquadratura.

Eseguita prima la configurazione accettata da sola, come controllo: identica a ieri sera, nessun
peggioramento. Censimento: 400 tentativi di allegato, 25 riusciti, tutti la texture 5 magazzino
512x512.

Poi le due varianti:

- **A) `WINE_NV_PBUFFER_DEPTH_STORE=2 WINE_NV_PBUFFER_DEPTH_STORE_SIZES=2048x2048`**: peggio della
  base. Ombre non migliori e subsurface scattering quasi sparito.
- **B) `WINE_NV_RT_COLOR_ALIAS=4 WINE_NV_RT_COLOR_ALIAS_SIZES=256x256`**: peggio della base, prima e
  dopo la correzione della modalita 4. Ombre praticamente assenti, spostando la telecamera si vede
  solo un quadratino grigio sullocchio, subsurface scattering quasi totalmente assente. La parete a
  LED invece e corretta in entrambe le run.

La misura che spiega perche la B rompe cio che la modalita 2 aveva aggiustato. Nella configurazione
accettata gli allegati a colori riusciti sono 25 e riguardano UNA SOLA texture, la 5 (magazzino
512x512). Nella B corretta gli allegati riusciti sono 242: 144 sui magazzini 256x256 (texture 11, 26,
27, 28, 29) e 98 sui 512x512, ma su TRE texture diverse (4, 5 e 13). Allargando la consegna si
allegano anche magazzini che nella configurazione accettata sono consegnati per copia, e la catena del
subsurface scattering legge cosi un magazzino vivo a meta del passaggio invece del quadro consegnato:
le venature quasi spariscono. Misura analoga sulla A: allegare la mappa di profondita 2048x2048 in
zero-copy cambia la catena e il subsurface scattering quasi sparisce.

Ritirata anche unaffermazione della notte: "con la modalita 4 la parete a LED scompare". Guardando le
due run dal vivo la parete e rimasta corretta in entrambe; quella conclusione veniva da fotogrammi
catturati e appaiati per contenuto con configurazioni diverse, cioe da un confronto non alla pari. Vale
la regola gia registrata: il giudizio visivo dellutente prevale sulle metriche interne.

Correzione resta nel codice, per onesta di semantica: la modalita 4 ora entra nel tentativo di allegato
per tutti i magazzini come la 2, e il filtro per taglia e per nome governa solo la creazione del
magazzino su domanda (prima il filtro bloccava proprio lingresso, e con taglie 256x256 si perdeva del
tutto lallegato 512x512 che tiene vive le venature). Il gate sulla separazione features/diagnostica e
sulle impronte e verde; la configurazione accettata di Luna e invariata e nessuno di questi knob e
acceso di default.

Conclusione operativa: per Luna la consegna in zero-copy non va allargata. Il numero corretto di
magazzini allegati e uno solo (tex 5, 512x512), e qualunque ampliamento misurato (taglie 256x256,
mappa di profondita 2048x2048) peggiora il subsurface scattering senza migliorare le ombre. Le ombre
troppo leggere restano aperte come difetto visivo, e la strada da provare non e la consegna: e
capire perche il passaggio che scrive il magazzino dombra produce un contenuto quasi piatto (indizio
nuovo: il quadratino grigio sullocchio, cioe un magazzino 256x256 campionato con la scala sbagliata).

## Le stampe che restavano nella serie di sola feature: silenti in release (8 novembre)

Una build di release non deve scrivere niente di nostro nel terminale. Misurato con la smoke di
release (11 demo per 32 secondi, `NV_BUILD` puntato a `build-release`): Timbury 17 righe, Nalu 24,
GasStation 3, e il totale sulle undici demo era 16108 righe quando la smoke guardava l'albero
sbagliato, 24 quando guardava quello giusto. Le righe che restavano venivano da sei punti che
stavano dentro la serie `0001`, cioe` venivano compilati anche senza la serie di diagnosi:

    nv_fshack_init                win32u/sysparams.c     annunciava il desktop finto (12 volte per run)
    nv_fshack_win_present_scaled  win32u/window.c        blocco di annuncio, rimosso del tutto
    x11drv_client_surface_update  winex11.drv/init.c     due rami: monitor_rect reale e presentazione 1:1
    nv_fshack_mouse_map_screen    winex11.drv/mouse.c    due rami: mappatura e salto

I contatori che limitavano quelle stampe (`nv_fshack_c_cnt`, `nv_sk`, `nv_fshack_mouse_cnt`) sono
rimasti al loro posto: vengono letti e scritti anche senza la stampa, quindi la serie di sola feature
continua a compilare senza variabili inutilizzate. Il blocco di `window.c` invece portava via la
dichiarazione di `once`, che esisteva solo per la stampa.

### Ripresa del 9 novembre: i due avvisi di configurazione dentro `nv_fshack_init`

Restavano due `FIXME` nella serie di sola feature, e non si vedevano perche' ogni demo del
launcher riceve `WINE_NV_FSHACK_MODE`: se l'interruttore master e' attivo e il Modo no, Wine
avvisa che il hack non fara' niente. Mad Mod Mike ha esposto la cosa, perche' la sua riga
geometrica chiede l'auto-rilevamento con larghezza massima 1280 e la superficie misurata dai
fotogrammi di swap e 1920x1080, quindi per quella demo il Modo non viene impostato e il hack
resta inerte di per se'. La smoke di rilascio lo ha preso sul serio: 6 righe nostre su quella
demo, `ESITO_SMOKE_RILASIO=FALLITO` con 0 cadute e 0 eccezioni. I due avvisi sono ora dentro
regioni `nvdbg`, quindi esistono solo nella serie di diagnosi. Verifica sui file installati,
`lib/wine/x86_64-unix/win32u.so`: la stringa del primo avviso 1 copia in debug e 0 in release,
la stringa del secondo 1 in debug e 0 in release, mentre il codice del hack resta in entrambi
(6 occorrenze del nome dell'interruttore in debug, 4 in release: la differenza sono proprio i
due testi tolti).


## Aggancio della profondità su una cubemap: la taglia sta sulla faccia (9 novembre)

`bind_depth_buffer_to_texture()` chiedeva la taglia del livello 0 del target del pbuffer.
Per un pbuffer creato come cubemap (`texture_target = GL_TEXTURE_CUBE_MAP`, 0x8513) quella
domanda risponde 0x0: le dimensioni di un cubo vivono sulle facce. Con taglia zero tutti i
rami che richiedono una dimensione si ritiravano, e la funzione tornava FALSE.

Misura su Mad Mod Mike (techdemo 39): dei nostri 2515 `wglBindTexImageARB`, 193 restituivano
FALSE, e tutti e 193 sullo stesso pbuffer (0x10005, 96x96, creato con
`WGL_DEPTH_TEXTURE_FORMAT_NV`, legato come `WGL_DEPTH_COMPONENT_NV`) - una volta per
fotogramma. Nella trace di riferimento della stessa demo i FALSE sono 0 su 8366. Quel pbuffer
è una cubemap di profondità 96x96, cioè la mappa d'ombra di una luce dinamica: la demo
registrava `NRPbuffer::Bind: failed to bind depth` e campionava una texture che non avevamo
mai riempito.

Cosa fa adesso: quando il target è un cubo, la taglia e il formato interno si chiedono alla
faccia (`attach_target`), e l'aggancio dell'`ALLEGATO di profondità` (GL_DEPTH_ATTACHMENT)
avviene sulla faccia selezionata. La faccia non va indovinata: la demo la sceglie con
`wglSetPbufferAttribARB(WGL_CUBE_MAP_FACE_ARB, ...)`, e il nostro codice la registra già in
`pbuffer->cube_face`; anche la registrazione per la copia differita riceve la stessa faccia.

Misure dopo la correzione, sulla stessa configurazione della stessa demo:

```text
fallimenti di aggancio della profondità dichiarati dalla demo   664 su 32 secondi -> 0
cadute non gestite ed eccezioni del guest                       0                 -> 0
fotogrammi scambiati confrontati con la corsa precedente        identici (differenza media massima 0,004)
```

I fotogrammi di Mad Mod Mike non cambiano in modo visibile: la cubemap 96x96 è piccola e il
suo contributo in quelle inquadrature resta sotto il rumore di misura (0,002..0,004 sui
fotogrammi finali). La correzione resta perché elimina un percorso di errore che la demo
registrava a ogni fotogramma e perché consegna davvero una mappa d'ombra che prima era vuota.

Due osservazioni separate, da non confondere tra loro.

1. Buco latente, letto nel codice: le caricazioni del percorso colori usano
   `pbuffer->texture_target` senza trattamento per faccia (`p_glTexImage2D` alle righe 6523
   e 6977, `p_glTexSubImage2D` alla 6849). Con un pbuffer legato come cubemap
   (`GL_TEXTURE_CUBE_MAP`) il target base non accetta una TexImage2D: vanno le facce. Non
   l'abbiamo incontrato: in Mad Mod Mike i pbuffer con `texture_target = 0x8513` (96x96,
   80x80) vengono legati solo come profondità, e la diagnosi `MESA_NV_TRACE_GLERROR=1` non
   ha registrato nemmeno un errore GL in tutta la corsa. Vale come avvertimento per una demo
   che leghi un colore a cubo: allora quel percorso va sistemato come abbiamo appena fatto
   per la profondità.

2. Nero della passata composita: resta aperto, e la cubemap non c'entra. Nello scarico delle
   texture campionate una cubemap 256x256 risulta nera (`MESA_NV_DUMP_TEX`, file
   `tex6_face0_256x256.ppm`, luminanza 0,000) mentre le altre cubemap scaricate hanno
   contenuto (0,144..0,576); pero' lo scarico legge solo la faccia 0, e la demo non passa da
   quel percorso con un target cubico (punto 1), quindi non abbiamo provato che quella
   faccia vuota sia la causa del nero. Le cause eliminate per misura sono elencate in
   `docs/mad-mod-mike.md`: consegna dei colori, copia differita, saturazione del taglio,
   camponi di texture vuoti, ordini degli assi dei volumi 3D, errori GL del driver.

### La faccia del cubo render-texture: dov e il magazzino delle ombre di Mad Mod Mike (2026-11-09, pomeriggio)

Dove sta il magazzino, misurato: Mad Mod Mike crea due pbuffer render-texture 96x96 con
`WGL_TEXTURE_TARGET_ARB = WGL_TEXTURE_CUBE_MAP_ARB` (nel nostro tracciato: `texture_target=0x8513`,
hdc 0x101006e e 0x1010071). Il riferimento ne crea due della stessa taglia piu' due 80x80, e
carica le sei facce iniziali con sei `glTexImage2D(GL_TEXTURE_CUBE_MAP_*, GL_RGBA8, 96x96)`:
i file a bordo sono `newCompCube_{x,y,z}{Pos,Neg}.tga`. Il contenuto che noi consegniamo su
quei pbuffer, dumpato (`WINE_NV_RT_DUMP_DIR` + `WINE_NV_RT_DUMP_SIZE=96x96`), mostra una
sagoma nera su fondo bianco molto simile a `newCompCube_yPos.tga`: e' il cubo delle ombre di
una luce puntiforme, quello che la demo riscrive sei volte per quadro, una faccia per direzione.

Cosa era rotto, e la prova. L'applicazione seleziona la faccia con
`wglSetPbufferAttribARB({WGL_CUBE_MAP_FACE_ARB, WGL_TEXTURE_CUBE_MAP_*_ARB, 0})`: nel
riferimento 17532 chiamate, tutte TRUE; nel nostro tracciato apitrace 5533 chiamate, tutte TRUE,
con lo stesso identico tentativo iniziale `{WGL_CUBE_MAP_FACE_ARB, 8323, 0} = FALSE` seguito
dalla forma con l'enum corretto. La selezione arriva da noi per bene: la traccia
`nvlegacy FACE` (sotto `WINE_NV_TRACE_WGL=1`) mostra i valori grezzi 0x207d..0x2082 tradotti
in `cube_face = 0x8515..0x851a`, in rotazione su sei facce consecutive. Perdevamo il frutto
della selezione al momento della consegna: i percorsi colore e profondita' nominaivano
`pbuffer->texture_target`, cioe' l'oggetto cubo, invece della faccia. In Mesa
`_mesa_tex_target_to_face` restituisce 0 per qualsiasi cosa non sia una faccia di cubo, quindi
ogni consegna finiva su +X e le altre cinque facce restavano con il contenuto caricato
all'inizio. La misura sul campo: le consegne dumpate uscivano sempre con la stessa faccia nel
nome (0x851a), mentre i legami di cubo erano 710 in 30 secondi e 284 copie 96x96.

Correzione (nella serie di sola funzionalita'): un unico ausiliario,
`nv_pbuffer_image_target(pbuffer)`, che quando il bersaglio e' `GL_TEXTURE_CUBE_MAP` nomina la
faccia selezionata (default +X), usato in tutti i punti dove si scrive un'immagine di texture,
si aggancia a un framebuffer o si chiede la taglia di un livello; 11 siti. E' la stessa regola
gia' adottata per il legame di profondita' (che senza di essa restituiva FALSE su un cubo).
L'A/B sui medesimi scambi (24, 32, 40, ... 144) con la leva spenta e accesa: nessuna caduta in
entrambi i casi, 16 fotogrammi entrambi, differenza media dei pixel 0,0000 sui primi scambi e
0,0070 0,0107 0,0114 0,0108 0,0077 0,0131 sugli scambi 8..13, concentrata sul personaggio e
sulla scia di pelo: e li' che la luce proiettata e l'ombra del getto agiscono.

Strumentazione aggiunta (serie di sola diagnostica):
- `WINE_NV_CUBE_FACE_TARGET=0` rimette provvisoriamente il vecchio comportamento (nomina
  l'oggetto cubo invece della faccia). Serve per isolare: la prima build con la regola della
  faccia e stata scambiata per colpevole di una tempesta di eccezioni, perche' nella stessa
  corsa era attivo anche `MESA_NV_DUMP_TEX`, che e' la causa vera (vedi `patches/mesa/doc.md`).
- `nvlegacy FACE` sotto `WINE_NV_TRACE_WGL=1`: stampa il valore grezzo ricevuto, quello tradotto
  e quello precedente, con un limite di 24 righe.
- `WINE_NV_RT_DUMP_DIR`: la chiave e il nome del file contengono ora la faccia
  (`96x96_f0x8515`), perche' senza di essa le sei consegne di un cubo condividevano un solo
  contatore e un solo nome di file, e l'evidenza che le facce sono distinte non era leggibile.
  Corretto anche un mio difetto: il filtro `WINE_NV_RT_DUMP_SIZE` confrontava la stringa
  completa con la chiave, quindi ha smesso di corrispondere appena la chiave ha preso il suffisso della
  faccia (misura: 0 dump dopo, 4 prima a parita' di corsa). Ora il filtro accetta un elenco
  separato da virgole e confronta come prefisso.

Retrazione, per correttezza: in una fase precedente di oggi ho scritto che la demo "non ruota
le facce nel nostro Wine" (2 chiamate di `wglSetPbufferAttribARB` osservate contro 17533 del
riferimento). Era un artefatto del censimento: quel conteggio veniva dai soli tracciamenti
interni di Wine, che nominano solo alcune chiamate. A livello di API, sulla nostra traccia
apitrace, i numeri sono 5533 selezioni di faccia e 2515 legami con 2514 rilasci, contro 17532
e 8366/8365 del riferimento. La rotazione c'era anche prima della correzione; mancava solo che
qualcuno la rispettasse al momento di scrivere i pixel.

### Consegna delle render-texture anche alla release: `WINE_NV_RT_DELIVER_AT`

`WINE_NV_RT_DELIVER_AT=both` fa la copia del contenuto del pbuffer nella texture allegata
sia alla `wglBindTexImageARB` sia alla `wglReleaseTexImageARB`; senza il knob resta il
comportamento storico, cioe' la sola copia al bind.

Motivo misurato su Mad Mod Mike il 2026-11-09. Nella traccia di riferimento la sequenza per
ogni passata di render-texture e`: bind del buffer del pbuffer sulla texture, disegni fatti
dal contesto del pbuffer, release. La demo usa circa venti pbuffers (256x256, 2048x2048,
3072x2048, e due cubi da 96 e da 80 la cui faccia viene scelta con `WGL_CUBE_MAP_FACE_ARB`
prima di ogni passata) e ne ruota parecchi nello stesso fotogramma. Il driver dell'epoca non
copiava nulla: il bind aliasava il magazzino del pbuffer nell'immagine della texture, quindi
i disegni finivano direttamente nell'oggetto campionato. Noi non possiamo aliasare, quindi
copiamo; pero' la copia al bind avviene prima che la passata abbia disegnato, e se la demo
azzera il pbuffer all'inizio della passata la texture resta vuota. Misurato: le depth
render-texture da 3072x2048 (oggetto tex=4) e da 2048x2048 (tex=1) risultano
`min=0 max=0 average=0` nella quasi totalita dei campionamenti, e i readback che passano
(al frame 5029 della campagna da 70 secondi) danno invece `min=0.62494 max=1.0 media=0.9828
sopra-0.999=87.0%`, quindi la mappa piena esiste ma arriva tardi alla texture. Copiare anche
alla release prende il contenuto della passata appena conclusa; per i cubi la copia usa la
faccia selezionata in quel momento, che e' quello che serve alla consegna per faccia.

Diagnostica collegata, gia` esistente: `WINE_NV_TRACE_WGL=1` (righe `BIND`, `FACE`,
`BIND-TFP`) e `WINE_NV_RT_DUMP_DIR=<dir>` piu' `WINE_NV_RT_DUMP_SIZE`, `WINE_NV_RT_DUMP_MAX`,
WINE_NV_RT_DUMP_EVERY per scaricare il contenuto consegnato.

## Catena di consegna delle render-texture di Mad Mod Mike: cinque knob misurati (notte 9-10 novembre)

La notte e stata spesa per cercare di correggere le ombre dinamiche di Mad Mod Mike, che lutente
vedeva "proiettate correttamente ma con la texture glitchata". Sono stati introdotti cinque knob;
nessuno di loro e acceso di default, e qui sotto c'e la misura che li ha giudicati.

- `WINE_NV_PBUFFER_DEPTH_COPY_MAXPX=<n|all>` (default: quattro milioni di pixel) - alza il tetto
  della copia di profondita. Era un limite reale: la mappa dura di Mad Mod Mike e un pbuffer di
  profondita 3072x2048, quindi 6291456 pixel, e con il tetto fisso la copia veniva rifiutata in
  silenzio. Misura: con `all` la copia parte, legge il framebuffer di sistema del contesto che ha
  disegnato e produce una mappa vera (min 0.438816, media 0.906472, `above_one` 5242880 su
  6291456, nessun texel a zero).
- `WINE_NV_PBUFFER_DEPTH_COPY_ALSO_COLOR=1` - permette la copia di profondita anche ai pbuffers
  che l'applicazione lega anche a colori (i cubi da 96 e da 80 di Mad Mod Mike). Misurato: la
  copia parte ma fallisce (`DEPTH-COPY: texture=8 96x96 ... result=0`), e le texture che i suoi
  programmi campionano con quei nomi sono oggetti a colori (`fmt=#x54`), non di profondita. Non
  utile: resta per prove, non attivo.
- `WINE_NV_RT_KEEP_BIND=1` - ricorda l'associazione (pbuffer, buffer) -> texture dal legame in cui
  l'applicazione aveva legato un oggetto, e la riapplica quando il legame arriva con lo slot vuoto.
  L'idea veniva dal tracciato di riferimento, dove i riligami del cubo da 96 restano TRUE con tutte
  le unita texture a zero. Misurato su Mad Mod Mike: il ramo non scatta mai, perche al momento del
  legame la demo ha gia una sua texture legata (nome 8 per il cubo di profondita). Non attivo.
- `WINE_NV_PBUFFER_RT_DEPTH_RESPEC=<16|24|32|32f>` - ri-specifica il magazzino della texture di
  profondita dell'applicazione con un formato di sola profondita. Serve perche la nostra Mesa, a
  fronte di una texture voluta `GL_DEPTH_COMPONENT16`, alloca un magazzino gallium con profondita
  piu stencil (`MESA-DEPTH-RAWDST: format 272, block 4`, i 24 bit della profondita nei tre byte
  bassi). Con il knob il magazzino diventa `format 271` e i byte scritti sono float corretti. La
  ri-specifica e una-tanto-per-tutte (`nv_respec_fatto`), e il costo misurato e zero: 55,17 fotogrammi
  al secondo contro 54,88 della base. Non attivo: non cambia lintroduzione (vedi sotto).
- `WINE_NV_PBUFFER_COLOR_READ_DRAWER=1` - legge la render-texture a colori nel framebuffer di
  sistema dell'ultimo contesto che ha reso quel pbuffer corrente, invece del contesto che fa il
  legame; e la stessa regola che nel ramo della profondita porta contenuto buono. Misurato: il ramo
  non scatta mai (`COLOR-DRAWER: 0 occorrenze`), perche il contesto che esegue il legame e proprio
  quello che ha reso il pbuffer corrente. Quindi i pannelli a colori neri non sono un problema di
  contesto. Non attivo.

## Che cosa hanno escluso le misure, e dove sta il problema aperto

Due fatti misurati due volte, con oracoli che non dipendono dagli strumenti di lettura:

1. Le due mappe di profondita grandi (2048x2048 e 3072x2048, campionate da 27525 e 44850 disegni)
   non sono viste da chi campiona: iniettare in esse un pattern conosciuto (meta al valore lontano,
   meta a 0,6) o una rampa lungo y non muove i fotogrammi presentati neppure alla quarta cifra
   (0,3255 contro 0,3254 di luminanza totale; differenze per blocco 20x14 pari a zero). Vale sia
   con il magazzino profondita+stencil sia con quello ri-specificato di sola profondita.
2. Le render-texture a colori arrivano invece al campionatore: capovolgere la consegna dei colori
   muove blocchi dello stesso fotogramma fino a 41 su 255 (`WINE_NV_PBUFFER_FLIP=1` contro base,
   media per blocco 4,87).

Le letture che passano per OpenGL su queste texture non sono pero' affidabili: `glGetTexImage`
(e quindi la sonda Mesa `MESA_NV_TEXWATCH`) restituisce zero anche quando la sonda sul magazzino
del pilota legge i byte giusti scritti dalla copia. Quindi la conclusione "magazzino vuoto" non
regge, e serviva un oracolo lato campionatore; lo si e costruito (`tools/nv_mike_oracolo.sh`).

Lo stato aperto, scritto chiaro: le texture a colori che portano ombra e luce vengono consegnate
vuote o non aggiornate. Misurato con `tools/nv_rt_contenuto.sh`: i due pannelli da 428x268
consegnano nero puro (byte campionati tutti zero, luminanza 0,0000) mentre il pannello da 912x576
in una corsa consegna la stanza reale (0,3290) e in un'altra nero (0,0000); i cubi da 96 e da 80
cambiano contenuto fra corse dello stesso eseguibile. La forma del difetto e quella del modello dell'epoca: il driver dell'epoca legava il magazzino del pbuffer alloggetto texture, quindi un legame
fatto prima dei disegni mostrava comunque i disegni; una copia scattata al legame congela la
superficie com'era in quell'istante. La correzione richiede una consegna che segua i disegni (per
esempio rileggere il pbuffer al primo disegno che usa la texture, oppure consegnare al rilascio),
non un altro formato di magazzino.

Utensili lasciati per questo lavoro: `tools/nv_mike_oracolo.sh` (base contro copia reale, rampa e
iniezione, con la tabella delle differenze per blocco) e `tools/nv_rt_contenuto.sh` (scarica il
contenuto consegnato e lo misura). Sonde Mesa nuove, tutte dentro la serie di sola diagnosi e
gate da `MESA_NV_TRACE_DEPTHUPLOAD`: `MESA-DEPTH-UPLOAD` (chi scrive, su quale oggetto, con quali
parametri), `MESA-DEPTH-UPLOAD-CPU` (i byte ricevuti dal pilota), `MESA-DEPTH-RAWSRC` e
`MESA-DEPTH-RAWDST` (i byte nella risorsa temporanea e nella risorsa della texture dopo il blit),
`MESA-DEPTH-DST` (gli stessi byte dopo il percorso lento), e `obj=` aggiunto alla censura dei
campionatori `MESA-NV TEXBIND`, che e cio che ha permesso di dimostrare che loggetto scritto e lo
stesso letto dai programmi.
