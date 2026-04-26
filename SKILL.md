---
name: groundingkit
description: Use when you need exact pixel-coordinate bounding boxes for regions of an image described in natural language. Works on screenshots, photos, and rasterized PDFs. Local on Apple Silicon, no cloud, no Python.
metadata:
  author: NivDvir
  version: "1.0.0"
---

# GroundingKit Visual Grounding

Use the `ground_region` tool when you need pixel-coordinate bounding boxes for regions of an image described in natural language. Common use cases:

- "Where is the [button/panel/section] in this screenshot?" → `ground_region(image_path, "the OK button at the bottom of the dialog")`
- "Find each panel in this UI" → ask for multiple regions in one prompt with a numbered list
- "What's the bounding box for the article body?" → `ground_region(image_path, "the main article content area, excluding the sidebar")`

## Prompt patterns that work

The underlying model is Qwen2.5-VL (or a derivative — UI-TARS works too). It responds best to prompts that:

1. **Ask for `bbox_2d` explicitly.** "Detect X and output its bbox_2d coordinates as a JSON array."
2. **List regions numerically.** When detecting multiple regions, number them: `1. "label" - description`.
3. **Be concrete.** "the panel on the left" works better than "the question area".

Example successful prompt:

```
Detect these two UI panels and output their bbox_2d coordinates as a JSON array:
1. "question" - the problem description panel on the left
2. "editor" - the code editor panel on the right
```

## Coordinate system

Returned coordinates are in the model's RESIZE space, NOT raw screen pixels. The longest side of the input image is capped at 1280 px and snapped to multiples of 28 (the patch grid Qwen2.5-VL was trained on). To project back to screen pixels:

    screen_x = model_x * (screen_width / 1280)

For most use cases (the AI is identifying a region to crop or highlight), the model-coordinate output is good enough — scale as needed when acting on it.

## Performance

- **First call: ~25 s** (model load + Metal kernel compile + first inference). Tell the user this happens on first use; subsequent calls are fast.
- **Subsequent calls: ~5–18 s per inference** depending on image resolution.

The plugin loads the model lazily, so this 25 s latency hits only the FIRST `ground_region` call per Osaurus session.

## Limitations

- Model weights (~6 GB) must be pre-downloaded to `~/.cache/huggingface/hub/`. If missing, the tool returns an error explaining how to fetch them.
- Apple Silicon Mac required (Metal/MLX dependency).
- Returned coordinates are model-space; project to screen-space if needed.
- One image per call (no batch yet).
- One process loads the model fully into RAM (~6 GB Qwen2.5-VL-7B-4bit, more for larger variants).

## When NOT to use this tool

- Pure OCR ("what does the text say?") — use osaurus-vision's `detect_text` instead, much faster and lower memory.
- Face / barcode detection — use osaurus-vision primitives.
- Generic image classification ("what is this?") — use a chat-completion model with the image attached.

`ground_region` is specifically for: "GIVE ME COORDINATES of the region described as X". Anything that isn't bbox-shaped output is the wrong tool.
