# Mesa nv-legacy patch series

`patches/mesa/` holds two patches, applied by `build.sh` in name order:

| file | content | must compile alone |
|------|---------|--------------------|
| `0001-nv-legacy-features.patch` | the behaviour the 2000-2005 NVIDIA demos need | **yes** |
| `0002-nv-legacy-diagnostics.patch` | traces, dumps, captures, A-B switches | no, optional |

Both are generated mechanically from the annotated development tree by
`tools/make_nv_patches.py`; never edit them by hand. The rules that keep the two
halves separable are in `docs/patch-split.md`.

---

## 1. Why these patches exist

The NVIDIA tech demos of the GeForce3 / GeForceFX / GeForce6 era
(`GasStation`, `Dusk`, `Dawn`/`Fairy`, `Blobby Dancer`, `Truck`/Time Machine, `Toys`,
`Clear Sailing`, `Timbury`/`BugLooker`, `Nalu`/mermaid, `Luna` and `Mad Mod Mike`)
do not program GL the way
modern applications do. They:

* submit assembly programs through `GL_NV_vertex_program` / `GL_NV_fragment_program`
 instead of GLSL;
* configure fixed-function register **combiners** (`GL_NV_register_combiners`) to do
 their lighting;
* bind a pbuffer's colour or depth buffer **directly** as a texture
 (`WGL_NV_render_texture`, `WGL_NV_render_depth_texture` - see the Wine series);
* name their textures and formats with pre-2004 extension spellings
 (`EXT_texture_signed_rgba8`, `GL_TEXTURE_UNSIGNED_REMAP_MODE_NV`);
* rely on hardware behaviour that modern drivers implement differently, or not at all:
 `v[]` registers kept per context, attribute numbers with no enabled array, immediate
 vertex attributes set inside display lists, `glVertexAttribPointerNV` offsets resolved
 at draw time, saturating fixed-point clip positions, an accumulator built by copying
 the framebuffer into a texture mid-frame.

Modern Mesa dropped most of that surface. Patch `0001` puts it back, and makes the
semantics match what those demos measured on real NV hardware of the time. Patch `0002`
adds the instrumentation that made those measurements possible; it is deliberately
separable so that a build without it can be proven to behave identically.

---

## 2. `0001-nv-legacy-features.patch`

### 2.1 New files

| file | role |
|------|------|
| `src/mesa/main/nv_extensions.c/.h` | the NV front end: entry points, per-context NV state (v[] mirror, combiner cache, fences, pixel data ranges), context/framebuffer hooks |
| `src/mesa/main/nv_program.c/.h` | NV program objects, parameter scopes, program text rewriting, the `MESA_NV_REPLACE`/`*_PATCH` machinery |
| `src/mesa/main/nv_combiners.c/.h` | `GL_NV_register_combiners` translated into a generated fragment program |
| `src/mesa/program/nv_to_arb.c/.h` | translator from `!!VP1.0/!!VP2.0/!!VP3.0` and `!!FP1.0` assembly into ARB assembly |
| `src/glx/nv_array_range.c/.h` | `glXAllocateMemoryNV` / `glXFreeMemoryNV` plus `wgl`-prefixed aliases |
| `src/mesa/glapi/glapi/gen/NV*.xml` | API declarations so the entry points reach the dispatch tables |

### 2.2 Extensions advertised, and what is actually implemented

| extension | status | notes |
|-----------|--------|-------|
| `NV_vertex_program`, `NV_vertex_program1_1`, `NV_vertex_program2`, `NV_vertex_program2_option`, `NV_vertex_program3` | **implemented** | programs are validated and translated to ARB assembly; `glExecuteProgramNV`, `glBindProgramNV`, `glProgramStringNV`, `glTrackMatrixNV`, `glVertexAttrib*NV`, `glCombinerInputParameterListNV` and friends are live |
| `NV_fragment_program`, `NV_fragment_program_option`, `NV_fragment_program2` | **implemented** | same translator, `glProgramStringARB`-style binding, named parameters |
| `NV_register_combiners`, `NV_register_combiners2` | **implemented** | `src/mesa/main/nv_combiners.c` builds a fragment program from the combiner graph; per-stage constants through `glCombinerStageParameterfvNV` |
| `NV_occlusion_query` | **implemented** | `glBeginOcclusionQueryNV` / `glEndOcclusionQueryNV` on top of the driver query objects |
| `NV_fence` | **implemented** | backed by Mesa sync objects (`glGenFencesNV`, `glSetFenceNV`, `glTestFenceNV`, `glFinishFenceNV`, `glIsFenceNV`, `glValidateFenceNV`, `glDeleteFencesNV`) |
| `NV_pixel_data_range` | **accepted and recorded** | `glPixelDataRangeNV` / `glFlushPixelDataRangeNV` validate and store the ranges; they exist so the demos' setup path does not error out |
| `NV_point_sprite` | **advertised** | the point-sprite state the demos query is served from the core ARB feature |
| `NV_vertex_array_range` | **implemented client-side** | `src/glx/nv_array_range.c`: allocation is ordinary client memory; `glFlushVertexArrayRangeNV` is a no-op, which is what the demos need |
| `EXT_texture_signed_rgba8` | **alias** | folded onto `EXT_texture_snorm`, which is what the demos then use for normal maps |
| `NV_texture_shader`, `NV_texture_shader2`, `NV_texture_shader3` | **advertised only** | not implemented. They are advertised so `cgGL 1.1` passes its `fp20` profile check; the `glTexEnv(GL_TEXTURE_SHADER_NV)` calls are then accepted instead of raising errors. Enabled by `MESA_NV_ADVERTISE_TEXSHADER` (`run.sh` always sets it) |

### 2.3 Behaviour restored, with the measurement that justifies it

Each of these was found by replaying an NVIDIA apitrace on the reference hardware and
comparing with our output. The long archaeology lives in `docs/`; the invariant is here.

**Program path**

* **Per-context `v[]` register mirror, restored on the draws that need it**
 (`nv_extensions.c: _mesa_nv_note_nvreg/_mesa_nv_apply_nvregs`). In Nalu 16 GL contexts
 coexist (the luminance chain's pbuffers); a shared mirror let one context's writes leak
 into another and the composite received `g_scale=(0,1)` instead of `(1,1)`: the god
 rays were wrong. Restoring the registers per context fixed it. Never writes through
 enabled client arrays (that corrupted the chain's output). Default **on**.
* **Float immediates re-emitted with shortest round-trip text** (`nv_to_arb.c:
 nv_fmt_float`/`nv_fmt_vec4`, all five places that print constants). The translator used
 to print `%.7g`, so the demo's exact `{0.99609375}` (= 255/256) came back as
 `-0.9960938`, which in float32 is 255/256 **plus one ulp**. On the only line that
 matters, `bite_area = saturate(256*(colormap.w - 255/256))`: with the exact constant
 `bite_area` is 1.0, alpha 0.0, `NOTEQUAL ref=0` discards the fragment and the hole
 appears; with the truncated constant `bite_area` is 0.99998474, alpha 1.5e-05, nothing
 is discarded and the effect disappears. One ulp of *text* was enough to remove a whole
 visual effect (Timbury's "bite").
* **Raster position when an NV vertex program is active** (`st_cb_rasterpos.c`). The
 probe draw must feed `VERT_BIT_GENERIC0`, otherwise the glyph position is computed from
 zeros. Without it `GL_CURRENT_RASTER_POSITION` came out wrong for every `glBitmap` /
 `glDrawPixels` in Timbury.
* **Bitmap glyph cache disabled when NV program extensions are present**
 (`st_cb_bitmap.c: nv_cache_bitmap_usable`). The cache accumulates consecutive
 `glBitmap` calls into one 512x32 quad and later draws it with the application's
 fragment program; the text program ignores the glyph mask, so the whole slider label
 area was painted flat. Automatic by default.
 * **Attribute numbering of the Cg era** (`nv_to_arb.c`). `vp20`/`vp30` programs number
 `v[0]`=position, `v[2]`=normal, `v[3..4]`=colour, `v[8..15]`=texture coordinates, and
 such registers must become *conventional* ARB inputs, not generic ones. This mapping is
 `MESA_NV_ATTR_MAP`, and it is **per executable** because Dusk and Blobby Dancer use
 opposite, incompatible conventions (`docs/nv-vertex-attrs.md`); `run.sh` decides.
* **Sign modifiers on immediate swizzles**: folding a literal's component selector used
 to lose the absolute/negate modifier, which turned `-{1,0,0,1}.x` into `{1,1,1,1}`
 (`2*x-1` became `2*x+1`). Fixed in the translator; that was the real cause of Clear
 Sailing's wrong sea (pixel mean 149.03 -> 118.45 measured against the reference video)
 and of Blobby's flattened character, so the old per-demo gate is gone.
* **Condition codes**: `MULXC`/`CMP` emission avoids a spurious `-0.0` (`MESA_NV_CMP_NEG0`
 restores the old form for A/B).
 * **fp40 instruction-set pieces in the ARB assembly frontend** (`program_lexer.l`,
 `program_parse.y`, `program_parser.h`, `arbprogparse.c`, `prog_instruction.h/.c`,
 `prog_to_nir.c`, `prog_print.c`). The runtime the GeForce FX/6-era demos ship (cgc 1.3)
 emits `!!ARBfp1.0` programs that declare `OPTION NV_fragment_program2` and then use
 mnemonics and operand forms this parser had no path for at all. Added following the
 spelling the extension documents: the option itself; the precision-suffixed mnemonics
 (`MOVR`, `MULH`, `DP3R`, `DDXR` and friends - 22 of them, plus the `X` and `C` variants the
 corpora use, which GL_NV_fragment_program 3.11.4.2 defines as 12-bit fixed point and as a
 condition-code update, not as predication); the opcodes `NRM` (3-component normalize,
 GL_NV_fragment_program2 3.11.5.51, which Mesa never supported on either path), `SEQ`,
 `SGT` and `SLE` (the last two lower to the existing NIR `slt`/`sge` with the operands
 swapped, which is exact: `a > b` is `b < a`); and `|operand|` absolute value, the `AVL`
 production of the ARBfp1.0 grammar, which this parser had never implemented for any
 program and which needed a new `Abs:1` bit in `prog_src_register`, applied before
 `Negate`. All of it is gated on the option, so a program without it behaves exactly as
 before. Two deviations are deliberate and marked in the code: Mesa does not model two
 program precisions, so `R`, `H` and `X` are computed as float32; and the condition-code
 update asked for by the `C` forms does not happen.
 Mad Mod Mike (techdemo 39, cgc 1.4) needed two more pieces of the same grammar,
 measured on 2026-11-08: the storage-precision declaration qualifiers `SHORT TEMP` /
 `LONG TEMP` (GL_NV_fragment_program2 answers the question about exposing precision by
 saying it is done "only for storage using the SHORT TEMP and LONG TEMP syntax", and
 cgc 1.4 writes 260 such lines in the 47 programs this parser rejected), accepted as the
 plain declaration because Mesa models one program precision; and the four mnemonics the
 earlier demos never used, `FRCR`, `SINR`, `SLTH`, `SGTHC`. Measured on the demo: 47
 programs rejected before, 0 after, and its own "Error loading program" lines from 158
 to 0. One trap is recorded in the lexer header: the fourth argument of the
 `return_opcode` macro is the length of the mnemonic the rule matched, because the macro
 hands `yytext + len` to the `_SAT` tail check; passing the base opcode's length makes
 the rule compile, appear in the generated scanner, and still yield IDENTIFIER.
 The same file now carries the closure of the fp40 suffixes rather than more one-off
 names: a rule per base opcode with an optional `[RHX]` and an optional `C`, through the
 macro `return_nvfp40_opcode`, because the whole corpus of Mad Mod Mike (every shader of
 the demo compiled by the demo's own Cg runtime on both candidate profiles, 1222 program
 texts dumped at the driver boundary) still showed names no rule covered: `MOVC`, `MULC`,
 `SLTC`, `SGTC`, `SLTRC`. The specific rules stay in front of the generic ones, since at
 equal match length flex takes the earlier rule, so nothing previously accepted changes.
 Measured over that corpus: programs rejected by the ARB parser went from 34 to 30, and the
 fragment side to zero. The 30 that remain are `arbvp1` texts stopping on `vertex.weight`,
 which is a real ARB_vertex_program state variable (spec lines 2753-2754, downloaded from
 the Khronos registry) that Mesa does not know. Not implemented on purpose: Mesa has no
 vertex weights, and choosing which generic attribute that name should bind is a guess,
 which would paint wrong data silently where today there is a visible parse error.
 Measured: 0 of the 153 programs the demo really submits contain that name, so the gap
 belongs to the `arbvp1` profile our own sweep asks for, not to the demo. See
 `docs/mad-mod-mike.md`.
 * **fp40 predication and control flow accepted as syntax only** (`MESA_NV_FP40_STUBS`, off
 by default). The destination condition-code mask (as in `MOVH H4.w(LE), c[1].x`) and the
 `IF`/`ELSE`/`ENDIF` blocks of fp40 are parsed and then discarded: a masked write lands on
 every component, and the instructions of both branches execute. That is not support, and
 it paints the affected objects wrongly on purpose; it exists because it is the cheap way
 to find out whether a missing piece of ISA is what stands between a demo and a running
 one. On Luna it answered that question in a single measurement: with all 41 ARB programs
 and 136 NV programs of the demo compiling, the demo's own `GL_PROGRAM_ERROR_POSITION_NV`
 queries answered -1 in 176 of 177 cases, and the crash was bit-identical to before.
 Without the knob the same constructs are rejected with a message naming the missing
 piece. See `docs/luna-fp40.md`.
* **Bound program wins over the enable** (`MESA_NV_PROG_LATCH`, off by default): Blobby
 Dancer binds its NV programs and then turns the enable off before drawing; on NV
 hardware of that era the bound program stayed effective, so the trail-copy pass was
 painted as a flat dark fill and erased the bokeh trails.

**Negative result kept on purpose** (so it does not have to be rediscovered)

* **Replaying `glVertexAttribPointerNV` requests when `GL_ARRAY_BUFFER` is bound**
 (`_mesa_nv_replay_nv_attrib_ptrs`, `MESA_NV_NVATTRIB_LATE_VBO`). The trace does show the
 attribute pointers left at offsets `0x18`, `0xc`, `0x20` with no buffer object bound,
 which looks exactly like a geometry bug. It is not: the A/B with the validated tool
 changes about 580000 pixels per frame, i.e. it destroys the scene. The path stays in
 the tree, **off by default**, for experiments, and the scope variants of
 `MESA_NV_PARAM_SCOPE` were measured worse for the same reason: they exist so the
 comparison can be repeated without re-deriving the question.

**Combiners**

* `nv_combiners.c` turns the combiner graph into a fragment program. Constants default to
 exact literals: program constants (`MESA_NV_COMB_PARAMS`) made the composite come out
 black, and 8-bit-quantised literals made fade-in flicker.

**Textures, formats, layouts**

* **Signed remap** `GL_TEXTURE_UNSIGNED_REMAP_MODE_NV = GL_EXPAND_NORMAL_NV` maps to
 `RGBA8_SNORM`, which is how the era's bump maps were read; the translator applies the
 same mapping in `prog_to_nir.c`. The rewrite is re-run after texture uploads: clients
 such as Toys set the mode before the image exists and use generated mip levels, so a
 missing lower level must not abort the whole texture.
* **Depth formats**: a depth texture bound as `DEPTH_STENCIL|SAMPLER_VIEW` and requested
 as `DEPTH_COMPONENT16` is stored as 24 bits (`MESA_NV_DEPTH16_AS_24`, on), and depth
 render textures prefer `Z24_UNORM_S8_UINT` (`MESA_NV_DEPTH_Z24S8`, on) because the
 end-of-frame snapshot is a GPU blit: with different formats the copy is skipped.
* **Compressed 3D layout** discovery (`MESA_NV_TEX3D_LAYOUT`, `..._INBLOCK`,
 `..._DEPTH_MAJOR`): NVIDIA's BC/DXT volumes do not use Mesa's block order; the correct
 layout is picked by measuring the mean difference between adjacent blocks along each
 axis (the correct order gives three small numbers, a wrong order at least one huge one).
* **`MESA_NV_TEXALPHA*`** family: experiments on how DXT1/DXT5 alpha blocks are uploaded
 (forced 255, quantisation, per-texel checks) - the A/B tools for Timbury's leaf/flower
 bite, where the real fix turned out to be float formatting in the translator.

**Render targets, swapchains, feedback loops**

* **Float pbuffers**: RGBA8 drawables handed over by Wine with a declared float format are
 backed by RGBA16F FBOs (`MESA_NV_FB_FLOAT=<WxH[,WxH]>`, plus `..._MAX`, `..._MAXW`).
 Without it the luminance chain is clamped to `[0,1]` and the tonemap's automatic
 exposure dies.
* **Two-image swapchain cycle** (`MESA_NV_MAX_BACK=2`): demos that use the back buffer
 contents as an accumulator (copy the framebuffer into a texture at the start of the
 frame) need only two images; with 3-4 the data read come from several frames earlier.
* **Preserved back buffer semantics** (`MESA_NV_PRESERVE_BACK`, `MESA_NV_COPY_SHADOW`,
 `MESA_NV_SKIP_COPY` in diagnostics): on Windows WGL the presented frame survives the
 swap, and the legacy demos rely on it for trails and bokeh. A Vulkan swapchain hands
 over the new back buffer undefined, so the feedback loops die out; the patch copies the
 presented frame back.
* **Render-texture store snapshots** (`dri_drawable.c`, `MESA_NV_RT_*`): the depth/colour
 store of a pbuffer-archived render texture is copied on the GPU when the draws actually
 changed (`MESA_NV_RT_COPY_GATE`, on). `RT_SNAP`, `RT_FLIP`, `RT_COPY_ON_SAMPLE` are off
 because each was measured to be harmful for the answer to a toggle.
* **Position saturation**: the hardware of the time converted `HPOS` to fixed point
 *saturating*, so a polygon wrapping the clip volume was cut to the whole viewport.
 Without saturation the clip tests on infinite values give NaN and the polygon
 disappears - which is exactly how GasStation builds its full-screen HDR passes
 (projection scale at infinity). `MESA_NV_POS_CLAMP` / `MESA_NV_NO_POS_SATURATE`
 (diagnostics) bound the experiment.

**Blending, multisampling**

* **Alpha-to-coverage on zink**: the pipeline value is ignored when
 `VK_EXT_extended_dynamic_state3` is present, so A2C must be re-emitted as dynamic state
 at every draw. Measured with an oracle counting covered/uncovered texels on a 100%
 transparent geometry (mean 149.03 vs the reference video).

**Client-side legacy semantics** (`MESA_NV_LEGACY_*`, mostly on by default)

* `LEGACY_ATTRS`, `LEGACY_TARGET`: texture name spaces and attribute behaviour of the
 pre-3.2 core profile, because those demos bind e.g. 2D object 3 as `GL_TEXTURE_3D`.
* `LEGACY_TEXENABLE=1`: a texture unit is enabled by its target, as the drivers of the
 time did.
* `LEGACY_TEXCOMPLETE=<0|1|2>`: how incomplete textures are treated (mode 2 = the era's
 forgiving behaviour).
* `LEGACY_SHADOW_SWAP=1`: a compare *function* arriving in the compare *mode* field
 (`GL_COMPARE_REF_TO_TEXTURE` in `GL_TEXTURE_COMPARE_FUNC_NV`) is treated as a request to
 enable comparison with that function - which is what the NV driver did.
* `LEGACY_BUFFERS`: legacy buffer bindings for the pbuffer chain Timbury needs (set by
 `run.sh`, together with `WINE_NV_PBUFFER_FLOAT_FALLBACK`).

**ARB assembly programs carrying NV-era program options**

* `OPTION NV_fragment_program2;` is accepted by the ARB fragment-program parser
 (`_mesa_ARBfp_parse_option`). Cg 1.3, the runtime the GeForce FX/6-era demos ship, opens
 every ARB fragment program it generates with that statement. Measured on Luna: in the
 reference apitrace (GeForce 9800 GTX, demo running) 42 of 42 ARB fragment programs carry
 it, and the demo's own 179 queries of `GL_PROGRAM_ERROR_POSITION_NV` answered -1, which
 means no parse error. In our run the same queries answered **30** - an offset inside that
 option's identifier - 41 times, because Mesa rejected the program outright ("invalid ARB
 fragment program option"). `tools/nvarb_check.c` reproduces the rejection without starting
 Wine, which is what made this fixable in minutes rather than in demo runs.
* Upstream's own comment in that function said the option handling was structured that way
 to cause "less churn" when options starting with `NV_` would one day be supported. They
 never were. Nothing becomes permissive here: an unknown option is still an error.
* Accepting the option is necessary but not sufficient for Luna. The same programs also use
 fp40 instructions this parser does not implement - `MOVR`, `MULH`, `ADDH`, `MADH`, `DP3R`,
 `NRMH`, `DDXR`/`DDYR`, control flow (`IF`/`ELSE`, which ARBfp1.0 has no notion of) and
 predicated write forms (`MULX`, `MOVRC`, `SGTRC`). The inventory over the 42 reference
 programs counts more than 30 distinct mnemonics.
* Those mnemonics are now handled in two steps. The first step, done: the 22 names that are
 the same ARB instruction with a precision suffix are accepted as aliases, gated on the
 option (so a program without `OPTION NV_fragment_program2` keeps failing exactly as before,
 and no previously rejected program becomes accepted by accident). `R` is the float32 form,
 `H` the float16 one; Mesa models one program precision only, so both map onto the base
 opcode, which is what `nv_to_arb.c` already does on the `!!FP1.0`/`!!VP1.0` path (its own
 comment: "MULH -> MUL, DP3R -> DP3"), and the 136 NV programs of the same demo exercise
 that path and load. Measured with `tools/nvarb_check.c` on the corpus extracted from the
 two traces, on both builds: Luna's rejected ARB programs go from 41 to 24, i.e. 17 parse.
 `TXP`, `TXD`, `TXB`, `DDX`, `DDY` needed nothing: this lexer already had them.
* Not done, and it is not a parser tweak: the remaining 24 programs need `NRM` (in nearly all
 of them - Mesa has no such opcode anywhere, and `nv_to_arb.c` maps `NRM` to NULL, so this
 was never supported on either path), the predicated write forms, the fp40 compares `SGT`
 and `SLE` (this lexer has only `SLT`/`SGE`; `nv_to_arb.c` side-steps `SLE` by mapping it to
 `SGE`), and ARB control flow. That is an instruction-set feature, with an opcode and a
 `prog_to_nir` lowering for each. See `docs/luna-fp40.md`.
* Luna still crashes at the same instruction after the aliases, which is consistent: the
 program object whose member is null belongs to one of the 24 that still do not parse. The
 ten demos that do run were re-checked in the presentation sweep after this change, because
 they share this parser: 10 su 10 conformi, `SWEEP_PRESENTA=PASSO`.

### 2.4 Behaviour knobs

Everything below is read once and cached. Unless the table says otherwise the default is
**off/unset**. `run.sh` (`tools/nv_gates.sh`) sets some of them per executable, and a
value you export yourself always wins.

Programs and the translator

| knob | default | effect |
|------|---------|--------|
| `MESA_NV_ATTR_MAP=<bits>` | 0 | maps NV `v[]` onto conventional ARB inputs; 1 = all, bit0 position, bit1 normal, ... (run.sh: 1 for Blobby, 0 for Dusk) |
| `MESA_NV_IMM_SWZ=0` | 1 | component-selector folding for NV immediates; set 0 to fall back to the old path |
| `MESA_NV_CMP_NEG0=1` | off | re-emits the negated predicate (produces `-0.0`) |
| `MESA_NV_CMP_SENSE=1` | off | emits the translated `CMP` with a positive condition instead of the default negated one (A/B only) |
| `MESA_NV_PROGRAM_REMAP=0` | on | disables the NV->ARB program remap |
| `MESA_NV_REPLACE=<id:old:new[,...]>` | off | textual substitutions in the ARB program text: both the text our translator produced and the text the application uploaded directly in ARB form |
| `MESA_NV_FP_PATCH`, `MESA_NV_FP_PATCH_SUB` | off | inject / substitute fragment-program text |
| `MESA_NV_PATCH_BITE_FP`, `_TH`, `_FIND` | off | targeted patches of one translated program (the "bite" pass) |
| `MESA_NV_KILL_FP=<ids>`, `MESA_NV_KILL_VP=<ids>` | off | make the given programs a no-op |
| `MESA_NV_SHOW_TEX=<ids>`, `MESA_NV_SHOW_VAR=<ids>` | off | report texture / variable use of the given programs |
| `MESA_NV_PARAM_SCOPE=<ctx\\|program\\|shared>` | ctx | where NV program parameters live |
| `MESA_NV_VP_C_LOCAL=1` | off | read `Cc` in vertex programs from local parameters |
| `MESA_NV_TXP_SHADOW=0` | on | projective/shadow `TXP` translation used by Nalu's soft shadows |
| `MESA_NV_TEX_SHADOW=1` | off | also turns NON-projective `TEX` fetches into shadow fetches: on NV hardware of the era the comparison lived in the texture, so a plain fetch from a depth map with `GL_TEXTURE_COMPARE_REF_TO_TEXTURE` returned 0/1, not the depth. Mad Mod Mike's Cg receivers use plain fetches, so they need it | 
| `MESA_NV_ARB_SHADOW_REF=<z|w|<number>>` | w | which component of the coordinate register is the comparison reference of a non-projective shadow read: `w` is upstream Mesa (the fourth component), `z` is what the NV-era programs carry (the receiver's window-space depth, which the demo builds as `0.5 + 0.5*z - zbias`), a number replaces the reference with that constant. Measured on Mad Mod Mike 2026-11-11: with `TEX_SHADOW=1` and a constant reference, sweeping the number moves the presented frame from lit to shadowed between 0.90 and 0.99 (the wall region of the frame at exchange index 11 goes from 61.38% to 69.21% dark pixels, with 42.7% of its pixels changing), which proves the comparison is live and that the map values sit near 0.95 (the atlas reads 0.9505 mean). With the upstream `w` the reference is the 1.0 filler of the fourth component, so the occlusion depends on geometry only and never on the receiver's depth: that is why `MESA_NV_TEX_SHADOW=1` alone improves the indirect lighting but leaves the wall streaks. |
| `MESA_NV_SHADOW_BIAS=<float>` | 0.002 | bias applied while translating the soft-shadow compare |
| `MESA_NV_SHADOW_CLAMP=0` | on | clamp to [0,1] of the shadow-comparison reference (NV path and ARB non-projective shadow reads) |
| `MESA_NV_TXP_OLD=1` | off | old `TXP` expansion, for A/B |
| `MESA_NV_PROG_LATCH=1`, `MESA_NV_PROG_LATCH_FP`, `MESA_NV_PROG_LATCH_VP` | off (`-1` = inherit) | a bound NV program wins over the enable |
| `MESA_NV_NVREG_RESTORE=0` | **on** | per-context `v[]` mirror restore |
| `MESA_NV_NVREG_EMIT=1`, `MESA_NV_NVREG_SLOT=map` | off | alternative emit / slot resolution |
| `MESA_NV_VP_DEFAULT_OUT=<0\\|1>` | auto (true on zink) | `VertexProgramDefaultOut`, i.e. RESULT initialisation |
| `MESA_NV_KEEP_DRAW_AT=<fp=...>`, `MESA_NV_SKIP_DRAW=<draw ids>` | off | keep or skip individual draws inside one run |
| `MESA_NV_A2C=<off\\|force>` | off | test knob for alpha-to-coverage |
| `MESA_NV_FORCE_BLEND_FP=<fp id>` | off | force blending for a given fragment program |
| `MESA_NV_DEBUG=1` | off | the cheap NV tracing every probe reuses |

Raster, vertex state, bitmaps

| knob | default | effect |
|------|---------|--------|
| `MESA_NV_RASTPOS_GENERIC=0` | **1** | feed `GENERIC0` for the raster-position probe draw |
| `MESA_NV_BITMAP_CACHE=<0\\|1>` | automatic | force/forbid the bitmap glyph cache; automatic means off whenever NV program extensions exist |
| `MESA_NV_NVATTRIB_LATE_VBO=1` | **off** | replays `glVertexAttribPointerNV` requests when `GL_ARRAY_BUFFER` is bound. Off on purpose: the A/B with the validated tool changes ~580000 pixels per frame, i.e. it destroys the scene ("vertex explosion"). The pointer resolution that Timbury's bite needed is a different, narrower path |
| `MESA_NV_NVATTRIB_DRAW_RESOLVE=1` | **off** | repairs the effective vertex-attribute binding of arrays specified through the NV entry points. Off on purpose since 2026-11-13: with the nested branch-diamond predicate corrected, the A/B shows no change on Mad Mod Mike (black area 1.5 1.5 4.1 2.4 percent with the knob on and the same four values with it off), and on GasStation, Dusk, Timbury and Nalu the difference stays inside the run-to-run noise measured with identical settings (gas 3.30 and 3.87 against 3.50 and 3.83 percent for the control pair; dusk 12.57 and 12.11 against 12.43 and 11.70; timbury 0.19 and 0.20; nalu 3.47 against 7.30 and 7.31). The data hole that motivated it was reported by MESA_NV_TRACE_VERTS*, which is not a neutral probe on Mike. Kept for experiments. |
| `MESA_NV_NESTED_ARM_GATE=0` | **on** | how the fall-through predicate of a linearized NV branch diamond is built when the diamond is nested inside another arm: on gives `(NOT test) AND enclosing arm`, off gives the older `NOT(test AND enclosing)`, which lights the inner fall-through arm even when the whole outer arm must be skipped. On is the era behaviour and the product default; off exists only to measure the difference. Mad Mod Mike's nine-quad composite (vertex program 115, `shaders/composite.vp30`) is the case that shows it: with the switch off the corner quads cover 0.00 percent instead of the 25.00 percent the Cg source asks for, and the demo's own materials leave a black rectangle over 11 to 49 percent of the width and 50 to 82 percent of the height. |
| `MESA_NV_RESOLVE_NEAREST=1` | **off** | delivering a multisample store into a single-sample texture reads one sample instead of averaging all of them. Why: Mad Mod Mike keeps per-pixel material codes in the alpha channel (105 nothing to light, 110..150 heat, 155..255 glow) and averages neighbouring codes into intermediate values, so the demo's own thresholds fire where they should not; measured on the delivered 1280x800 store, regions above 109/255 reach 1024000 pixels at frame 3672 against 186923 in the single-sample run. This is the coarse form (nearest on all four channels), kept off by default: it exists to measure whether the averaging is the cause |
| `MESA_NV_FB_ALPHA_ZERO=<w>x<h>[,...]` | **off** | refuses alpha writes on the draws whose destination framebuffer has one of the listed sizes (up to eight), applied where `st_update_blend` builds the per-render-target colour mask, so it covers every draw and not only the ones the application announced with `glColorMask`; clears and copies are untouched. Why: Mad Mod Mike keeps its effect codes in the alpha of the 428x268 bright-copy store, and its heat pass uses that alpha as threshold, as blend weight and as displacement scale; measured 2026-11-14: without the refusal 2238 draws to that store ask for alpha with mask `0xffffffff`, the store peaks at alpha 118 with 50 pixels above 110 on tex17 and 32 on tex18; with the refusal nothing is left above 110 and the peak falls to 102, while the demo's heat gate needs more than 110/256 = 0.4297 and the peak left under the refusal is 101/255 = 0.396, so the gate cannot open. A residue of mean alpha about 15 survives the refusal and is not attributed yet: the pbuffer-to-texture delivery and the clear colour of that store are the candidates.
| `MESA_NV_FB_ALPHA_ZERO_FP=<id[,...]|all>` | **off** | refuses alpha writes on the draws that use one of the listed fragment program ids (up to twenty), independently of the size selector and on the same colour mask; added to find out which pass carries the alpha into a store instead of switching the whole store off (Mad Mod Mike 2026-11-14 evening: the census of draw state shows only fp=114, the high-pass filter, and fp=107, the ping-pong blur, drawing on the 428x268 bloom store, and blocking either one alone drives the alpha of the object the composite samples to zero over 251 reads of the late window - which also switches the heat distortion off entirely, so this is a measurement lever and not a fix) |
| `MESA_NV_NVATTRIB_GENERIC=1` | off | map NV attributes onto ARB generic attributes |
| `MESA_NV_LEGACY_ATTRS=0` | **on** | legacy immediate/NV attribute behaviour |
| `MESA_NV_LEGACY_TARGET=0` | **on** | legacy per-target texture name spaces |
| `MESA_NV_LEGACY_TEXENABLE=0` | **on** | a texture unit is enabled by its target |
| `MESA_NV_LEGACY_TEXCOMPLETE=<0\\|1\\|2>` | 2 | how incomplete textures are treated |
| `MESA_NV_LEGACY_SHADOW_SWAP=0` | **on** | compare function arriving in the compare-mode field |
| `MESA_NV_ARB_TEX_SHADOW=1` | off | mark a plain ARB `TEX 2D` as a shadow fetch when the Cg debug comments declare `sampler2DSHADOW` on that unit (Mad Mod Mike's hard omni receiver) |
| `MESA_NV_LEGACY_BUFFERS=1` | off | legacy buffer bindings (set by run.sh for `BugLooker.exe`) |
| `MESA_NV_ARRAY_ONCE=1` | off | upload each vertex array only once (Vulcan experiment; correctness then relies on the sampling self-check) |

Textures, formats, swapchain, render targets

| knob | default | effect |
|------|---------|--------|
| `MESA_NV_NO_TEX_REMAP=1` | off | disables the signed texture remap |
| `MESA_NV_FORCE_REMAP=<...>` | off | forces the remap even when the application does not ask |
| `MESA_NV_DEPTH16_AS_24=0` | **on** | store 16-bit depth textures as 24-bit |
| `MESA_NV_DEPTH_Z24S8=0` | **on** | prefer `Z24_UNORM_S8_UINT` for depth render textures |
| `MESA_NV_TEX3D_LAYOUT=<auto|vtc|identity|dmaj|split4|split4c|bands|sheets>` | vtc when unset | Default forces the Khronos `GL_NV_texture_compression_vtc` 4x4x4 block order for legacy compressed 3D uploads. `auto` restores the measured heuristic; `identity` disables reordering. `vtc` has the same formula as the older `split4c` candidate. |
| `MESA_NV_TEX3D_INBLOCK`, `MESA_NV_TEX3D_DEPTH_MAJOR` | auto | in-block order / depth-major volumes; the depth-major value takes `0`/`off`/`no` to disable, `auto` (default) to decide by the continuity score, `all` or `1` to always apply the best candidate, or a comma-separated list of texture ids |
| `MESA_NV_HILO_Z=<on|off>` | on | signed HILO textures, the historical normal-map format of the NV era, are stored with three signed components: the third one is reconstructed the way the NV sampler does it, so a program fetching them into a three-component destination gets a real z instead of zero (Luna's hero suit was black for this); `off` restores the two-channel storage for an A/B. Unsigned HILO textures (`GL_HILO_NV`, `GL_HILO8_NV`, `GL_HILO16_NV`) are also expanded at upload into RGBA: their H and L components are stored in R and G. This is not controlled by `MESA_NV_HILO_Z`; without it Mad Mod Mike's cube remap table stays incomplete and the sampler fetches the black fallback. |
| `MESA_NV_MIPMAP_3D=0` | **on** | generate mipmaps for compressed non-2D textures |
| `MESA_NV_TEXALPHA255=1` | off | force DXT alpha to 255 |
| `MESA_NV_TEXALPHA_QUANT`, `_KILL255`, `_PATTERN`, `_BUMP=<n>`, `_BUMP_DIM`, `_COUNT`, `_DIM`, `_WANTED` | off | the family of A/B switches for DXT alpha uploads |
| `MESA_NV_TEXFLIPV=1` | off | flip V while rewriting blocks |
| `MESA_NV_FLIP=<id:name,...>` | off | deterministic block flips inside a single run |
| `MESA_NV_NO_COPYBLIT=1` | off | staging copy instead of the hardware blit |
| `MESA_NV_STRICT_BLIT=1` | off | enforce strict blit validation instead of the relaxed path |
| `MESA_NV_FB_FLOAT=<WxH[,...]>`, `MESA_NV_FB_FLOAT_MAX`, `MESA_NV_FB_FLOAT_MAXW` | off | back float drawables with RGBA16F FBOs |
| `MESA_NV_MAX_BACK=<n>` | 0 = driver default | cap the number of back buffers |
| `MESA_NV_PRESERVE_BACK=1`, `MESA_NV_COPY_SHADOW=1` | off | re-inject the presented frame into the new back buffer |
| `MESA_NV_RT_SNAP=1`, `MESA_NV_RT_FLIP=1`, `MESA_NV_RT_COPY_ON_SAMPLE=1` | off | per-copy experiments (measured harmful, so off) |
| `MESA_NV_RT_COPY_GATE=<0\\|1>` | **on** | copy the render-texture store only if the draws changed |
| `MESA_NV_RT_ALIAS_SHARE=1`, `MESA_NV_RT_ALIAS_TRACE=1` | off | share/trace render-texture aliasing |
| `MESA_NV_SHOT=<dir>`, `MESA_NV_SHOT_EVERY`, `_SKIP`, `_MAX`, `_FEVERY`, `_FSKIP`, `_TEVERY`, `_TSKIP`, `_READBACK`, `_AT`, `_SWAP_FORCE` | off | capture presented frames to disk |
| `MESA_NV_PARAM_AT_DRAW=<id[,id...]|all|*>`, `MESA_NV_PARAM_AT_DRAW_MAX` (default 400), `MESA_NV_PARAM_AT_DRAW_CELLS` (default 8, max 24) | off | at draw time, print the parameter cells that the bound NV programs actually read (`_mesa_nv_env_array`), per context: the c[] of an NV program is not inside the program object, so this is the only census that matches the application stream. Needs `MESA_NV_TRACE_TEXBIND`. |
| `MESA_NV_TRACE_SMOKE3D=<lines>` | off | for every draw that carries a **GL_TEXTURE_3D** object on a texture unit, one line per distinct state seen (fragment program id, texture name, unit, depth mask, depth test, blend enable, src/dst/equation), plus a count summary every 200 such draws. Needs `MESA_NV_TRACE_TEXBIND`, because the census that walks the units is where it lives. Measured on Mad Mod Mike 2026-11-12: four states, one per smoke volume (names 384, 385, 386, 387), all `depthmask=0 depthtest=1 blend=1 src=0x302 dst=0x303 eq=0x8006`, which is the state the 208 smoke draws of the reference trace have too. So the grid on the smoke veil is not a depth-write or blend-function problem. |
| `MESA_NV_TRACE_VAOBIND=<lines>` | off | logs every VAO binding (`glBindVertexArray`) with the enable masks of the object left, the object entered, and the VBO-state VAO (`vbo_context.VAO`), plus a flag telling whether the new binding IS the VBO-state object. Added for the Mad Mod Mike heat composite pass: at its draws the VAO in use is named 0 with mask 0x8000 while the client-array state is named 0xffffffff with mask 0x18003, so the position attribute the program declares reads the generic constant. Measured on Mad Mod Mike: 0 lines over 170 swaps, the demo never binds a VAO. |
| `MESA_NV_ATTRIB_RESOLVE_MAX=<lines>` | 200000 | cap for the two attribute witnesses `MESA-NV ATTRIB-RESOLVE-IN` and `MESA-NV ATTRIB-STATE`. The old hardcoded limit of 200000 lines was reached on Mad Mod Mike and the log alone was about 200 MB. |
| `MESA_NV_TRACE_FB_ALPHA_ZERO=<lines>` (default 3000) | off | one line per refused alpha write, `MESA-NV ALFA-VIETATA fb=<w>x<h> disegni_negati=<progressive>`, and `MESA-NV ALFA-VIETATA-PROGRAMMA fb=<w>x<h> programma=<id> disegni_negati=<progressive>` when the refusal comes from the per-program selector: without it the bright-copy store still showed a full alpha population and only the per-size refusal count revealed where the mask hook acted.
| `MESA_NV_TRACE_TEXCOMPLETE=1` | off | print once per texture object how many mipmap levels are allocated and whether the object is complete for a base filter and for a mipmap filter: a texture with only level 0 sampled through a mipmap filter is incomplete and incomplete textures read as zeros, which is how a detail map silently disappears from a render |
Nota di misura, verificata su Luna il 2026-11-06 e che evita un errore costoso.
`MESA_NV_SHOT=<dir> cattura al livello dello scambio: il fotogramma presentato, con la
interfaccia disegnata dall'applicazione (su Luna si vede la scritta MENU e il contrassegno del
produttore video) e con la risoluzione reale della presentazione. `MESA_NV_SHOT_COPY=<dir>
cattura al livello della copia di texture: passa intermedi, spesso senza interfaccia, e lo stesso
numero di fotogramma pu essere un passaggio diverso da corsa a corsa. Per misurare un difetto
visibile all'utente serve quindi `MESA_NV_SHOT; `MESA_NV_SHOT_COPY serve solo a guardare i
passaggi intermedi. Il file preso dallo scambio si chiama `frame_NN_<largo>x<alto>.ppm e il
contatore NN avanza di uno ogni campione, con il passo dato da `MESA_NV_SHOT_EVERY.

Nota di misura, verificata su Mad Mod Mike il 2026-11-12, che evita un errore costoso.
`MESA_NV_SHOT_AT=swap` sposta la diagnosi del fotogramma dentro lo scambio. Lì il campione viene
preso nel callback gallium `flush_swapbuffers`, e `_mesa_nv_note_clear` legge il framebuffer della
finestra con `_mesa_ReadBuffer(GL_BACK)`. Se nello stesso momento sono armate le sonde di lettura
indietro dei magazzini a colori o di profondita (`MESA_NV_DUMP_COLTEX`, `MESA_NV_DUMP_DEPTHTEX`),
che mettono blit in coda, il processo si ferma al primo scambio: zero scambi completati, 22 fili
tutti addormentati in `__futex_wait`, zero eccezioni, log fermo a 4197 righe dopo 126 letture di
magazzino. Ora, con quelle sonde armate, la diagnosi di scambio viene saltata e lo dice out loud
(`MESA-NV DIAG-SKIP`), perche una misura assente in silenzio era gia costata una notte intera.
Per avere insieme le immagini dei fotogrammi presentati e le letture dei magazzini si lascia
`MESA_NV_SHOT_AT=swap`: la cattura dentro `glXSwapBuffers` resta attiva anche con le sonde armate
(perche e misurata sicura: 538 scambi, 4 scatti con contenuto reale media 70.65 su 255 a
1920x1080, 24 immagini di faccia dei cubi a colori, 3234 letture delle sei facce di profondita),
mentre viene saltata solo la parte che sta dentro il callback gallium. Il teste che lo dichiara e
`MESA-NV DIAG-KEEP`. Lasciare `MESA_NV_SHOT_AT` spento non e un'alternativa utile su Mad Mod Mike:
la diagnosi di frame su glClear legge il FRONT e produce scatti tutti a zero (media 0, min 0, max 0
su frame_02_912x576.ppm in tutti e quattro gli assetti misurati). `MESA_NV_SHOT_SWAP_FORCE=1`
rimette la parte dentro il callback e, con le sonde armate, riproduce il congelamento: serve solo a
chi vuole vedere il blocco da vicino.


| `MESA_NV_SWAP_DELAY=<us>`, `MESA_NV_SWAP_PERIOD_US=<us>` | 0 | throttle presents (for trace-shaped timing) |
| `MESA_NV_CLEAR_MAGENTA=1` | off | clear to magenta: distinguishes "not drawn" from "drawn black" |
| `MESA_NV_FORCE_DEPTH_CLEAR=<1\\|2>` | off | add depth (and stencil) bits to zero-mask clears |
| `MESA_NV_FORCE_CULL=<mode>`, `MESA_NV_FORCE_NO_DEPTH=1` | off | culling / depth-test overrides used while bisecting |
| `MESA_NV_DUMP=<dir>`, `MESA_NV_DUMP_NVPROG_DIR`, `MESA_NV_DUMP_NVPROG_MAX` | off | dump NV and translated program text |
| `MESA_NV_DUMP_PARSEFAIL=<dir>` | off | when the ARB assembly parser rejects a program, write `rejected-NNN-{fp,vp}.txt` and print the error position and Mesa message |
| `MESA_NV_DUMP_FP_EXEC=<dir>` with `MESA_NV_DUMP_FP_EXEC_ID=<id[,...]|all>` and `MESA_NV_DUMP_FP_EXEC_MAX=<n, default 8>` | off | writes the program text the driver holds for a fragment program id, plus an executed-IR section appended at the flush point. Needed because `MESA_NV_DUMP_ARBTEXT_DIR` (default cap 60) only sees programs that pass through nv_to_arb: measured 2026-11-15 on Mad Mod Mike the blur (id 107) and the heat composite (id 118) do, and their translator files are byte-identical to the text the driver keeps, while the threshold filter (id 114, 3834 bytes) arrives already in ARB form (loader witness `target 0x8804`) carrying the fp40 dialect inside `!!ARBfp1.0` (`OPTION NV_fragment_program2`, `MULH_SAT`, `SGTHC`), so what decides its behaviour is our extended ARB parser and prog_to_nir, not the translator. Known limitation: for legacy programs the object's `nir` field is still NULL at the flush, so the IR section stays empty until the state tracker's compiled object is read. |

---

### 2.5 Switches read by the features series that were undocumented until 2026-11-04

Note of 2026-11-14 evening: `MESA_NV_TRACE_DEPTHUPLOAD` belongs to this list because of marker
nesting, not by design. In `st_cb_texture.c` the `#include "main/nv_extensions.h"` line sits in a
common (keep) region that wraps a diagnostics region, and the series splitter copies the whole
common block into the features series, so the depth-upload witness and its `<stdlib.h>` /
`<string.h>` includes travel with it. The right correction, deliberately left to the next session
because the first attempt at it corrupted the development tree, is to give the include its own
narrow keep region and leave the witness in diagnostics only, or to make the witness function
file-local; either way `MESA_NV_TRACE_DEPTHUPLOAD` then disappears from the features census and
this paragraph can be deleted.


`tools/nv_doc_serie_check.py` compares the names read by the code of the features patch
with the names this document mentions, and on 2026-11-04 it found 23 gaps. They are
listed here so the published document covers the whole behaviour surface. Defaults: every
one of them is **off**, and the project's launcher does not set them.

Register combiners (11 `MESA_NV_COMB_*`, all in `src/mesa/main/nv_combiners.c`):

| switch | off by default | what it does |
|---|---|---|
| `MESA_NV_COMB_PARAMS` | - | the combiner parameter path (documented in 2.4; listed again because the family is counted here) |
| `MESA_NV_COMB_LITERALS=1` | yes | writes the combiner constants back into the program text as literals instead of named parameters - used to compare two generations of the same text |
| `MESA_NV_COMB_QUANT=<bits>` | yes | quantises the constant values to a 1/2^bits grid, only when the parameters are not real program parameters. Kept as a diagnostic switch because it measurably loses: with a 1/255 grid the composite's luminance oscillates about 5 levels out of 255 at roughly 40 Hz (probe over the fade area: 64 60 59 59 64 59 64 64 59, one 128 drop in 7 s), with the exact 1/4095 grid a single drop only, at the same frame pace (p50 6.9 ms in both cases) |
| `MESA_NV_COMB_EXACT_CONSTS=1` | already the default behaviour | forces the exact constants even if `MESA_NV_COMB_QUANT` is set |
| `MESA_NV_COMB_ALWAYSFLUSH=1` | yes | flushes the combiner constants on every fetch even when the state signature did not change; used to test whether caching was what made a frame black |
| `MESA_NV_COMB_NOWRITE=1` | yes | does not write the parameter values at all: shows whether the values are what reaches the shader (intended for experiments only; a switch with this effect is not a diagnostic aid in a release build, and it is never set by the launcher) |
| `MESA_NV_COMB_FORCEWHITE=1` | yes | replaces the constant colour with (1,1,1,1) (same category as `NOWRITE`: it changes behaviour, so experiments only) |
| `MESA_NV_COMB_ZEROSTATE=primary` | yes | when an application enables register combiners without configuring any register, NV hardware routed the primary colour; without this rule the generated program emits a constant colour (`MOV result.color, fragment.color;`) |
| `MESA_NV_COMB_SHOWCONST=1` | yes | makes the result colour be the first used combiner constant: shows whether parameter values really arrive in the shader |
| `MESA_NV_COMB_RED=1` | yes | emits solid red: shows whether the generated program is the one actually bound to the draws in progress |
| `MESA_NV_COMB_TESTOUT=white_single\|white_split\|t0_plus_one` | yes | A/B that isolates how `result.color` is written: one 4-component write versus the two partial writes (`.xyz` plus `.w`) that the normal path emits - this is what separated the black-wireframe hypotheses |

Texture forcing, used for the Timbury "bite" investigation (`src/mesa/main/texparam.c`,
`src/mesa/state_tracker/st_atom_sampler.c`):

| switch | what it does |
|---|---|
| `MESA_NV_FORCE_TWRAP=clamp\|repeat\|mirror` | forces the texture wrap mode |
| `MESA_NV_FORCE_MAXLVL=<n>` | forces `GL_TEXTURE_MAX_LEVEL` (`0` shows only level 0) |
| `MESA_NV_FORCE_TFILTER_SET=<min>:<mag>` | forces the min/mag filters by GL enum (for example `0x2703:0x2601`) |
| `MESA_NV_FORCE_TFILTER_DIM=<WxH>` | restricts the forcing above to textures of that exact size |
| `MESA_NV_LOD_BIAS=<float>` | shifts the chosen mip level for every texture; a debug knob, checked before use because it also moves the level the application asked for |

Programs and text replacement (`src/mesa/main/nv_program.c`):

| switch | what it does |
|---|---|
| `MESA_NV_PATCH_BITE_FP`, `MESA_NV_PATCH_BITE_FIND`, `MESA_NV_PATCH_BITE_TH` | backwards alias, still used by the launcher, for a single `MESA_NV_REPLACE` rule of the form `f<id>:<find>:<threshold>`; `MESA_NV_PATCH_BITE_FIND` defaults to `-0.9960938` (the value whose one-ulp difference caused the leaf/flower bite). The legacy rule is placed before `MESA_NV_REPLACE`, so setting both does not silently change what the old behaviour meant |
| `MESA_NV_PROG_LATCH_SUB=<text>` | re-enables only the programs whose NV text contains `<text>` (used when one program of a long list has to be left latched) |

GLX and captures:

| switch | what it does |
|---|---|
| `MESA_NV_GPX_TRACE=1` | traces the GLX protocol path for creating and destroying the pbuffers' drawables (`src/glx/dri_common.c`, `src/glx/glx_pbuffer.c`); the label is emitted only when the switch is set, so the extra cost is not paid by default. This is the probe that separated the Dusk / Truck / Toys pbuffer behaviour |
| `MESA_NV_SHOT_COPY=<dir>` with companions `MESA_NV_SHOT_CEVERY=<n>` (sample every n-th copy, default 60) and `MESA_NV_SHOT_CSKIP=<n>` (skip the first n) | takes the framebuffer shot at the moment of the copy into the texture (`CopyTexSubImage2D` on `GL_TEXTURE_RECTANGLE`, no FBO involved): it shows what really lands in the feedback accumulation buffer of Blobby Dancer |

Environment variable taken from upstream Mesa:

* `MESA_MAX_TEXTURE_IMAGE_UNITS` - the series honours it when advertising the number of
 texture units; `run.sh` sets it to 16 because the legacy demos were written against
 GeForce 3/4 limits (measured: the same binary with 32 units gets different behaviour in
 two demos, so the cap is part of the emulated machine, not a tuning knob).

---

## 3. `0002-nv-legacy-diagnostics.patch`

Everything in this patch is wrapped in the markers

```c
/* nvdbg:begin */ ... /* nvdbg:end */
/* nvdbg:keep-begin */ ... /* nvdbg:keep-end */
```

and `tools/make_nv_patches.py` splits on them: a keep-region holds code that
**feature** code calls (a cached env read, a shared prototype), so that patch 0001 still
compiles alone. `tools/nv_check_nvdbg_balance.py` proves the markers are balanced and
that no marker is inert because of text on the same line.

**The rule:** diagnostics must not change behaviour. Reading a value, printing a line,
writing a PPM: yes. Changing what the demo draws: no. The exceptions below exist only as
A/B levers; they live in this patch precisely so that dropping it drops the behaviour
change, and `--no-wine-diag` (plus a features-only Mesa build) proves the separation
still holds.

### 3.1 Conventions

* `MESA_NV_TRACE_<AREA>=<max lines>` - one line per event, capped; unset or `0` = off.
 Companions add detail: `_MAX` (line budget), `_FP`/`_VP` (restrict to one program id),
 `_EVERY`/`_SKIP` (sampling), `_NAME`/`_ID` (filter by name or id), and `_FROM` (a
 Mesa-frame lower bound, used by `MESA_NV_PARAM_TRACE_FROM` to let a late run's writes
 survive the startup flood).
* `MESA_NV_DUMP_<X>=<dir>` - writes files (PPM/PAM/BIN/text); `..._DIR`, `..._MAX`,
   `..._MINW`, `..._MAXPX` bound the output.

 * Colour-target size limits: `MESA_NV_DUMP_COLTEX_MINW`/`MESA_NV_DUMP_COLTEX_MAXW` compare
   against BOTH axes, so a 1280x720 target cannot be selected without also taking the
   1024x1024 ones. `MESA_NV_DUMP_COLTEX_MINH`/`MESA_NV_DUMP_COLTEX_MAXH` (added 2026-11-13
   while replaying the Mad Mod Mike trace from period hardware) limit the vertical axis
   alone and fall back to the width limits when unset. The registration queue holds
   `NV_DTX_MAX=64` entries per round, so an over-broad window fills it with shadow atlases and the
   targets of interest never appear. Since 2026-11-13 the number of images written is a knob too:
   `MESA_NV_DUMP_DEPTHTEX_MINW=<width, default 64>` gates BOTH depth registration paths: the depth
   textures that a draw samples and the depth textures attached to a framebuffer as its depth
   attachment. It used to gate only the first, so asking for the 3072x2048 Mad Mod Mike shadow atlas
   with `MINW=3000` still filled the queue with the six 96x96 cube faces (measured 2026-11-13 late:
   12 dumped images, all 96x96, no atlas). With the rule honoured the same run produced eight
   3072x2048 atlas images and no faces, and the atlas statistics became measurable: mean 0.9952,
   minimum 0.8314 over the whole surface.
   `MESA_NV_DUMP_COLTEX_MAXFILES=<n, default 60>` and `MESA_NV_DUMP_DEPTHTEX_MAXFILES=<n, default
   60>`, counted separately per kind. Before that the total was hard-wired at 60 with a single
   counter for both kinds, measured on Mad Mod Mike: the probe stopped after 30 images of the
   1280x720 main store and 30 of the 428x240 bloom store, which makes it impossible to pair a
   captured frame with images of that same frame, and a content comparison between frames that do
   not match is not evidence. These are not the same thing as `MESA_NV_DUMP_DEPTHTEX_MAXPX`, which
   bounds the pixel count of one image.
   The statistics line each dumped texture prints used to say `MESA-NV DTX frame=<n>` while passing
   the round tick counter: the label was wrong, the number was not a frame. It now prints
   `MESA-NV DTX tick=<n> frame=<n>` with the real Mesa frame counter as second value, which is the
   only way to pair a dumped image with a captured frame (measured 2026-11-13 on the Mad Mod Mike
   composite pass: with the old label a whole afternoon of reading compared captures from one
   moment with surfaces from another). Each dumped texture also prints a statistics line with
   the alpha histogram (`MESA_NVTEX_ALPHA`).


 * Cube render textures are dumped FACE BY FACE: `MESA_NV_DUMP_COLTEX_FACE_FROM=<n>` and
   `MESA_NV_DUMP_COLTEX_FACE_EVERY=<n>` choose from which census read the six colour face
   images are written and how often they are rewritten (without a window the file keeps the
   first frame of the run, and on Mad Mod Mike the first frames hold empty faces: colour 0,
   alpha 255, six of them identical). The same pair for depth cubes is
   `MESA_NV_DUMP_DEPTHTEX_FACE_FROM=<n>` and `MESA_NV_DUMP_DEPTHTEX_FACE_EVERY=<n>`, writing
   `depth-<object>-t<name>-<size>-<face>.pgm` from the depth to colour COPY blit, with
   `min/max/mean/nonZero` per face on the `MESA-NV DTX-DFACE` line. Every line and file name
   carries the object pointer, because texture names are recycled.

Aggiunta di misura del 2026-11-12: la lista dei campioni di profondita si riempiva solo di texture
che qualche disegno CAMPIONA come profondita. Un magazzino che l'applicazione usa soltanto come
attacco di profondita, e che non campiona mai, non veniva mai registrato e quindi non veniva mai
letto: su Mad Mod Mike il cubo di profondita 96x96 dell'ombra omni dura (creato dall'applicazione
con sei `glTexImage2D` di GL_DEPTH_COMPONENT16 e usato come attacco di profondita del proprio
framebuffer cubico) non e mai comparso, con 0 immagini di profondita in 4 rassegna, mentre i
magazzini a colori ne producevano 24 di facce ciascuna. Ora `_mesa_framebuffer_texture` registra
anche la texture che diventa attacco `GL_DEPTH_ATTACHMENT`/`GL_DEPTH_STENCIL_ATTACHMENT`, e il
giro delle sei facce la pu leggere: nella stessa rassegna le immagini di profondita sono diventate
6 per ogni variante. Misura resa possibile dal fatto che la registrazione non prende lock e non
chiama GL, perche avviene a mutex del framebuffer tenuto.
| `MESA_NV_TRACE_FBATTACH=<n>` | off | print every framebuffer texture attachment (framebuffer, attachment point, texture target, name, object pointer, level, layered); `<n>` is the line cap, 0 = no cap. Added 2026-11-12 to tell apart "the application attaches the six cube faces one by one" from "it attaches the whole cube", which the readback alone cannot show. |
* `MESA_NV_SHOT*` - frame captures at the GLX level.
* `MESA_NV_PROBE`, `MESA_NV_PROBE_ALL` - a probe draw that reads back GL state
 (`glGetQuery*`-style) for replay comparison.
* All output goes to `stderr` with a `MESA-NV` / `MESA_NV_` label so that
 `grep -a 'MESA-NV'` isolates it; the label name is the knob name in capitals, so
 changing a label means changing the tools that grep it (that has already bitten once).

### 3.2 What can be traced (146 `MESA_NV_TRACE_*` switches)

Grouped by area; the prefix `MESA_NV_TRACE_` is omitted:

* programs and parameters: `NVREJECT, A2C, COMB, COMBDRAW, DRAWPARAMS, ENVPARAM, MASKS, NAMED,
 NAMED_MAX, NVREG, NVREPLAY, PARAMS, PARAMS_ID, PROGS, REMAP, TEXSHADER, TFP,
 VP_IDS`
* draws and vertex state: `ARRAYS, ARRBUF, ATTRBIND, ATTRIBS, ATTRSET, ATTRS_FP,
 BADDRAW, BEGINEND, DRAW, DRAWCALL, DRAWCALL_BITE, DRAWCALL_IDX, DRAWCALL_FP,
 DRAWCALL_MAX, DRAWSTATE, DRAW_TARGET,
 DRAW_TARGET_SIZE, PIXDRAWS, PRIM, PRIM_FP, PRIM_MAX, VERTDATA, VERTS, VERTS6,
 VERTS_MAX, CLIENCALL, UVBUF`
* textures, samplers, bindings: `BIND, BINDBUF, BINDBUF_MAX, BINDMISMATCH,
 BINDNOTENABLED, SAMPLER, SAMPLERS, SAMPLERS_FP, SAMPLERS_MAX, SAMPLER_MAX, TEX,
 TEXBIND, TEXBIND_FP, TEXBIND_MAX, TEXBIND_MINUNITS, TEXBIND_NAME, TEXBIND_SKIP,
 TEXFILT, TEXFILTER, TEXFMT, TEXGEN, TEXIMAGE, TEXIMAGE_MAX, TEXIMG, TEXPARAM,
 TEXPARAM_MAX, TEXPARAM_NAME, TEXSHADOW_FP, TEXSHADOW_FRAME_MAX, TEXSHADOW_FRAME_MIN,
 TEXSTORAGE, TEXSTORAGE_EVERY, STTEX, COPYPATH, COPYPATH_TEX, RT_UPLOAD,
 RT_UPLOAD_SIZE`
* framebuffers, swap, presentation: `FB, FBDRAW, FBDRAW_FP, FBDRAW_SKIP, FBDRAW_TEX,
 FBO, FBSIZE, FB_FILTER, FBSIZE_RESET, FRAMES, SLOT, STATE, STATE_MAX, STATE_SKIP,
 SWAP, VISUAL, BLEND, CLEAR, CLEAR_ALL, MATRIX, RAST, RASTPOS, BITMAP, DEPTHSTATO,
 ENABLES, ENABLE, FALLBACK, GET, LOCK, MIPMAP, NVCOUNTS, OCC, OCCFORCE, READBUF,
 READPIXELS, READPIXELS_SIZE, ALPHA_LOW, ALPHA_LOW_FP, ALPHA_LOW_MAX, TRACK_ANSWER`
* blit and copy paths: `BLIT, BLIT_DUMP, BLIT_EVERY, COPY, COPYDATA, COPY_MAX,
 FENCEFORCE`

* the GL errors themselves: `GLERROR, GLERROR_MAX` - prints every error the driver raises,
 with the call that raised it, before Mesa decides whether the message is worth showing.
 Added for Mad Mod Mike: the demo reads `glGetError()` itself and blames the shader
 compiler when an error from an earlier call is still pending, so the hypothesis worth
 testing was "a silent error poisons the Cg runtime". Measured with this switch: zero GL
 errors raised by our driver in the whole run, which is what moved the investigation to
 the Cg profile check instead (docs/mad-mod-mike.md).
* other: `VARANGE` (vertex array range: the read is in a keep-region, the print is
 diagnostics), `FORCE_BLEND` (see 2.5: it forces the blend state for an A/B, it is not
 only a trace), `DUMP_*` below

### 3.3 What can be dumped (56 `MESA_NV_DUMP_*`)

`ARBTEXT(_DIR,_MAX), ARRAY(_DIR,_MAX), ATTRIBS(_DIR,_MAX), BUFMAP(_DIR,_MAX), COLTEX(_MAXW,_MINW),
CPARAMS, DEPTHTEX(_EVERY,_MAXPX,_MINW), FB(_IMAGES: _MAX,_SIZES,_FROM,_UNTIL), PARSEFAIL,
LPARAMS(_MAX), TEX(_DIR,_EVERY,_INLINE,
_MINVERTS,_NAME,_SKIP), TEXDATA(_MAX,_TEX), VATTRIB`

The depth-texture dump (`DEPTHTEX`) is what showed Nalu's soft shadows were fed an
out-of-date depth pbuffer archive: it re-reads every sampled depth texture and prints
min/max/mean/fraction non-zero, which distinguishes "stale" from "never copied".

### 3.4 Forced experiments (they do change behaviour - A/B only)

`MESA_NV_FORCE_ATTRIB, FORCE_FENCE_TRUE, FORCE_LINEAR_RT, FORCE_NO_CULL, FORCE_NPARAM,
FORCE_OCC_AVAILABLE, FORCE_OCC_PIXEL_COUNT, FORCE_POLYMODE, FORCE_SAMPLES,
FORCE_TFILTER, FORCE_TFILTER_COMP, MESA_NV_NO_CULL, NO_POS_SATURATE, NO_SRGB_DRAWABLE,
NO_SRGB_VISUAL, POS_CLAMP, SKIP_COPY, MAX_ANISO, GL_RENDERER, GL_VENDOR, ALPHA_TEST,
ALPHA_TEST_FP, FP_REPLACE, FP_SCALE, GENMIP_FORCES_LOD, INJECT_MASK(_FP,_DANGER),
PROBE, PROBE_ALL, SAMPLE_TARGET, TRACK_ANSWER, UNBOUND_TEX, UPLOAD_KB, VP_C_LOCAL,
VP_FORCE, BUFFER_CENSUS(_MAX), CENSUS_DUMP(_DIR)`

`MESA_NV_TRACE_DRAWCALL_IDX=1` samples the index *data* of a draw. Off by default on
purpose: measured on the BugLooker replay, the pointer reaching the probe can map a
region shorter than `count` claims, and sampling faulted (gdb pointed inside that loop).
Enable it only when you want to look at index values.

`UNBOUND_TEX=<black|white|<level>>` is the clearest example of why an experiment is
useful: it changes the fallback colour of an incomplete texture, which makes GasStation's
wireframe visible instead of black (`docs/gasstation-wireframe.md`). Shadow/depth
samplers deliberately stay black.

Note: some of these names are read by the features series as well (measured: **15** names
appear as reads in both patches, because the value is taken in a keep-region and the
printing lives in the diagnostics series). They are documented once, here, and
`tools/nv_doc_serie_check.py` recomputes that number from the patches so this sentence
cannot go stale.

---

| `MESA_NV_INJECT_FILL=<r>,<g>,<b>,<a>` | at draw time fills the texture object that the draw census is sampling, with the four byte values given |
| `MESA_NV_INJECT_FILL_MAX=<n>` | 4000 | how many fills a run may apply |
| `MESA_NV_INJECT_FILL_ONCE=<0|1>` | off | fill once instead of at every draw of the pass |

## 4. Checking a change to these patches

```sh
python3 tools/make_nv_patches.py # regenerate both series
python3 tools/nv_check_nvdbg_balance.py # markers balanced, none inert
python3 tools/nv_codice_file.py mesa 060e1d8 # code identical to a validated state
python3 tools/nv_codice_file.py mesa HEAD --scheletro # only string/comment text differs
python3 tools/nv_codice_file.py mesa HEAD --nomi # only identifier names differ
python3 tools/nv_audit_localizzazione.py # Italian left in comments/strings/names
./build.sh --mesa-only
bash tools/nv_fs_sweep.sh # 10 fullscreen demos, frames presented, no GL errors
bash tools/nv_sweep_contenuto.sh # 12 demos, content signal, exceptions 0
bash tools/nv_rastpos_oracolo.sh # raster position oracle
bash tools/nv_slider_oracolo.sh # Timbury slider text oracle
```

`nv_codice_file.py` applies the old and the new series to the same pristine tree and
compares whole files: `--scheletro` blanks the content of string literals, `--nomi` also
turns every identifier into `I` and every number into `N`. Those three modes are how a
comment translation, a log-string translation and an identifier rename are each proven to
have changed nothing else.

## 5. Renamed knobs

Four diagnostic knob names were changed on 2026-11-02. Two were Italian, and two were
simply **dead**: the identifier-rename pass of an earlier session had also rewritten text
inside string literals, so two `getenv()` calls were looking for `nv_MESA_NV_TRACE_*` -
names nothing ever set. The documented knobs had been silently doing nothing for weeks and
no test noticed, which is the reason `tools/nv_audit_localizzazione.py --docs` now checks
every knob name cited in these documents against the real patch series.

| old | new | note |
|-----|-----|------|
| `MESA_NV_TRACE_FB_FILTRA` | `MESA_NV_TRACE_FB_FILTER` | the source comment already used the English name; the code was the odd one out |
| `MESA_NV_TRACE_FBSIZE_RIPARTISCI` | `MESA_NV_TRACE_FBSIZE_RESET` | it zeroes the per-framebuffer table after each report, so each report covers only the interval since the previous one |
| `nv_MESA_NV_TRACE_FB_STEP` | `MESA_NV_TRACE_FB_STEP` | was dead: no one set a name with an `nv_` prefix |
| `nv_MESA_NV_TRACE_DRAWCALL_BITE` | `MESA_NV_TRACE_DRAWCALL_BITE` | was dead: the comment described `_BITE=1`, the code read `nv_MESA_...` |

The old names are gone rather than accepted as aliases: they only ever appeared in this
project's own docs and tools, and an alias would have kept Italian in the source. The
tools that grepped the affected log labels were updated in the same pass
(`riordinato dal layout` -> `reordered from layout`).

## Render texture a colori servite al momento del campionamento

Lato Mesa ladessione arriva dal canale privato gia usato per la profondita: `glTexParameteri  con pname
`0x8FFF0002  (valore: il nome del framebuffer in cui Wine disegna il pbuffer ) imposta il campo
`nv_rt_color_alias  della texture in `main/mtypes.h. La tabella drawable/texture con le generazioni dei disegni
e delle copie sta in `main/nv_extensions.c; `state_tracker/st_draw.c  alza le generazioni quando quel
framebuffer viene disegnato, `state_tracker/st_atom_texture.c  prima della validazione del disegno chiede la
copia se le generazioni differiscono. La copia e un blit `GL_COLOR_BUFFER_BIT  con `GL_NEAREST  dal framebuffer
di Wine alla texture della demo allegata come `COLOR_ATTACHMENT0  di un framebuffer privato, livello 0; se lo
stato di uno dei due framebuffer non e `FRAMEBUFFER_COMPLETE  la copia viene saltata, e un garde anti ricorsione
impedisce che il blit rientri dal percorso di cancellazione. Senza adesione il codice non fa nulla: le altre demo
non sono toccate. `MESA_NV_RT_COLOR_ALIAS=0  lo disabilita comunque, per i confronti A/B senza ricostruzioni. Le due stampe che
mostrano la consegna in corso o il suo rifiuto (taglie o numero di campioni diversi) stanno in due funzioni
separate del frontal DRI, chiuse dietro `MESA_NV_RT_COLOR_TRACE=1  (spento di default ) e limitate a sei righe per
- `MESA_NV_RT_COLOR_ANY=1  (spento di default ) - modalita diagnostica: segna come sporchi tutti i
  magazzini delle render texture a colori a ogni disegno, invece di riconoscerli dal disegnabile. Serve
  perche la chiave per disegnabile e risultata sbagliata: labbinamento avviene nel contesto interno di
  Wine, e ogni contesto ha l'oggetto-wrapper proprio della stessa superficie, quindi il puntatore
  registrato allabbinamento non e quello del disegno della demo. ATTO: cosi Luna va in eccezione
  (err:seh:send_debug_event Exception c0000005) subito dopo gli abbinamenti, quindi e uno strumento di
  indagine e non una strada di prodotto.
tipo, cosi la diagnosi non allaga il stderr: le stampe incondizionate in passato sono costate 6,4 MB di log in un
minuto su Luna.

### Stato misurato del meccanismo (build usata nei confronti delle 17:42 )

Lato Wine ladozione arriva: dieci righe `nvlegacy COLOUR-ALIAS  (texture 5, 18, 12, 24, 25, 26, 27, 3 ).
Lato Mesa labbinamento texture-disegnabile avviene: otto righe `MESA-NV RT-COLORE: abbinata. Le generazioni
pero non scattano mai: tre righe dicono che la texture e campionata ma il magazzino non e stato ridisegnato,
per il motivo della chiave (contesto interno di Wine contro contesto della demo). Forzandole con
`MESA_NV_RT_COLOR_ANY=1  la demo cade in eccezione subito dopo gli abbinamenti. Nessuno di questi knob e
attivato dalla configurazione dei filmini: `run.sh  non li imposta, e l'esecuzione base di Luna resta invariata
(25 campioni su 25, nessuna caduta). Il lavoro riparte da qui: la coppia va registrata nel contesto della demo,
non in quello interno di Wine, e la copia deve avvenire fuori dalla validazione del disegno.

## Promozione delle texture di profondita a 16 bit verso i 24 bit: `MESA_NV_DEPTH16_A_24

Spento di default. Quando attivo, una texture allocata come `GL_DEPTH_COMPONENT16  viene salvata nel
layout di profondita a 24 bit accettato dal driver (scelto tra `Z24_UNORM_S8_UINT, `Z24X8_UNORM,
`X8Z24_UNORM  e stampato una volta con la riga `MESA-NV D16A24: formato accettato #<valore> ).

Motivazione misurata: la mappa d'ombra di Luna che la lookup `SHADOW2D  campiona é allocata a 16 bit
(censimento dei legamenti: magazzino 2048x2048 con `ifmt=#x114  = `PIPE_FORMAT_Z16_UNORM,
`cmp=#x884e  = `COMPARE_REF_TO_TEXTURE, `dmode=#x203  = `LEQUAL ) e i programmi sottraggono un bias
costante di 0.002  (`arbtrad-097-fp.txt, riconosciuto dal censimento per lunghezza 851 ). Sul
ferramento del 2004 lo store di profondita del pbuffer era a 24 bit, quindi quel bias valeva una
frazione piccola dellintervallo; a 16 bit vale circa tredici volte tanto in termini relativi, e il
profilo d'ombra che sul feramento reale é nero duro  diventa una macchia grigia.

Nota: il campo `ifmt  del censimento é il formato Mesa dell'immagine della texture, non quello pipe;
la promozione quindi non si vede cambiare quel numero, va giudicata sul disegno.

## Censimento dei legamenti: `sh, `m, `len, `ifmt  e `MESA_NV_DUMP_FP_TEXT

Il censimento dei legamenti delle unita di texture (`MESA_NV_TRACE_TEXBIND=<fb >, `-1  = tutti ) adesso
dice anche:

- `sh=<n > m=#x<maschera >`: quante istruzioni `SHADOW1D/2D/CUBE  ha il programma frammento in uso e
  su quali unita (le unita sono marcate con `*  nella riga). Letto dal testo del programma, perche in
  questo Mesa `struct gl_program  non ha un array di istruzioni: ha `String, `Format  e NIR.
  Misura su Luna: un solo programma usa il confronto, 1686 disegni, unita marcata #x2, e laggetto
  a quellunita é il magazzino 2048x2048 di profondita con confronto attivo.
- `len=<byte >`: lunghezza del testo del programma. Serve per collegare gli id del censimento ai file
  tradotti: per esempio `fp=138 len=851  corrisponde a `arbtrad-097-fp.txt  (851 byte ).
- `ifmt=#x<valore >`: formato Mesa reale dell'immagine, per distinguere un magazzino RGB8  da un RGBA8
  quando il formato base dice solo `GL_RGBA.
- `MESA_NV_DUMP_FP_TEXT=<dir >`: salva il testo del programma frammento in uso al primo disegno che lo
  usa, un file per id (`fp<id>-<lunghezza>.txt ). Indispensabile: i 47  programmi frammento cosi
  salvati includono quelli che ombreggiano creature, occhio e cupola (`fp056  11195, `fp059  11294,
  `fp072  11257, `fp019  10010  byte ), che il dump del percorso NV->ARB non produceva. In `fp059  la
  lookup del magazzino 256x256 é `TEX H4, fragment.texcoord[1], texture[5], 2D  e il risultato entra sia
  come colore (`MADH H15.xyz, H5, c[22].x, H4 ) sia come coefficiente (`H4.w ).

### Lettura diretta della profondita: il blit profondita-colore era uno strumento falso

Il censimento delle mappe di profondita (`MESA_NV_DUMP_DEPTHTEX`) leggeva i magazzini di profondita con
un blit verso una texture a colori. Misurato oggi: con la texture di profondita allegata a
`GL_DEPTH_ATTACHMENT` il framebuffer di lettura risulta COMPLETO (`fb_leg=#x8cd5`), il blit risponde
`blit=#x0` senza errori, la `ReadPixels` risponde `rd=#x0`, eppure il risultato e tutto zero. Le cifre
usate nelle conclusioni precedenti su questo percorso vanno quindi lette cosi:

- ritiro: "la mappa d'ombra campionata ha `min=0 max=1 mean=0.040` con `nz=0.080`, quasi tutti texel a
  zero"; e di conseguenza "la `glTexSubImage2D` di Wine non arriva alloggetto campionato";
- misura giusta col percorso nuovo (`via=READ-DIRETTA`: `ReadPixels(GL_DEPTH_COMPONENT, GL_FLOAT)` diretto
  dal framebuffer di lettura, con secondo tentativo `GL_UNSIGNED_INT`). Esecuzione pulita di Luna, clock
  deterministico, FSHACK spento, 2220 righe di censimento, tutte `via=READ-DIRETTA`, `rd=#x0`, zero errori
  gravi:
  - magazzino 2048x2048 (tex 3, quello che la lookup `SHADOW2D` campiona): `min=0.106 max=1 mean=0.943
    nz=1.000`;
  - magazzino 1024x1024 (tex 6): `min=0.439 max=1 mean=0.8998 nz=1.000`;
  - `nz=1.000` significa che ogni texel e non zero, quindi la mappa e popolata: il fondo sta al valor di
    lontano e gli occlusori fra 0.106 e 1.

La lettura diretta vale solo quando lispezione riguarda una texture di profondita; per i magazzini a colori
resta il blit `C2C`, che e valido.

La stessa sonda oggi si auto-segnala. Se viene chiesta una cartella di scarico ma dopo 400 tic nessun file
risulta scritto, stampa una sola volta:

    MESA-NV SILENT-PROBE: ... requested, but no file has been written after 400 ticks:
    the probe is producing nothing

Serve perche una sonda muta viene scambiata per un risultato. Misurato oggi su Mad Mod Mike: la regressione
silenziosa di `MESA_NV_DUMP_DEPTHTEX` (sessanta file alle 13:10, poi piu nessuno, con la corsa sana a 486
scambi e zero cadute) ha fatto leggere per un'ora dati che non c'erano. La verifica A/B della guardia: con
`MESA_NV_DUMP_DEPTHTEX` attivo, zero file scritti e una riga di guardia; con `MESA_NV_DUMP_COLTEX` attivo,
sessanta file scritti e zero righe di guardia. Il messaggio e in inglese come tutti i messaggi del codice, e
la guardia non introduce knob nuovi.

### `tools/nv_shadow2d.c`: nel nostro stack il confronto `SHADOW2D` e giusto

Prova isolata senza Wine, con la forma esatta dei programmi di Luna: `OPTION
ARB_fragment_program_shadow` e `TEX result.color.x, program.local[0], texture[0], SHADOW2D`, su texture di
profondita con `GL_TEXTURE_COMPARE_MODE=GL_COMPARE_REF_TO_TEXTURE` e
`GL_TEXTURE_COMPARE_FUNC=GL_LEQUAL`, riempite con 0.4 su una meta e 1.0 sullaltra. Quattro varianti: 16 bit
allocata con dati, 16 bit allocata senza dati e riempita dopo con `glTexSubImage2D`, 24 bit piena, 24 bit
vuota poi riempita. Con reference 0.5 tutte e quattro danno `0.000` sul lato occlusore e `1.000` sul lato
fondo; con reference 0.3 danno `1.000` su entrambi i lati. Ripetuto senza il nostro percorso, col Mesa di
sistema (radeonsi), i numeri sono identici riga per riga.

Nota emersa: `glTexImage2D` con `GL_DEPTH_COMPONENT16` e dati `GL_FLOAT` risponde `GL_INVALID_VALUE`
(#x500), mentre la stessa allocazione senza dati seguida da `glTexSubImage2D` non da errori. Vale identico
nel nostro Mesa e nel Mesa di sistema, quindi non una differenza introdotta dal nostro lavoro.

Conseguenza per lindagine su Luna: lopcode di confronto, i parametri di confronto e il percorso di copia
dei texel di profondita sono corretti; le ombre piu leggere non sono spiegate da questi pezzi.

### Marcatore del magazzino scritto da un programma con SHADOW: `MESA_NV_SHADOW_MARK

Spento di default. Nei due punti di `main/draw.c` che precedono `_mesa_nv_skip_draw` e in cima a
`_mesa_nv_trace_draw` (il punto per-disegno che scatta davvero: i due punti in `draw.c` su Luna non
hanno mai chiamato la funzione, misurato con zero righe di diagnosi), quando la chiave e accesa il
marcatore cerca la parola `SHADOW1D/2D/CUBE/CUBE` nel testo del programma frammento in uso e, se la
trova, mette un bit (`nv_shadow_written` in `main/mtypes.h`) sulle texture allegate come colori al
framebuffer di disegno. Lo scopo dichiarato non era cambiare il rendering, ma dare a Wine un modo per
riconoscere il magazzino giusto da consegnare in zero-copy senza passare dal nome della texture.

Misura su Luna, esecuzione pulita con clock deterministico, FSHACK spento, geometria originale, piu
`MESA_NV_TRACE_TEXBIND=-1` per avere la certezza che il percorso per-disegno girasse:
- righe di censimento dei legamenti 245396, quindi il gancio per-disegno viene eseguito;
- fra quelle righe compare il passaggio d'ombra: `fp=138 len=851 sh=1 m=#x2`, cioe il programma con la
  lookup SHADOW2D in uso c'e;
- righe `MESA-NV SHADOW-MARK`: zero. Il bit non e mai stato messo.

Lettura della misura: il disegno che produce l'ombra non ha una texture come allegato di colore
(probabilmente scrive in un renderbuffer, o in un framebuffer il cui allegato di colore non appartiene
al contesto che campiona), quindi il tipo di dato scelto per il marcatore e sbagliato. Il manico giusto
e il framebuffer o il drawable del pbuffer, non l'oggetto texture: la prossima implementazione deve
marcare quello e esporre a Wine una lettura sul framebuffer, non sui parametri di texture.

Strumento di diagnosi: quando il marcatore scrive il bit, stampa `MESA-NV SHADOW-MARK: tex<nome>
programmato frammento id=<id>` (limite 10 righe, stessa chiave del marcatore).

## Letture progettuali dei programmi ARB/fp40: `MESA_NV_ARB_TXP_SHADOW

Causa trovata il 8 novembre, e prima causa verificata delle ombre troppo leggere di Luna che non
dipendesse dalla mappa o dalla consegna.

I programmi che ricevono l'ombra (id 19, 56, 59, 72: mostri, torso, braccia, colletto) leggono la
mappa d'ombra con la forma progettuale:

    TXP   H4.x, R2, texture[0], 2D;

e l'unita 0 di quei programmi e una texture di profondita 2048x2048 con
`GL_TEXTURE_COMPARE_MODE = GL_COMPARE_REF_TO_TEXTURE` e `GL_TEXTURE_COMPARE_FUNC = GL_LEQUAL`
(censimento live: `u0=tex1 tgt=#xde1 2048x2048 fmt=#x1902 cmp=#x884e`, confronto attivo su decine di
migliaia di disegni). Mesa imposta il confronto solo quando il testo dell'assemblato nomina un target
`SHADOW*`; con un target `2D` la lettura progettuale torna il texel grezzo. Sul feramento del
2004-2005 il confronto avveniva dentro il fetch perche la modalita di confronto e stato della texture,
quindi il valore che entrava nella catena di illuminazione era 0 o 1.

Strumento che lo misura senza Wine: `tools/nv_arbtxp.c`, tre programmi ARB montati su una texture di
profondita 64x64 con texel noti (0.4 a sinistra, 0.8 a destra) e confronto attivato dai parametri di
texture. Misure sul Mesa di progetto con zink:

    variante tex  (TEX ... 2D)            -> 0.800 e 0.800   (texel grezzo, nessun confronto)
    variante txp  (TXP ... 2D) spento     -> 0.800 e 0.800   (il caso di Luna: texel grezzo)
    variante txp  (TXP ... 2D) con il knob-> 0.000 e 1.000   (confronto giusto: 0.9 > 0.8, 0.3 <= 0.8)
    variante shd  (TEX ... SHADOW2D)      -> 0.000 e 1.000   (gia' giusto, fa da controllo)

Attuazione: in `program/arbprogparse.c`, quando la chiave e accesa, si guardano le istruzioni
`OPCODE_TXP` non gia' in ombra e si marchia **tutta l'unita** (tutte le letture di quell'unita
diventano letture d'ombra, perche il feramento decideva per texture, non per istruzione, e perche il
parser rifiuta una modalita di confronto mista sulla stessa unita). In `program/prog_to_nir.c` la
lettura progettuale in ombra fa la divisione progettuale a mano sulle coordinate e sul riferimento,
perche NIR non accetta una sorgente `projector` su un sampler d'ombra; la stessa forma che
`nv_to_arb.c` gia' scrive per l'assemblato NV (per questo il passaggio che prepara il magazzino
d'ombra di Luna, id 138, era gia' corretto).

Chiavi:

    MESA_NV_ARB_TXP_SHADOW=1   accende il comportamento; spento di default
    MESA_NV_ARB_TXP_DIV=0      non divide (per capire se la demo divide gia' nel suo vertex stage)
    MESA_NV_ARB_TXP_REF=<f>    forza il riferimento al costante <f> (per leggere dove sta il
                               riferimento reale della scena)

Le unita che non hanno una texture di profondita perdono il confronto dal passaggio che esiste gia
in `state_tracker/st_program.c` (`nir_remove_tex_shadow` su `~key->depth_textures &
fp->ShadowSamplers`), lo stesso che protegge il caso `SHADOW2D` scritto su una texture a colori; le
letture a colori restano quindi come prima. Limite onesto: il passaggio guarda il formato, non la
modalita di confronto, percio una texture di profondita letta con `TXP` **senza**
`GL_TEXTURE_COMPARE_MODE` impostato verrebbe trattata come d'ombra. Non successo su Luna (tutte le
unita marchiate hanno `cmp=#x884e`); per questo la chiave resta opt-in.

Misure su Luna con il knob spento, per escludere le altre piste:
- maschera d'ombra del programma 19: `shadowmask=#x0` senza chiave, `shadowmask=#x1` con la chiave
  (diagnosi esistente `MESA_NV_TRACE_TEXSHADOW_FP=19`);
- la mappa che i programmi leggono e piena: `tex=1 tgt=#xde1 2048x2048 min=0.101961 max=1
  mean=0.958835 nz=1.000 via=READ-DIRECT`, quindi non e il contenuto della mappa;
- stato di miscelazione e di raster al momento dei disegni, confrontato fra il trace del feramento
  reale e il nostro (`tools/nv_stato_disegni_confronto.py`): per ogni
  programma che campiona la mappa o il magazzino le firme di `glBlendFunc`, `glBlendEquation`,
  `glColorMask`, `glDepthMask`, `glAlphaFunc`, `glDepthFunc`, `glPolygonOffset`, viewport e framebuffer
  sono le stesse, con conteggi proporzionali ai fotogrammi (553 contro 579). La miscelazione non e
  la causa.

Metodo, e una correzione di metodo importante presa oggi: il confronto numerico "stesso indice di
fotogramma" fra due esecuzioni diverse **non e valido** su Luna, nemmeno fra due esecuzioni identiche.
Con il medesimo config e il clock deterministico (`WINE_QPC_STEP=16666666`, `WINE_NV_FSHACK=0`,
`NV_LUNA_CONFIG=none`, finestra di 70 fotogrammi) la differenza di luminanza media della stessa
finestra fra due esecuzioni di base va da -0.138 a +0.158, con media -0.0003. La stessa ampiezza di
prima sembrava effetto delle chiavi. Quindi si giudica per contenuto (`tools/nv_accoppia_fotogrammi.py`) o
dal vivo. Misura con l'accoppiamento per contenuto: la scena della cupola (fotogramma di riferimento
238) e quasi identica fra base e chiave (distanza di firma 1.5), mentre la scena del fotogramma 257
cambia molto (distanza 22.8).

Stato: accettata e accesa da `run.sh` nel solo ramo di Luna (`MESA_NV_ARB_TXP_SHADOW=1`, sovrascrivibile
dall'ambiente come le altre chiavi del ramo). Verdetto visivo sul feramento, raccolto dal vivo il
8 novembre alle 08:57: le ombre corrispondono al feramento reale e la scattering subsuperficiale
della creatura resta integra, quindi la chiave non tocca la correzione delle venature
(`WINE_NV_RT_COLOR_ALIAS=2`). Verdetto ripetuto alle 09:03 con il fullscreen hack attivo, cioe con il
percorso di presentazione che `run.sh` usa di default: anche li le ombre e la scattering sono
corrette. Verifica end-to-end sul lanciatore, senza variabili aggiunte nell'ambiente e con la sola
diagnosi `MESA_NV_TRACE_TEXSHADOW_FP=19`: 20 righe su 20 con `shadowmask=#x1`, zero errori gravi.

Cautela dichiarata: la chiave e provata su Luna e sul POC `tools/nv_arbtxp.c`, non su tutte le demo.
Il limite noto resta che il passaggio `nir_remove_tex_shadow` guarda il formato della texture e non la
modalita di confronto, percio una texture di profondita letta con `TXP` senza
`GL_TEXTURE_COMPARE_MODE` attivo verrebbe trattata come lettura d'ombra. Nelle demo che usano il
percorso NV c'e gia la chiave gemella `MESA_NV_TXP_SHADOW` accesa di default da tempo, e GasStation,
Dusk, Nalu, Timbury, Vulcan, Toys, Clear Sailing e Blobby passano da li senza lagnanze; la chiusura
di validazione in sospeso deve pero confermarlo anche sull'esecuzione di release.

## Stampe rimaste nella serie di sola feature, e il errore di struttura che nascondevano (8 novembre)

La smoke di release (11 demo per 32 secondi su `build-release`) ha contato ancora marker nostri:
3321 righe `MESA-NV ARRAY_ONCE` su Vulcan, 2 `MESA-NV TEX3D` su Vulcan, 24 `nvlegacy MESA-RT-OPTIN`
su Nalu, e su GasStation le righe `MESA-ATTR fp=0 attr=1 ...`. Tutte stavano dentro la serie `0001`,
quindi venivano compilate anche senza la serie di diagnosi. Portate in diagnostica:

    gallium/auxiliary/util/u_vbuf.c   due stampe periodiche del contatore ARRAY_ONCE
    main/teximage.c                   cinque stampe del percorso di riordino dei volumi TEX3D
    main/texparam.c                   due stampe del canale privato Wine->Mesa (pname 0x8FFF0001)
    main/nv_extensions.c              le due funzioni di traccia degli attributi (MESA-ATTRTYPE,
                                      MESA-ATTR) erano meta' in una regione di diagnosi e meta' no:
                                      il corpo e' ora un'unica regione, senza annidamenti

Il punto che meritava attenzione non era il volume di testo, ma la struttura: in `u_vbuf.c` le due
stampe erano l'unico corpo di un `if` senza parentesi graffe. Avvolgere solo la `fprintf` avrebbe
lasciato l'`if` senza corpo, e la riga successiva sarebbe finita dentro la condizione. Nella prima
delle due il compilatore se n'e` accorto subito (`error: control reaches end of non-void function`,
perche' il `return true;` seguiva la stampa); nella seconda no: `mgr->pipe->set_vertex_buffers(...)`
sarebbe stata eseguita solo quando `mgr->nv_hit` e' diverso da zero, un errore di comportamento vero
e silenzioso nella build di release. Ora i due rami hanno le parentesi graffe.

Corretta anche una parola malsana lasciata dalla traduzione automatica dei testi: la stringa
`declared as nv_depth archive'` (con un apostrofono appeso) e` diventata `declared as nv_depth store`.


## Nomi della bozza vendor del 2004: `EXT_framebuffer_object` e `NVX_conditional_render` (8 novembre)

Mad Mod Mike (techdemo 39, GeForce 7800 GTX) si installa ma muore all'avvio, e il suo
stesso caricatore di estensioni stampa `Failed to initialize extension
EXT_framebuffer_object`. Misura, non ipotesi: `tools/nv_proc_wgl.c` chiede a
`wglGetProcAddress` i 156 nomi di funzione GL che `strings` trova nell'eseguibile, e
l'unica catena FBO della demo si ferma al primo nome non risolto, che e'
`glFramebufferTextureEXT`. Il disco del caricatore nella demo lo conferma: la sequenza e'
`push $0x6067f0; call *%esi; cmp %ebx,%eax; mov %eax,0x6cd878; je <fallimento>`, quindi
un solo nome mancante azzera tutto il gruppo.

Cosa fa questa patch (serie di feature):

| nome | cosa e' | come e' implementato |
|---|---|---|
| `glFramebufferStorageEXT` | bozza: alloca il buffer di profondita del framebuffer | `_mesa_FramebufferStorageEXT` in `src/mesa/main/fbobject.c`: crea e aggancia lui stesso un renderbuffer (l'oggetto renderbuffer nella bozza non esiste), perche' la demo non chiama mai `glGenRenderbuffersEXT` |
| `glValidateFramebufferEXT` | bozza: il test di completezza | `_mesa_ValidateFramebufferEXT`, stessa firma di `CheckFramebufferStatusEXT` |
| `glGetFramebufferBufferParameterivEXT` / `...fvEXT` | bozza: interrogazione del buffer proprio, senza argomento `attachment` | `_mesa_GetFramebufferBufferParameterivEXT` / `...fvEXT`: trovano loro l'attacco del buffer della bozza; la variante `fv` converte, perche' i parametri sono interi |
| `glBeginConditionalRenderNVX` / `glEndConditionalRenderNVX` | bozza precedente a `NV_conditional_render` | in `src/mesa/main/condrender.c`: la specifica nel registro Khronos dice che equivalgono a `glBeginConditionalRenderNV(id, QUERY_WAIT_NV)`, quindi mappatura diretta su `GL_QUERY_WAIT` |
| `glFramebufferTextureEXT` | **non dichiarato da noi** | il nome esiste gia in Mesa come alias di `FramebufferTexture` (solo nel profilo ES, `es_EXT.xml`), e il generatore rifiuta un nome duplicato; lo risolve Wine con il proprio thunk |

Come si aggiunge un entry point in Mesa (meccanismo letto nell'albero, non inventato):
file XML nuovo in `src/mesa/glapi/glapi/gen/` (`NV_framebuffer_object_draft.xml` e
`NVX_conditional_render.xml`), incluso in `gl_API.xml` con `xi:include` vicino alle altre
estensioni NV legacy del progetto, e nomi aggiunti in coda ad `all_functions` di
`static_data.py`, che e' la lista da cui il generatore calcola gli offset del dispatcher.

Tre guasti veri di questo meccanismo, tutti misurati e corretti in modo onesto:

1. `RuntimeError: Aliased entry-point FramebufferTextureEXT shouldn't be in static_data.py`
   - gli alias non ricevono offset: il nome va tolto da `all_functions` e non va
     implementato in C.
2. `Exception: FramebufferTextureEXT is duplicated`
   - un nome non puo' comparire come entry point in due categorie: la dichiarazione nel
     file nuovo va rimossa, e resta solo una nota che spiega perche'.
3. `Exception: entries are not ordered by slots`
   - `mapi_abi.py` pretende che gli slot 0..massimo siano tutti occupati e in ordine:
     numerando la categoria NVX con 355 (numero reale nel registro) le sue funzioni
     finivano in mezzo all'ordine delle categorie ma in coda agli offset, lasciando tre
     buchi. I numeri 32765 e 32766 nelle due categorie nuove non sono numeri del registro
     (una bozza vendor non ce l'hanno) e servono solo a tenere l'ordine delle categorie
     concorde con quello degli offset.

Misura dopo la correzione, con la sonda esistente `WINE_NV_TRACE_WGL=1` (che stampa ogni
richiesta e ogni fallimento di `wglGetProcAddress`):

    prima: la catena FBO si fermava su glFramebufferTextureEXT, e la demo stampava
           "Failed to initialize extension EXT_framebuffer_object"
    dopo:  230 nomi distinti richiesti, 0 sconosciuti, la riga di fallimento assente;
           si risolvono `glFramebufferTextureEXT` e la coppia NVX; i cinque nomi restanti
           non vengono nemmeno chiesti perche' prima la catena si interrompeva prima di loro

Quello che NON funziona ancora: la demo muore sempre allo stesso punto
(`004A03AF`, `mov 0x0(%ebp),%eax` con `%ebp = [ebx+0xc0]` nullo), quindi il gruppo FBO
non era la causa del crash. Prossima indagine: quale oggetto a +0xC0 resta nullo, con lo
stesso metodo usato per Luna.

Diagnosi aggiunta: `MESA_NV_TRACE_DRAFT_FBO=1` stampa le chiamate ai sei entry point della
bozza con i loro argomenti. Serve perche' le firme della bozza sono una lettura di una
specifica che non esiste piu': la prima esecuzione di una demo nuova di questa famiglia
deve confermare la lettura, non fidarsene.

Rischio di regressione registrato: anche `Luna.exe` (techdemo 26) chiede gli stessi nomi
della bozza, e ora anche per lei la catena FBO si inizializza. Controllato a 45 secondi:
Luna renderizza ancora la scena accettata (sirena, cappuccio, volto, tessuto
semitrasparente, acqua verde, banda MENU in alto). Prima di considerare sicura questa
modifica va ripetuta la passata completa sulle 11 demo; se Luna dovesse cambiare, il
nome e' gia progettato ma non implementato: `WINE_NV_ADVERTISE_NV_DRAFT_NAMES` in Wine,
che nasconderebbe questi entry point alle demo che non li devono vedere.

## Branche del linguaggio NV che aggiornano i codici di condizione

Mad Mod Mike (techdemo 39, GeForce 7800 GTX) passava al driver due programmi vertex in
`!!VP2.0` che il nostro traduttore NV -> ARB rifiutava, e il rifiuto lasciava alla demo un
puntatore di programma nullo che la demo dereferenzia: da li' la pagina di crash a
`004A03AF`. Il riferimento preso dall'hardware vero (apitrace, 3.085.361.744 byte) quegli
stessi programmi li ha caricati senza protestare, quindi il rifiuto era una lacuna nostra.

Cosa costruivano quei programmi: un confronto che scrive i codici di condizione (`SLTC`,
`SLTRC`, `MOVC`, `BRA`) dentro una branca del flusso di controllo NV, con le etichette
(BB1..BB9 in quello rifiutato, 46 istruzioni). Il traduttore materializzava il test della
condizione come predicato della branca, ma non sapeva rappresentare un aggiornamento dei
codici di condizione *dentro* la branca, perche' il suo modello prevedeva che il confronto
stesse sempre fuori, subito prima del salto.

Come e' risolto, tutto in `src/mesa/program/nv_to_arb.c`:

* il test della condizione di branca viene materializzato in un temporaneo ARB
  (`nv_bf%d`) dalla nuova funzione di aiuto `emit_cc_test_flag`, usata anche per la forma
  negata (`nv_bn%d`); le braccia non fanno piu' affidamento sulla lettura diretta dei codici
  di condizione, ma su quel temporaneo;
* `lower_nv_branches` riscrive i salti NV in predicati su quei temporanei
  (`branch_to_flag_inst`), quindi le branche possono annidarsi;
* `OP_FLAGTMP` e' l'opcode interno che emette il predicato e il suo complementare;
* un aggiornamento dei codici di condizione dentro una branca diventa condizionato anche
  lui: se la branca non viene eseguita, non deve corrompere i codici che l'altra branca
  leggera'. Quando un'istruzione ha insieme un codice di condizione proprio e il predicato
  di branca, i due si moltiplicano.

Misure, con i contenuti originali della demo (nessun ricablaggio dei materiali):

```text
rifiuti del traduttore NV (MESA_NV_TRACE_NVREJECT)   2 -> 0
programmi rifiutati dal parser ARB                   0    0
"Could not compile file" della demo                  8 -> 6
"Error loading program" della demo                  16 -> 12
programmi VP2.0 ricevuti  (nostri / riferimento)    85 / 86
programmi FP1.0 ricevuti  (nostri / riferimento)    37 / 38
programmi ARB diretti     (nostri / riferimento)    80 / 81
```

I tre programmi che mancano all'appello non arrivano affatto al driver: la sonda Cg con la
`cg.dll` della demo stessa (profilo richiesto dal blocco di materiale) mostra che `fp20`
`cgGLIsProfileSupported` risponde 0 sui nostri contesti, mentre vp20, vp30, fp30, arbvp1 e
fp40 rispondono 1; gli stessi file compilano puliti a fp30, fp40 e arbfp1 e falliscono a
fp20. La scelta del profilo da parte del motore della demo resta quindi aperta, e non e'
colpevole nessuno dei candidati misurati fin qui: ne' la stringa vendor/renderer
(`MESA_NV_GL_VENDOR`/`MESA_NV_GL_RENDERER`), ne' le pubblicizzazioni di estensione
(`GL_NV_fragment_program3`, `GL_NV_gpu_program4`), ne' i limiti dei programmi (il
riferimento non interroga nessun `GL_MAX_*`), ne' i miei knob del canale float.

Effetto visibile, con i contenuti originali della demo: le immagini a schermo intero
scritte a mano - il foglio "Hey Mad Mike, it's me Gabby" con la foto e la stella, che
prima era completamente assente - ora compaiono nel fotogramma scambiato.

Attenzione pero': la stessa correzione ha introdotto una regressione, trovata perche' la
rassegna del contenuto l'ha segnalata subito. GasStation ha un programma !!VP2.0 (quello
di `..\\shaders\\sun.fp30`, con `BRA` e confronti che scrivono i codici di condizione)
che scrive i registri di uscita dentro la branca. Il traduttore ha gia' il modo giusto per
trattare le scritture predicate di un output: riserva un temporaneo d'ombra
(`shadow_slot`, `nv_o%d`), la scrittura predicata aggiorna l'ombra - che conserva il valore
precedente, cosa che in ARB non si puo' fare su un registro di uscita - e la copia in fondo
pubblica l'uscita con la maschera delle componenti scritte. La mia prima versione del
predicato di branca pero' non passava da li': la pre-pass che riserva l'ombra guardava solo
`cc_test` (la condizione dell'istruzione), non `cc_flag` (il predicato della branca),
perche' quest'ultimo campo prima non esisteva. Risultato: l'ombra non veniva riservata e
l'emettitore rispondeva `predicated writes to output registers are not supported`; la demo
restava con il puntatore di programma nullo e cadeva leggendo 0x00000000 all'indirizzo
0041AA76.

Misure dopo la correzione (2026-11-09):

```text
GasStation   programmi NV ricevuti / tradotti        27/26 -> 28/28
GasStation   rifiuti del traduttore (NV-REJECT)        1  ->  0
GasStation   cadute non gestite                        1  ->  0
GasStation   fotogrammi dello scambio                  0  ->  4   (luminanza 0,533..0,574)
Mad Mod Mike rifiuti del traduttore                   0  ->  0
Mad Mod Mike programmi NV ricevuti / tradotti       122/122 -> 122/122
Mad Mod Mike luminanza dei fotogrammi di controllo  0,176 0,174 0,173 0,150 (identica a prima)
```

Due correzioni in `src/mesa/program/nv_to_arb.c`:
  - la pre-pass delle ombre considera anche `cc_flag`, perche' `lower_nv_branches()` gira
    prima e quindi il predicato di branca e' gia' assegnato;
  - la scrittura predicata la cui destinazione e` un registro di uscita viene riscritta
    sull'ombra riservata (`nv_o<slot>`), invece di rifiutare il programma; se l'ombra non
    c'e` la ragione del rifiuto lo dice in modo esplicito.

Inoltre, letta la macchina senza aspettarsene un sintomo: la copia interna
`struct nv_inst inner` azzerava `cc_test` ma non `cc_flag`, e un'istruzione non-MOV con
predicato di branca sarebbe rientrata nello stesso blocco chiamando se stessa. Corretto;
nessuna programma di GasStation o Mad Mod Mike passa di li', quindi la ricorsione non era
ancora diventata un crash.

Stato della passata composita, misurato oggi: il suo programma vertex ora si carica, ma il
risultato e` nero (luminanza media 0,023 contro 0,176 con la sostituzione nei materiali),
quindi la sostituzione resta. Le cause eliminate per misura sono elencate in
`docs/mad-mod-mike.md`; tra queste la consegna dei colori dei pbuffer, che porta contenuto
(719 legami su 1154 con pixel non nulli).


### I valori iniziali dei parametri nominati (2026-11-09)

Cg scrive il valore iniziale dei parametri nominati di un programma nei commenti che
accompagnano l'assemblato, non in un'istruzione: `#var <tipo> <nome> : ... : c[<slot>] : ...`
dice in quale registro di costanti finisce quel nome, e `#default <nome> = v ...` dice il
valore con cui deve partire. Il driver dell'epoca li applicava al caricamento. Il nostro
traduttore capiva gia` le piu` semplici `#const c[N] = ...` e aveva gia` una tabella di
inizializzazioni dei registri (`struct nv_local_init`, applicata in `_mesa_LoadProgramNV`), ma
non capiva `#var` e `#default`: quindi ogni parametro nominato di ogni programma NV, da noi,
partiva da zero.

Misura sul tracciato di riferimento: `glProgramLocalParameter4dvARB` compare 58167 volte e
tutte quante nominano `GL_FRAGMENT_PROGRAM_ARB`; zero chiamate sui programmi vertex. Il testo
del programma vertex del composito e` identico per lunghezza nei due mondi (2030 byte) e non
contiene `DECLARE`. L'unica fonte di quei valori sono quindi i commenti: il programma legge
`x0y0x1y1` (c[2]), `y_limits` (c[3]), `blur_texel_radius` (c[5]) e un `#const` su c[1].

Implementato: l'analisi dei commenti del traduttore raccoglie nome e registro da `#var` e
trasforma ogni `#default` in una delle inizializzazioni esistenti. Un difetto mio nella prima
versione: la lista dei valori si fermava al primo numero se non era seguita da una virgola, e
il primo valore veniva replicato sull'intero registro (`-1 -1 1 1` diventava `-1 -1 -1 -1`);
corretto, ora l'elenco e` separato da spazi come scrive cgc.

Cosa NON ha risolto, e lo dico per come e` misurato: la passata composita di Mad Mod Mike
resta quasi nera sui nostri fotogrammi. Sui medesimi scambi (26, 33, 40, 47) con la passata
genuina si resta a 0,023 0,032 0,037 0,059, identici a prima della correzione. Il nero ha
quindi un'altra causa, e il ricablaggio dei materiali di `tools/nv_mike_materiali.py` resta
necessario. Cosa ha portato: 83 inizializzazioni su 39 programmi di Mad Mod Mike con i numeri
giusti (c[2] = -1 -1 1 1, c[3] = -1 1 0 1, c[5] = 0.22, c[1] = 0.5 -1 1.5 1), e la rassegna
del contenuto sulle dodici demo invariata (nalu 0.3059, luna 0.3609, mike 0.1483, zero
eccezioni, `NV_SWEEP_CONTENUTO=PASSO`).

La sonda `MESA_NV_TRACE_NVDEFAULT=1` (patch di sola diagnostica) stampa le inizializzazioni
prodotte dai commenti, con programma, stage, registro e valori: senza di essa non si distingue
"l'analisi non ha trovato nulla" da "il valore e` stato scritto dove il programma non legge".

### Difetto noto: lo scarico delle texture corrompe l'heap su Mad Mod Mike (2026-11-09)

`MESA_NV_DUMP_TEX=<dir>` (e `MESA_NV_DUMP_TEX_DIR`) su Mad Mod Mike porta l'host a morire di
`double free or corruption (!prev)` subito dopo una riga `MESA_NVTEX_BEGIN tex=266 face=0
target=0xde1 256x512 depth=1 fmt=#xac base=#x1908`: lo scarico differito (la coda `nv_td_q`
con flush al clear) e' il percorso coinvolto, perche' la stessa demo con lo scarico in linea
(`MESA_NV_DUMP_TEX_INLINE=1`) non mostrava il problema. Sintomo osservato: una tempesta di 42
milioni di righe `trace:seh:handle_syscall_fault code=c0000005 ip=fffffffffffffff0` senza
nessuno scambio di fotogrammi. Non e' la demo, non e' Wine, e' il nostro strumento di
diagnostica: riparato (2026-11-09, stessa giornata: le facce con formato interno compresso vengono ora rifiutate in anticipo con una riga `MESA_NVTEX_SKIP ... formato interno compresso`, e se il readback viene rifiutato l'errore si legge dal campo `ctx->ErrorValue` - non chiamando glGetError, per non consumare un errore che l'applicazione vedrebbe - e la faccia viene saltata invece di finire nello scrittore di PPM con un buffer non scritto)
questa demo; nel frattempo, per il contenuto dei pbuffer cubo usare `WINE_NV_RT_DUMP_DIR` lato
Wine, che non tocca l'heap di Mesa.

Su Mad Mod Mike, dopo la riparazione: 157 facce scaricate e 147 rifiutate perche' il formato
interno e' compresso (`MESA_NVTEX_SKIP tex=236 512x512: formato interno compresso...`). Il
limite e' dichiarato, non aggirato: per vedere il contenuto di una DXT serve decodificare i
blocchi (c'e' `tools/nv_dxt_decode.py` per i file su disco), non chiedere a `glGetTexImage`
un RGBA che le specifiche rifiutano. Lo scarico riparato ha comunque risposto alla domanda
aperta sul magazzino delle ombre: il cubo 96x96 del driver (nome di texture 7) ha sei facce a
livello 0, RGBA8, complete, `minFilter` LINEAR e senza catene di mip usate; le facce 0..4 sono
identiche fra loro (differenza media 0,0000) e solo la 5 (-Z) porta il disegno (0,2489).

## Scrittura dei codici di condizione: SGT e lopzione NV_fragment_program2 (10 novembre)

Il lessico del linguaggio ARB accetta le istruzioni di confronto `SGT `, `SEQ ` e `SLE ` solo
se il programma dichiara `OPTION NV_fragment_program2 `: la regola del lessico e
`require_nvfp2 `, cioe' lopzione impostata in `asm_parser_state `. Quella opzione esiste soltanto
nella tabella dei programmi a frammento (`_mesa_ARBfp_parse_option `), non in quella dei programmi
vertice (`_mesa_ARBvp_parse_option `), quindi per i vertici lopzione non e' nemmeno dichiarabile.

Il transpile NV -> ARB aveva gia' la regola giusta: `emit_instruction_impl ` trasforma
`SGT d, a, b ` in `SLT d, b, a `, perche' `SLT ` e `SGE ` sono accettate sempre. Il difetto era
nel percorso di emulazione dei codici di condizione: quando listruzione scrive nel registro `CC `
(o nell`HC ) della forma NV `SGTC CC.x, ... `, `emit_instruction_body ` stampa il nome dellopzione
NV alla lettera (`inst->op->name `) e non passa dalla regola di riscrittura. Il testo generato
conteneva quindi `SGT nv_ccv, ... `, il parser ARB lo leggeva come un identificatore sconosciuto e
rifiutava l'intero programma.

La conseguenza non era un avviso: il rifiuto passa da `_mesa_error ` con `GL_INVALID_OPERATION `,
che in un contesto senza `GL_KHR_debug ` non stampa nulla. Il programma restava inesistente, la
legatura dell'applicazione non trovava un programma valido e la superficie veniva disegnata senza
il suo programma, a schermo nero o con la combinazione a funzione fissa.

Misura su Mad Mod Mike (dump dei sorgenti NV e dei testi generati con `MESA_NV_DUMP_NVPROG_DIR ` e
`MESA_NV_DUMP_ARBTEXT `): 3 programmi NV su 122 rifiutati, e gli unici opcode vietati nei testi
rifiutati erano `SGT ` (2+1+1 occorrenze). I sorgenti NV interessati usano `SGTC CC.x ` e
`SGTRC HC.x `; i programmi che contenevano `SGT ` con destinazione normale passavano gia' dalla
regola e non erano toccati. Dopo la correzione: programmi rifiutati 0 , occorrenze di `SGT ` nei
testi generati 0 , occorrenze di `SLT ` 55.

La correzione sposta la riscrittura in un aiuto unico (`sgt_needs_swap ` e `sgt_as_slt `) chiamato
in cima a `emit_instruction_body `, prima che qualunque percorso stampi il nome: cosi' il percorso
dei codici di condizione e quelli delle copie interne passano tutti dalla stessa regola.

Prova di non regressione, senza affidarsi ai numeri di programma (che slittano con i tempi di
caricamento): sono stati confrontati i testi generati dalle due build agganciando ogni programma al
digest sha256 del suo sorgente NV. Su cinque demo (Mad Mod Mike, Time Machine, Nalu, Timbury, Luna)
i testi confrontati sono 504: **501 identici bit per bit  e 3 diversi **, e i 3 diversi sono
esattamente i programmi di Mike che prima venivano rifiutati. Luna (137 programmi), Nalu (103),
Timbury (104) e Time Machine (38) non cambiano di un byte, perche' nei loro programmi le forme
`SGTR ` e `SGTXC ` scrivono in registri normali e passavano gia' dalla regola esistente.

Effetto visibile su Mad Mod Mike: la catena della carta titolo e del filmato d'apertura (programmi
con semantiche `destTexSize `, `window_params `, `mytex/take_max/g_alpha_blur `) disegnava un
pannello nero assoluto. Misura della regione della carta titolo, fotogrammi di scambio con
`WINE_NV_FSHACK=0 ` e `WINE_QPC_STEP=16666666 `, stessa sequenza di scene:

    scambio   prima (prodotto)   dopo (con la correzione)
    06        0,0000             0,6639
    08        0,0000             0,3123
    09        0,0000             0,6321
    20        0,0000             0,6774
    21        0,0000             0,6774

e in tutti gli altri scambi la regione e identica. Con gli occhi: prima un riquadro nero, dopo la
carta col marchio della demo, la fascia del nome della stanza e i fotogrammi seppia del filmato.


## `MESA_NV_PARAM_OVERRIDE` con filtro per programma (2026-11-12)

La forma storica era `MESA_NV_PARAM_OVERRIDE=<indice>:<x>,<y>,<z>,<w>` e valeva per
tutti i programmi del bersaglio che scrivevano quell'indice. Aggiunta la forma con
prefisso di id: `MESA_NV_PARAM_OVERRIDE=<id>/<indice>:<x>,<y>,<z>,<w>`; la
sovrascrittione si applica solo quando il programma associato al bersaglio ha
quell'id. Il testimone `MESA-NV OVERRIDE-PARAM` riporta sempre l'id del programma
colpito, cosi' la misura si controlla da sola.

Perche' serviva, con i numeri. Su Mad Mod Mike con i materiali originali della demo
(`args.txt` e le sue scene `quads.nma`/`cards.nma`, non quelle riadattate) il
fotogramma esce coperto per il 63,6-74,9 per cento di nero, mentre con i materiali
riadattati e al 1,0-4,4 per cento. Confrontando i disegni, le due configurazioni
differiscono di una sola coppia di programmi: con gli originali si disegna con
frammento 117 e vertice 115 per 5879 volte, con i riadattati la stessa coppia di
disegni usa vertice 113. Il programma 115 dichiara i quadranti della sfocatura del
bloom e legge il rettangolo della sorgente in c[2] (`x0y0x1y1`).

Il profilo reale di quel registro, nella nostra catena: 55 scritture con valore
(-1,1,-1,1), 7 con (0,0,0,0), 3 con (-1,0.978,-1,1). Nella traccia di riferimento lo
stesso programma (stesso id 115, stesso testo da 2030 byte) riceve 1371 scritture:
996 con (0,0,0,0), 59 con (1,1,1,1), 55 con (-1,1,-1,1). La distribuzione e'
rovesciata, e noi scriviamo quel registro 0,29 volte per fotogramma contro 2,14 del
riferimento. Manca del tutto il valore (0,0.5,0,0) che nel riferimento compare 470
volte su c[5].

Misura dell'effetto: `MESA_NV_PARAM_OVERRIDE=2:-1,-1,1,1` (forma non filtrata) porta
il nero da 63,6-74,9 a 0,8-32,9 per cento ma distrugge la geometria delle altre
passate, perche' c[2] in altri programmi contiene righe di matrice. Con la forma
filtrata `115/2:-1,-1,1,1` il nero scende a 2,7-7,4 per cento e la scena resta
corretta: il testimone riporta `associated program id=115` per tutte le otto
occorrenze mostrate. Il difetto dunque e' il contenuto di quel singolo registro, non
la presentazione, non la taglia di rendering (identico a 1280x720 in finestra, a
1280 con l'hack di presentazione e a 2560x1600 in nativo) e non i valori non finiti
(0 scritture con nan o infinito su 400000 esaminate).

Aggiunta del 2026-11-13, con la correzione di una misura. La forma applicata alla
scrittura dell'applicazione non era sempre efficace, e il testimone non lo diceva: su Mad
Mod Mike con `MESA_NV_PARAM_OVERRIDE=116/5:0,0,0,0` il testimone `OVERRIDE-PARAM` ha sparato
(ridai 11, 15, 19 e 23) mentre il censimento `MESA_NV_PARAM_AT_DRAW` della stessa corsa
leggeva ancora il valore dell'applicazione nella stessa cella, `v5=[0.324999988 ...]` in 114
delle 240 righe campionate. Motivo: con `MESA_NV_PARAM_SCOPE=ctx` (default) il registro
appartiene al contesto, non al programma, quindi una scrittura fatta mentre un altro
programma e' legato tocca la stessa cella e annulla la sovrascrittura prima del disegno. Ora
la stessa sintassi viene applicata anche al disegno, in `_mesa_nv_trace_draw`, sul magazzino
che il censimento legge davvero; il nuovo testimone e' `MESA-NV OVERRIDE-AT-DRAW frame= vp=
fp= cells=`. Dopo la correzione, a parita di sonde, il censimento della stessa cella riporta
`v5=[0 0 0 0]` in 240 righe su 240, e nel braccio di controllo senza la variabile il
 testimone `OVERRIDE-AT-DRAW` non spara per niente. Misura a confronto: 8 testimoni
`OVERRIDE-AT-DRAW` nella corsa con la variabile, 0 in quella senza.
