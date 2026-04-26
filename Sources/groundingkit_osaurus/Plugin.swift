// SPDX-License-Identifier: MIT
//
// groundingkit-osaurus — Osaurus plugin exposing GroundingKit's VLM grounding
// to AI agents running inside Osaurus.
//
// Single tool: ground_region(image_path, prompt) → [{label, x1, y1, x2, y2}]
//
// Plugin protocol: Osaurus v1 C ABI (osaurus_plugin_entry).
// Reference: https://github.com/osaurus-ai/osaurus/blob/main/docs/PLUGIN_AUTHORING.md
// C header:  https://github.com/osaurus-ai/osaurus/blob/main/Packages/OsaurusCore/Tools/PluginABI/osaurus_plugin.h

import AppKit
import CoreGraphics
import Foundation
import GroundingKit

// MARK: - Folder context (auto-injected by Osaurus when working dir is active)

private struct FolderContext: Decodable {
    let working_directory: String
}

// MARK: - Path resolution + validation (mirrors osaurus-vision pattern)

private enum PathHelper {
    /// Resolve a possibly-relative path against the folder context's working
    /// directory. Absolute paths pass through unchanged.
    static func resolve(_ path: String, context: FolderContext?) -> String {
        guard !path.hasPrefix("/"), let workingDir = context?.working_directory else {
            return path
        }
        return "\(workingDir)/\(path)"
    }

    /// Reject paths that escape the folder context's working directory after
    /// `..` resolution. If no context, accept any absolute path (user took
    /// responsibility by not selecting a folder).
    static func validate(_ absolutePath: String, context: FolderContext?) -> Bool {
        guard let workingDir = context?.working_directory else { return true }
        return URL(fileURLWithPath: absolutePath).standardized.path.hasPrefix(workingDir)
    }
}

private func loadCGImage(at path: String) -> CGImage? {
    guard let nsImage = NSImage(contentsOfFile: path),
          let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        return nil
    }
    return cgImage
}

// MARK: - Tool input + output types

private struct GroundRegionArgs: Decodable {
    let image_path: String
    let prompt: String
    let _context: FolderContext?
}

/// Encode bounding boxes as a JSON array string for the AI to consume.
private func encodeBoxes(_ boxes: [BoundingBox]) -> String {
    let dicts: [[String: Any]] = boxes.map { box in
        [
            "label": box.label,
            "x1": box.x1,
            "y1": box.y1,
            "x2": box.x2,
            "y2": box.y2,
        ]
    }
    let payload: [String: Any] = ["regions": dicts]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{\"regions\":[]}"
}

private func errorJSON(_ message: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{\"error\": \"unknown\"}"
}

// MARK: - Lazy model loading (actor-confined; matches groundingkit-mcp pattern)

/// The Grounder is expensive to construct (loads ~6 GB of weights and compiles
/// Metal kernels). Defer construction until the first tool call so plugin
/// `init` returns instantly and the Osaurus host doesn't block at startup.
/// Wrapping inside an actor keeps the underlying MLX state confined to a
/// single isolation domain — only the Sendable result `[BoundingBox]` ever
/// crosses the boundary.
private actor GrounderHolder {
    private var instance: Grounder?

    func ground(image: CGImage, prompt: String) async throws -> [BoundingBox] {
        if instance == nil {
            instance = try await Grounder()
        }
        return try await instance!.ground(image: image, prompt: prompt)
    }
}

// MARK: - Plugin context (one per init/destroy lifecycle)

private final class PluginContext {
    let holder = GrounderHolder()

    /// Synchronous tool dispatch entry. Decodes args, resolves the image path,
    /// then bridges to the actor via Task.detached + runloop draining so the
    /// calling thread can keep its runloop alive while inference progresses.
    func invoke(toolId: String, payload: String) -> String {
        guard toolId == "ground_region" else {
            return errorJSON("Unknown tool: \(toolId)")
        }

        // Decode args
        guard let data = payload.data(using: .utf8) else {
            return errorJSON("Invalid arguments: payload is not UTF-8")
        }
        let args: GroundRegionArgs
        do {
            args = try JSONDecoder().decode(GroundRegionArgs.self, from: data)
        } catch {
            return errorJSON("Invalid arguments: \(error.localizedDescription)")
        }

        // Resolve + validate path
        let resolvedPath = PathHelper.resolve(args.image_path, context: args._context)
        guard PathHelper.validate(resolvedPath, context: args._context) else {
            return errorJSON("Path outside working directory: \(args.image_path)")
        }
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return errorJSON("Image not found: \(resolvedPath)")
        }

        // Load image
        guard let cgImage = loadCGImage(at: resolvedPath) else {
            return errorJSON("Could not decode image at \(resolvedPath) — supported formats: PNG, JPEG, TIFF, HEIF")
        }

        // Sync→async bridge with runloop draining.
        //
        // Why: Grounder's NativePanelDetector hops to MainActor for progress
        // callbacks (`await MainActor.run { onProgress?(…) }`). When invoke()
        // is called on the main thread (which the Osaurus C ABI permits, and
        // the host-harness in fact does), a naive `semaphore.wait()` would
        // block the main thread — which is the main actor's executor — and
        // every MainActor.run hop inside Grounder would deadlock.
        //
        // Solution: spin the calling thread's runloop instead of blocking it.
        // This lets MainActor-targeted blocks drain while we wait for the
        // inference Task to finish on the cooperative pool.
        nonisolated(unsafe) var outcome: Result<[BoundingBox], Error>!
        nonisolated(unsafe) var done = false

        Task.detached(priority: .userInitiated) { [holder] in
            do {
                outcome = .success(try await holder.ground(image: cgImage, prompt: args.prompt))
            } catch {
                outcome = .failure(error)
            }
            done = true
            CFRunLoopStop(CFRunLoopGetMain())
        }

        // Drain the calling thread's runloop. Returns either when the Task
        // calls CFRunLoopStop, or every 250 ms so the `done` check covers the
        // race where the Task signaled before we entered the runloop.
        while !done {
            _ = CFRunLoopRunInMode(.defaultMode, 0.25, false)
        }

        switch outcome! {
        case .success(let boxes):
            return encodeBoxes(boxes)
        case .failure(let error):
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return errorJSON("ground_region failed: \(msg)")
        }
    }
}

// MARK: - Manifest

private let manifest = """
  {
    "plugin_id": "dev.nivdvir.GroundingKit",
    "version": "0.1.0",
    "description": "On-device VLM-based screen-region grounding via Qwen2.5-VL on Apple Silicon. Returns pixel-coordinate bounding boxes for regions described in natural language.",
    "instructions": "Use ground_region when you need pixel-coordinate bounding boxes for regions of an image described in natural language. Phrasing matters: ask for `bbox_2d` JSON output explicitly and name each region. Coordinates returned are in the model's resize space (max 1280px on the longest side); multiply by `screen.width / 1280` to get screen pixels. First call loads the model (~25s); subsequent calls are fast.",
    "license": "MIT",
    "min_macos": "15.0",
    "min_osaurus": "0.5.0",
    "capabilities": {
      "tools": [
        {
          "id": "ground_region",
          "description": "Detect bounding-box regions in an image using a vision-language model (Qwen2.5-VL on Apple Silicon, via mlx-swift-lm). Returns model-coordinate bounding boxes for each named region. First call loads the model (~25s); subsequent calls are fast. Use this when you need exact pixel coordinates of regions described in natural language.",
          "parameters": {
            "type": "object",
            "properties": {
              "image_path": {
                "type": "string",
                "description": "Path to the image file (relative to working directory if folder context active, otherwise absolute). Supported: PNG, JPEG, TIFF, HEIF."
              },
              "prompt": {
                "type": "string",
                "description": "Natural-language description of regions to detect. For best results, ask for `bbox_2d` JSON output explicitly and list each region numerically. Example: \\"Detect these two UI panels and output their bbox_2d coordinates as a JSON array: 1. \\\\\\"question\\\\\\" - the panel on the left; 2. \\\\\\"editor\\\\\\" - the panel on the right.\\""
              }
            },
            "required": ["image_path", "prompt"]
          },
          "requirements": [],
          "permission_policy": "ask"
        }
      ]
    }
  }
  """

// MARK: - C ABI struct (matches osaurus_plugin.h v1 fields)

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

private struct osr_plugin_api {
    var free_string: (@convention(c) (UnsafePointer<CChar>?) -> Void)?
    var `init`: (@convention(c) () -> osr_plugin_ctx_t?)?
    var destroy: (@convention(c) (osr_plugin_ctx_t?) -> Void)?
    var get_manifest: (@convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?)?
    var invoke: (
        @convention(c) (
            osr_plugin_ctx_t?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> UnsafePointer<CChar>?
    )?
}

/// Allocate a C string the host can free via `free_string`. Uses `strdup` so
/// the bytes come from the same `malloc` heap that `free()` releases.
private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
    strdup(s).map { UnsafePointer($0) }
}

// MARK: - API instance + entry point

nonisolated(unsafe) private var api: osr_plugin_api = {
    var api = osr_plugin_api()

    api.free_string = { ptr in
        if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
    }

    api.`init` = {
        Unmanaged.passRetained(PluginContext()).toOpaque()
    }

    api.destroy = { ctxPtr in
        guard let ctxPtr else { return }
        Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
    }

    api.get_manifest = { _ in makeCString(manifest) }

    api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
        guard let ctxPtr, let typePtr, let idPtr, let payloadPtr else { return nil }

        let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let type = String(cString: typePtr)
        let id = String(cString: idPtr)
        let payload = String(cString: payloadPtr)

        guard type == "tool" else {
            return makeCString("{\"error\": \"Unknown capability type: \(type)\"}")
        }

        return makeCString(ctx.invoke(toolId: id, payload: payload))
    }

    return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
    UnsafeRawPointer(&api)
}
