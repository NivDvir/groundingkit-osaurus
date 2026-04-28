// SPDX-License-Identifier: MIT
//
// HostHarness — simulates Osaurus's plugin loader without needing Osaurus
// installed. Exercises the full v1 ABI lifecycle:
//
//   dlopen → osaurus_plugin_entry → init → get_manifest → invoke → destroy
//
// Three invoke scenarios are exercised:
//   1. Unknown tool      → expect {"error": "Unknown tool: ..."}
//   2. Bad JSON payload  → expect {"error": "Invalid arguments: ..."}
//   3. Missing image     → expect {"error": "Image not found: ..."}
//
// A fourth scenario (real grounding with leetcode_test.png) is gated behind
// the GK_HARNESS_FULL=1 env var because it loads ~6 GB of weights and takes
// ~30 s. Set it when you want the end-to-end parity gate (Gate 5).
//
// Exit code: 0 on all gates passing, non-zero with diagnostic on first failure.

import Darwin
import Foundation

// MARK: - C ABI mirror (matches Plugin.swift's osr_plugin_api struct exactly)

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

private struct osr_plugin_api {
    var free_string: (@convention(c) (UnsafePointer<CChar>?) -> Void)?
    var initFn:      (@convention(c) () -> osr_plugin_ctx_t?)?
    var destroy:     (@convention(c) (osr_plugin_ctx_t?) -> Void)?
    var get_manifest:(@convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?)?
    var invoke:      (@convention(c) (
        osr_plugin_ctx_t?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>?)?
}

private typealias EntryFn = @convention(c) () -> UnsafeRawPointer?

// MARK: - Test helpers

nonisolated(unsafe) private var failed = false

private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("  ✓ \(name)")
    } else {
        print("  ✗ \(name) — \(detail)")
        failed = true
    }
}

private func cstr(_ ptr: UnsafePointer<CChar>?) -> String {
    guard let p = ptr else { return "<nil>" }
    return String(cString: p)
}

// MARK: - Resolve dylib path

let dylibPath: String = {
    // Built by `swift build -c release` from package root.
    let cwd = FileManager.default.currentDirectoryPath
    let candidates = [
        "\(cwd)/.build/release/libreticle-osaurus.dylib",
        "\(cwd)/.build/debug/libreticle-osaurus.dylib",
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        return path
    }
    print("FATAL: no dylib found. Run `swift build -c release` first.")
    print("  searched: \(candidates)")
    exit(2)
}()

print("HostHarness — loading \(dylibPath)")

// MARK: - dlopen + entry

guard let handle = dlopen(dylibPath, RTLD_NOW) else {
    print("FATAL: dlopen failed: \(String(cString: dlerror()))")
    exit(2)
}
defer { dlclose(handle) }

guard let entrySym = dlsym(handle, "osaurus_plugin_entry") else {
    print("FATAL: dlsym(osaurus_plugin_entry) failed")
    exit(2)
}
private let entry = unsafeBitCast(entrySym, to: EntryFn.self)
guard let apiRaw = entry() else {
    print("FATAL: osaurus_plugin_entry returned nil")
    exit(2)
}
private let api = apiRaw.assumingMemoryBound(to: osr_plugin_api.self).pointee

// MARK: - Gate 4a: lifecycle smoke test

print("\nGate 4a — lifecycle smoke test")
check("init present",         api.initFn != nil)
check("destroy present",      api.destroy != nil)
check("get_manifest present", api.get_manifest != nil)
check("invoke present",       api.invoke != nil)
check("free_string present",  api.free_string != nil)

guard let ctx = api.initFn?() else {
    print("FATAL: init returned nil ctx")
    exit(2)
}
check("init returned non-nil ctx", true)

// MARK: - Gate 4b: get_manifest

print("\nGate 4b — manifest extraction")
guard let manifestPtr = api.get_manifest?(ctx) else {
    print("FATAL: get_manifest returned nil")
    api.destroy?(ctx)
    exit(2)
}
let manifestStr = cstr(manifestPtr)
api.free_string?(manifestPtr)

let manifestData = manifestStr.data(using: .utf8) ?? Data()
let manifestJSON = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
check("manifest is valid JSON", manifestJSON != nil)
check("plugin_id matches",
      (manifestJSON?["plugin_id"] as? String) == "dev.nivdvir.Reticle",
      "got \(manifestJSON?["plugin_id"] ?? "<nil>")")
check("version matches",
      (manifestJSON?["version"] as? String) == "0.1.0")
let tools = (manifestJSON?["capabilities"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
check("exactly 1 tool", tools.count == 1, "got \(tools.count)")
check("tool[0].id == ground_region", (tools.first?["id"] as? String) == "ground_region")

// MARK: - Gate 4c: invoke error paths (no model load)

print("\nGate 4c — invoke error paths")

func invokeAndDecode(type: String, id: String, payload: String) -> [String: Any]? {
    return type.withCString { typePtr in
        id.withCString { idPtr in
            payload.withCString { payloadPtr in
                guard let resultPtr = api.invoke?(ctx, typePtr, idPtr, payloadPtr) else {
                    return nil
                }
                let result = cstr(resultPtr)
                api.free_string?(resultPtr)
                let data = result.data(using: .utf8) ?? Data()
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
    }
}

// Scenario 1: unknown tool id
let r1 = invokeAndDecode(type: "tool", id: "nonexistent_tool", payload: "{}")
check("unknown tool returns error",
      (r1?["error"] as? String)?.contains("Unknown tool") == true,
      "got \(r1 ?? [:])")

// Scenario 2: invalid JSON payload
let r2 = invokeAndDecode(type: "tool", id: "ground_region", payload: "{not json")
check("bad JSON returns error",
      (r2?["error"] as? String)?.contains("Invalid arguments") == true,
      "got \(r2 ?? [:])")

// Scenario 3: missing image file (won't load model — fails at file-exists check)
let r3 = invokeAndDecode(
    type: "tool",
    id: "ground_region",
    payload: #"{"image_path":"/nonexistent/path/to/image.png","prompt":"x"}"#
)
check("missing image returns error",
      (r3?["error"] as? String)?.contains("Image not found") == true,
      "got \(r3 ?? [:])")

// Scenario 4: unknown capability type
let r4 = invokeAndDecode(type: "resource", id: "anything", payload: "{}")
check("unknown capability type returns error",
      (r4?["error"] as? String)?.contains("Unknown capability type") == true,
      "got \(r4 ?? [:])")

// MARK: - Batch mode (opt-in): drive multiple inferences in one process
//
// Set GK_HARNESS_BATCH=path1,path2,path3 + GK_HARNESS_PROMPT to drive N
// inferences with the model loaded only once. Each result is printed as
// `__BATCH__ <path> <regions-json>` so a parent process can grep+parse.
// Used by the GIF demo in scripts/build-demo-gif.sh.

if let batch = ProcessInfo.processInfo.environment["GK_HARNESS_BATCH"], !batch.isEmpty {
    print("\nBatch mode — driving \(batch.split(separator: ",").count) inferences")
    let prompt = ProcessInfo.processInfo.environment["GK_HARNESS_PROMPT"]
        ?? #"Detect these two regions and output their bbox_2d coordinates as a JSON array: 1. "title" - the article title heading; 2. "article" - the main article body text column."#
    for path in batch.split(separator: ",").map(String.init) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let payload = ["image_path": trimmed, "prompt": prompt]
        let payloadStr = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let start = Date()
        let r = invokeAndDecode(type: "tool", id: "ground_region", payload: payloadStr)
        let elapsed = Date().timeIntervalSince(start)
        let regionsData = try! JSONSerialization.data(withJSONObject: r?["regions"] ?? [])
        let regionsJSON = String(data: regionsData, encoding: .utf8) ?? "[]"
        print("__BATCH__ \(trimmed) \(regionsJSON)")
        print("  → \(String(format: "%.1f", elapsed)) s")
    }
    api.destroy?(ctx)
    exit(0)
}

// MARK: - Gate 5 (opt-in): real grounding

if ProcessInfo.processInfo.environment["GK_HARNESS_FULL"] == "1" {
    print("\nGate 5 — real grounding (loads ~6 GB model, takes ~30 s)")

    let imagePath = ProcessInfo.processInfo.environment["GK_HARNESS_IMAGE"]
        ?? "/tmp/native_vlm_input.png"
    let prompt = ProcessInfo.processInfo.environment["GK_HARNESS_PROMPT"]
        ?? #"Detect these two UI panels and output their bbox_2d coordinates as a JSON array: 1. "question" - the panel on the left; 2. "editor" - the panel on the right."#

    guard FileManager.default.fileExists(atPath: imagePath) else {
        print("  ✗ test image missing: \(imagePath)")
        print("    set GK_HARNESS_IMAGE=/path/to/test.png to override")
        failed = true
        api.destroy?(ctx)
        exit(failed ? 1 : 0)
    }

    let payload: [String: Any] = ["image_path": imagePath, "prompt": prompt]
    let payloadData = try! JSONSerialization.data(withJSONObject: payload)
    let payloadStr = String(data: payloadData, encoding: .utf8)!

    let start = Date()
    let r5 = invokeAndDecode(type: "tool", id: "ground_region", payload: payloadStr)
    let elapsed = Date().timeIntervalSince(start)

    print("  invoke took \(String(format: "%.1f", elapsed)) s")
    check("response is dict", r5 != nil)
    check("response has no error key", r5?["error"] == nil, "got \(r5?["error"] ?? "")")
    let regions = r5?["regions"] as? [[String: Any]] ?? []
    check("regions array present", r5?["regions"] != nil)
    check("≥1 region returned", regions.count >= 1, "got \(regions.count)")
    if let first = regions.first {
        let hasAllKeys = ["label", "x1", "y1", "x2", "y2"].allSatisfy { first[$0] != nil }
        check("region[0] has label/x1/y1/x2/y2", hasAllKeys, "got keys \(first.keys.sorted())")
    }
    print("  full response: \(r5 ?? [:])")
} else {
    print("\nGate 5 — skipped (set GK_HARNESS_FULL=1 to run real grounding)")
}

// MARK: - Cleanup

print("\nGate 4d — destroy")
api.destroy?(ctx)
print("  ✓ destroy returned (no crash)")

print("\n\(failed ? "FAILED" : "PASSED")")
exit(failed ? 1 : 0)
