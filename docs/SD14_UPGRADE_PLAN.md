# Plan: Substance 3D Designer 14.1.1 support

Base: `branch/sd-agnostic/render_node_preview` (from `yang1190/master`, itself a fork of
`matthieuhuguet/substance-designer-mcp`). Target runtime: **Adobe Substance 3D Designer 14.1.1**
(Python 3.11.6, PySide6 6.5.7, `C:\Program Files\Adobe\Adobe Substance 3D Designer`).

## Facts established (measured, not assumed)

| Fact | Evidence |
|---|---|
| Running SD is the Adobe install, `app.getVersion()` = `14.1.1`, Python 3.11.6, PySide6 6.5.7 | `sys.executable` / process path inside SD |
| `C:\Program Files\Allegorithmic\...` is an old unrelated install: ignore it | its library has different names, Qt5 |
| SD 14 library = 501 `.sbs`, 802 graph identifiers in `resources/packages` | scan of `<graph><identifier>` |
| All 23 `LIB` identifiers used by the recipes exist in SD 14 | diff of `recipes.py` LIB vs. library |
| Only the user package is loaded via `getPackages()`: library packages must be loaded on demand | `get_library_nodes` returned 0 on the original plugin |
| Reading a node's own texture after `compute()` is unreliable on 14.1.1; a graph **output node** always has one | probes on RockTest/ShotTest |
| `SDTexture.getPixelBufferAddress()` read works on 14.1.1 (RGBA8 verified) | exact colour round trip |
| Original plugin set graph size "relative to parent" (8192x8192 instead of 512) | observed; yang1190 fixes it (Absolute) |

## What this changes vs. the first plan

- No library renaming table is needed. The old "blur_hq vs blur_hq_grayscale" worry came from
  looking at the wrong install.
- yang1190 resolves library nodes by identifier from `<SD>/resources/packages`, which is exactly
  what SD 14 needs. Expected work is *verification and gating*, not a rewrite.
- Python/Qt are the same generation as SD 16 (3.11 + PySide6), so no Qt5 shim.

## Hard rules while testing on the live SD (from CLAUDE.md, SD 15 findings)

One SD tool call at a time. Never `SDUsage.sNew()` (hung SD 15.0.3; unknown on 14.1.1) and never
`newNode()` with an unvalidated definition id. `arrange_nodes` may drop connections. Save work
before every experiment that could hang SD.

## Phases

### Phase 0: Baseline and deployment (needs the user: SD restart)
1. Back up `Documents\Adobe\Adobe Substance 3D Designer\python\sduserplugins\sd_mcp_plugin\`.
2. Add `deploy.ps1`: copies `plugin/` -> `sduserplugins/sd_mcp_plugin/` (whole package, not three
   files), prints the SD version it finds, refuses to overwrite without `-Force`.
3. Restart SD, check `get_scene_info` reports `sd_version 14.1.1` and the plugin version.
4. Check the bridge (`uv sync`, `uv run python sd_mcp_bridge.py --port 9881`) and the MCP config.

Done when: all existing read-only tools answer on 14.1.1.

**Status: done (2026-11-05).** Plugin 3.10.1 loads on 14.1.1; bridge runs from this repo
(Claude connector config). Verified end to end: `list_library_paths` (771 graphs found),
`get_library_nodes`, `create_instance_node('perlin_noise')`, `render_node_preview` and
`render_outputs` (LUM16 read, absolute 2048 size, thumbnails as images).
Findings for later phases:
- `list_library_paths`: `sd_settings_dir` is null, so SD 14's own Library watched paths are not
  read (Phase 2).
- Output nodes on 14 get no usages and keep identifier `output` (usages gated to 16+), so the 3D
  view will not pick them up (Phase 1: decide how to set usage/identifier on 14).

### Phase 1: Version gates (`plugin/common.py::_sd_major`)
Today the code branches on `>= 16` only. Introduce one capability layer instead of scattered
checks:
`CAPS = {usages, openpbr, function_graphs, sdf, absolute_size, ...}` computed from the version,
plus `SD_MCP_FORCE_*` env overrides (already exists for usages).
- Decide per capability for **14**: `usages` (unknown: probe only on a throw-away SD session, since
  it hung 15.0.3), OpenPBR/function graphs/SDF = off (SD 16 features, tools return a clear
  "requires SD 16+" error).
- Add the 14 row to `sd_documentation.py` (version notes) and to each tool docstring that is
  SD16-only.

Done when: SD16-only tools fail with a readable message on 14, never hang or crash.

**Status: done (2026-11-05), branch `branch/sd14/phase1-version-gates`.**
- `common._sd_caps()`: `output_usages` on 14 and 16+ (off on 15), `material_model` on 16+;
  `SD_MCP_FORCE_USAGES=1/0` overrides. Function graphs / SDF stay detected at call time (already
  readable errors on 14).
- Probed on 14.1.1 in a throw-away package: `SDUsage.sNew()` does not hang; usages + identifier
  write and read back. Through the tools: `create_output_node` sets usage, outputs are named
  `height` / `basecolor`.
- The output identifier is now set even without usages (would affect SD 15, untested there).
- On 14: `list_material_models` -> `supported: false`, `list_sdf_functions` -> "SD 16+ required",
  `list_function_nodes` works (function graph API exists; `build_function_graph` for pixel
  processors still to verify in Phase 3/4).
- Offline tests for the caps table and the PNG encoder; `sd14_notes` in the knowledge base.

### Phase 2: Library resolution on 14
1. Run `validate_library` in batches (offset/limit) on 14.1.1: every identifier instantiates.
2. Fix library root detection if `<SD>` path detection assumes the 15/16 layout
   (`library_paths.py`), including the "Adobe Substance 3D Designer" folder name.
3. Check `get_library_nodes`, `create_instance_node` by identifier / `pkg:///id`.

Done when: `validate_library` reports 0 failures (or a documented known-broken list).

**Status: done (2026-11-05), branch `branch/sd14/phase2-library`.**
- `validate_library(source="builtin")` on 14.1.1: 475/475 visible graphs instantiate, 0 failures,
  ~95 s total; no packages left behind.
- `get_library_nodes` and `create_instance_node('perlin_noise')` verified in Phase 0.
- Fix: `library_paths.sd_settings_dir` now finds SD 14's flat settings folder
  (`%LOCALAPPDATA%/Adobe/Adobe Substance 3D Designer/*.sbsprj`, no `<major.minor>` subfolder).
  Checked inside the running SD: settings dir found, watched paths read from
  `default_project.sbsprj`, built-in root not duplicated. Custom Library folders from SD
  Preferences will now be picked up (none configured at the moment). Offline test added.
- `list_library_paths` through the tool shows the fix only after an SD restart (plugin deployed).

### Phase 3: Regression on 14 (the real work)
1. Run `tests/run_regression.py`: 79 recipes + 8 heightmaps + library + performance.
2. Save the result as `tests/regression_baseline_sd14.json` (the existing baseline is SD 16.0.5;
   make the runner pick the file by SD major).
3. Triage failures into: (a) port/param id differences in SD 14 library graphs -> regenerate the
   snapshot with `update_port_snapshot.py` on 14, (b) API differences -> gates, (c) recipes that
   cannot work on 14 -> mark KNOWN with a reason.
4. Use `render_outputs` / `render_node_preview` as the oracle: no recipe may produce flat output
   unless it is in the KNOWN list.

Done when: failing set is explained and frozen in the 14 baseline.

### Phase 4: Previews (already started)
Done: `render_node_preview` (temp output node), Qt-free PNG encoder, SD 14 pixel-buffer read.
Todo: end-to-end through the bridge after Phase 0; optional `max_size` for `export_outputs`;
check the open-in-editor requirement (probes ran on an open graph); 16-bit and float formats on 14.

### Phase 5: Cleanup and trimming (decision for the user)
Keep SD 16 code gated (small diff against upstream, easy to merge yang1190 updates) or delete it
(smaller fork). Recommendation: keep, gated, until Phase 3 is green.

### Phase 6: Docs, tests, packaging
- README: "SD 14.1.1" section (install path, tested versions), CLAUDE.md: replace SD 15-only
  statements, record the two-installs pitfall.
- Offline tests (`tests/test_offline.py`, stdlib) run in CI-like fashion: add tests for the
  version-gate table and the PNG encoder.
- CHANGELOG entry per phase.

## Branch layout
- `branch/sd-agnostic/*`: version-independent improvements (previews, PNG encoder, gates).
  Candidates for an upstream PR to yang1190 / the original.
- `branch/sd14/*`: 14-only fixes and the 14 baseline.
- Merge `yang1190/master` periodically (`git fetch yang1190`).

## Risks
| Risk | Mitigation |
|---|---|
| A call hangs SD 14 (unknown API behaviour) | save first, one call at a time, probe unknowns in a throw-away package |
| `SDUsage` behaviour on 14 unknown | keep off by default on 14; test only deliberately |
| Library path detection differs | `SD_MCP_LIBRARY_PATHS` env var as fallback |
| Upstream (yang1190) keeps changing | small gated diff, regular fetch/merge |
