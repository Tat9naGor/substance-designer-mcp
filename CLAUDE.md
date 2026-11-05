# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this project is

An MCP integration that lets AI clients drive Adobe Substance 3D Designer: build graphs, create
and connect nodes, set parameters, build materials from recipes, and look at the result
(thumbnails + pixel statistics).

This fork: `Tat9naGor/substance-designer-mcp` (remote `origin`, push default), based on `yang1190`'s
fork (remote `yang1190`, SD 15/16, modular plugin), itself a fork of `matthieuhuguet`'s original
(remote `upstream`, SD 15). Goal of this fork: **Substance 3D Designer 14.1.1** support, keeping
15/16 behind version gates. Plan and measured facts: `docs/SD14_UPGRADE_PLAN.md`.

## Architecture

```
AI client (Claude)
   | stdio, MCP (JSON-RPC)
   v
server/sd_mcp_bridge.py      FastMCP server, started by the AI CLIENT (not by SD), uv-managed
   | TCP localhost:9881, [4-byte big-endian length][UTF-8 JSON], fresh socket per command
   v
plugin/ (package sd_mcp_plugin)   started by SD at launch from sduserplugins/
   | sd.api, always on the Qt main thread (Signal/Slot dispatch)
   v
Substance 3D Designer
```

- The tool list comes from the bridge: changing `server/sd_mcp_bridge.py` needs a restart of the
  AI client. Changing `plugin/` needs a redeploy + SD restart (no hot reload). After an SD
  restart the bridge reconnects by itself (one socket per command).
- Bridge tools are thin: `_async_send("<command>", params)`; the plugin does the work.
  Image-returning tools (`render_outputs`, `render_node_preview`) turn base64 PNGs from the
  plugin into MCP `Image` content.

### Plugin modules (`plugin/`)

| Module | Role |
|---|---|
| `__init__.py` | SD entry points (`initializeSDPlugin`), starts the TCP server |
| `transport.py` | Qt main-thread dispatcher, TCP server, Qt binding detection |
| `handler.py` | `CommandHandler`: command table, composed from the mixins below |
| `common.py` | shared imports/constants/pure helpers, `SDError`, `_sd_major()`, **`_sd_caps()`** |
| `core.py` | lookup of packages/graphs/nodes, value coercion, parameters, output usages, material model |
| `library.py` / `library_paths.py` | library node resolution by graph identifier from `<SD>/resources/packages` + custom Library folders (SD settings, `add_library_path`, `SD_MCP_LIBRARY_PATHS`) |
| `scene_tools.py` | scene / package / graph tools, `diagnostic` |
| `node_tools.py` | node / connection / parameter tools, `arrange_nodes` |
| `builders.py` | `create_batch_graph`, recipe and heightmap builders |
| `recipes.py` | 79 material recipes + 8 heightmap styles (pure data, `LIB` = `pkg:///<identifier>`) |
| `render.py` | `render_outputs`, `render_node_preview`, `export_outputs`, `validate_library`, `close_package`; pure-Python PNG encoder (no Qt) |
| `function_graphs.py` | function graphs on parameters, SDF, Shape splatter v2 (mostly SD 16) |
| `sd_documentation.py` | embedded knowledge base for `list_documentation` (`sd14_notes`, `sd16_changes`, ...) |

To add a command: method on the right mixin, entry in `handler.py` `HANDLERS`, `@mcp.tool()`
wrapper in the bridge.

## SD versions

All version-dependent behaviour goes through `common._sd_caps()`; do not add scattered
`_sd_major()` checks. Prefer feature detection (API import, library file present) where possible.

| | 14.1.1 (target) | 15.x | 16.0.x |
|---|---|---|---|
| Python / Qt | 3.11.6 / PySide6 6.5.7 | 3.11 / PySide6 | 3.13 / PySide6 6.8 |
| Output usages (`SDUsage.sNew`) | yes (probed safe) | **no: hung 15.0.3** | yes |
| Graph material model (OpenPBR) | no (API missing) | no | yes |
| SDF / 3D viewer / Shape splatter v2 | no (`3d_functions.sbs` missing) | no | yes |
| Settings folder (`*.sbsprj`) | `%LOCALAPPDATA%/Adobe/Adobe Substance 3D Designer/` (flat) | per version | `.../16.0/` |

On this machine the running SD is the **Adobe** install
(`C:\Program Files\Adobe\Adobe Substance 3D Designer`). `C:\Program Files\Allegorithmic\...` is an
old unrelated install: never read library files from it.

## Hard rules with a live SD

- **One SD tool call at a time.** Never parallel calls to the bridge.
- Unknown API behaviour can hang SD (needs a restart): probe it with `execute_sd_code` in a
  throw-away package (`pkg_mgr.newUserPackage()` ... `unloadUserPackage`), with nothing unsaved
  open in SD.
- `graph.newNode()` with an unknown definition id hangs SD: the plugin validates against
  `graph.getNodeDefinitions()`; keep it that way.
- SD API errors (`APIException`) derive from `BaseException`: catch `SDError`, not `Exception`.
- Library node outputs have per-graph names (never `unique_filter_output`): call `get_node_info`
  before connecting. `directionalwarp` warp map input is `inputintensity`.
- `arrange_nodes` may drop connections; prefer `move_node`.
- Reading a node's own texture after `compute()` is unreliable (None for isolated / freshly edited
  nodes on 14.1.1). Read textures through an **output node**: `render_outputs`, or
  `render_node_preview` (temporary output node, deleted afterwards).
- Clean up test packages (`close_package`) after experiments.

## Development commands

```powershell
# Deploy the plugin into SD (backs up the old one outside sduserplugins), then restart SD
.\scripts\deploy.ps1 -Force

# Offline tests (no SD needed; bridge tests need the `mcp` package -> run with the server venv)
python tests\test_offline.py
uv run --directory server python ..\tests\test_offline.py

# Against a live SD with the plugin loaded (plugin TCP port, no MCP client needed)
python tests\run_regression.py --quick          # ~2 min smoke test
python tests\run_regression.py                  # recipes, heightmaps, library, SD 16 features
python tests\update_port_snapshot.py            # writes tests\data\sd_node_ports_sd<major>.json (deploy first)

# Bridge by hand (normally the AI client starts it)
uv run --directory server python sd_mcp_bridge.py --port 9881
```

Deployed plugin: `%USERPROFILE%\Documents\Adobe\Adobe Substance 3D Designer\python\sduserplugins\sd_mcp_plugin\`.
The AI client's connector config must point `uv run --directory` at this repo's `server/`.

## Conventions

- Bare Python ints are treated as float parameters; pass `{"value": x, "type": "int"}` for int
  enums (e.g. `blendingmode`). Lists become float vectors; int2/3/4 only when the SD property is.
- `graph_identifier=None` means the graph currently active in SD's UI.
- Library references accepted everywhere: `perlin_noise`, `pkg:///perlin_noise`,
  `file.sbs#graph`, `D:/libs/x.sbs#graph`. `?dependency=N` URLs are session-specific.
- Branches: `branch/sd-agnostic/*` = version-independent work (upstreamable),
  `branch/sd14/*` = SD 14 specifics. Keep history linear on top of `yang1190/master`.
