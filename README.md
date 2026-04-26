# groundingkit-osaurus

[Osaurus](https://osaurus.ai) plugin that exposes on-device VLM-based screen-region grounding to AI agents — built on top of [GroundingKit](https://github.com/NivDvir/screen-overlay-toolkit), native Swift Qwen2.5-VL inference on Apple Silicon with no Python in the inference path.

## What it does

Adds one tool to your Osaurus AI agents:

```
ground_region(image_path: string, prompt: string)
  → [{label, x1, y1, x2, y2}, ...]
```

Pass a path to a local PNG/JPEG and a natural-language prompt; get back model-coordinate bounding boxes for each named region.

Examples of what an Osaurus AI agent can do once this plugin is installed:

- *"Find the OK button in this screenshot and tell me its bounding box."*
- *"In this LeetCode page, where exactly is the question panel and where is the editor?"*
- *"What's the bbox of the main article column on this Wikipedia page, excluding the sidebar?"*

## Requirements

- **Apple Silicon Mac**, macOS 15+
- [Osaurus](https://osaurus.ai) 0.5.0+
- ~6 GB of disk for `mlx-community/Qwen2.5-VL-7B-Instruct-4bit` weights (auto-downloaded on first use; or pre-fetch via `huggingface-cli download mlx-community/Qwen2.5-VL-7B-Instruct-4bit`)
- Swift 6.0+ (Xcode 16+) to build from source

## Install

### Option 1 — Developer hot-reload (`osaurus tools dev`)

If you have Osaurus installed and the `osaurus` CLI in your `PATH`:

```bash
git clone https://github.com/NivDvir/groundingkit-osaurus.git
cd groundingkit-osaurus
osaurus tools dev
```

This builds the plugin in release mode, installs it to `~/.osaurus/Tools/dev.nivdvir.GroundingKit/0.1.0/`, launches Osaurus, and reloads the plugin on every source change.

### Option 2 — Manual local install

Build the plugin and copy it into Osaurus's tools directory:

```bash
git clone https://github.com/NivDvir/groundingkit-osaurus.git
cd groundingkit-osaurus
bash scripts/package.sh
mkdir -p ~/.osaurus/Tools/dev.nivdvir.GroundingKit/0.1.0
unzip -o dist/dev.nivdvir.GroundingKit-0.1.0.zip -d ~/.osaurus/Tools/
```

Restart Osaurus. The `ground_region` tool appears in your agents' available-tools list.

### Option 3 — Central registry (deferred)

Distribution via Osaurus's central registry requires `codesign` + `minisign` artifact signing. Out of scope for v0.1; planned for v0.2+.

## Use a different model

The default model is `mlx-community/Qwen2.5-VL-7B-Instruct-4bit`. To swap in any Qwen2.5-VL-architecture derivative (UI-TARS-1.5-7B is verified):

```bash
# When launching Osaurus from the command line:
GK_MODEL=mlx-community/UI-TARS-1.5-7B-4bit open -a Osaurus
```

If you launch Osaurus normally (Finder), set the env var via `launchctl setenv` before launching, or use a wrapper script.

## How fast is it?

| Call | Latency |
|---|---|
| First `ground_region` call per Osaurus session | ~25 s (model cold load + Metal kernel compile + first inference) |
| Subsequent calls | ~5–18 s per inference (depends on image resolution) |

The model loads lazily on the first tool invocation, so plugin startup itself is fast — the latency is per-Osaurus-session, not per-restart.

## Verifying the install

After installing, ask Claude (via Osaurus): *"Use ground_region to find the title in `/path/to/some/screenshot.png`."* You should see the tool appear in the tool-execution timeline; the first call will take ~25 s, subsequent ones much less.

## How it works

```
Osaurus app
    └─ dlopen(libgroundingkit_osaurus.dylib)
        └─ osaurus_plugin_entry()
            └─ get_manifest() / invoke()
                └─ Grounder (Swift SDK from screen-overlay-toolkit)
                    └─ mlx-swift-lm (patched fork — see PRs #222, #242, #243)
                        └─ Qwen2.5-VL-7B-4bit (Metal kernels via MLX)
```

## Why this exists

Osaurus's existing `osaurus-vision` plugin wraps Apple's classic `Vision.framework` (OCR, face detection, barcodes, body pose) — pre-AI-era CV primitives. There was no plugin for **semantic VLM grounding** ("where is the X on this screen?"). This plugin fills that gap using the same on-device, no-cloud, native-Swift posture as the rest of the Osaurus ecosystem.

## License

MIT — see [LICENSE](LICENSE).

## Tool contract

This plugin implements the [GroundingKit ecosystem `ground_region` tool spec](https://github.com/NivDvir/screen-overlay-toolkit/blob/main/docs/ECOSYSTEM_SPEC.md) — same tool name, input schema, and output shape as `groundingkit-mcp`. Agents that work with one will work with the other.

## Related

- [GroundingKit](https://github.com/NivDvir/screen-overlay-toolkit) — the underlying Swift library and consumer macOS overlay app
- [Ecosystem spec](https://github.com/NivDvir/screen-overlay-toolkit/blob/main/docs/ECOSYSTEM_SPEC.md) — canonical `ground_region` contract for all adapters
- [groundingkit-mcp](https://github.com/NivDvir/groundingkit-mcp) — same `ground_region` capability exposed via Model Context Protocol (for Claude Desktop, Cursor, Cline, etc.)
- [mlx-swift-lm PR #222](https://github.com/ml-explore/mlx-swift-lm/pull/222) — upstream Qwen2.5-VL fixes that make this possible
- [Osaurus Plugin Authoring docs](https://github.com/osaurus-ai/osaurus/blob/main/docs/PLUGIN_AUTHORING.md)
