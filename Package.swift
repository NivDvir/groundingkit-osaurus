// swift-tools-version: 6.0
//
// reticle-osaurus — Osaurus plugin exposing Reticle's VLM-based
// screen-region grounding to AI agents running inside Osaurus.
//
// Single tool: ground_region(image_path, prompt) → [{label, x1, y1, x2, y2}]
//
// Plugin protocol: Osaurus v1 C ABI (osaurus_plugin_entry).
// Distribution: dynamic library (.dylib), packaged as
//   `dev.nivdvir.Reticle-<version>.zip` for local install.
//
// Stack:
//   • screen-overlay-toolkit (Grounder library) — patched mlx-swift-lm fork;
//     will become NivDvir/reticle after repo rename
//   • macOS 15+ (matches osaurus-vision and Osaurus's plugin SDK requirement)
//   • Swift 6.0+ (strict concurrency for safe sync→async bridging)

import PackageDescription

let package = Package(
    name: "reticle-osaurus",
    platforms: [.macOS(.v15)],
    products: [
        // type: .dynamic produces a .dylib that Osaurus can dlopen.
        // Default (.static) produces a .a archive — wrong shape.
        .library(name: "reticle-osaurus", type: .dynamic, targets: ["reticle_osaurus"]),
        // Test harness — simulates Osaurus's plugin loader so we can verify
        // the full lifecycle (init/manifest/invoke/destroy) without needing
        // Osaurus installed on the dev machine.
        .executable(name: "host-harness", targets: ["HostHarness"]),
    ],
    dependencies: [
        // Pinned to the SHA where Grounder became @unchecked Sendable; bump
        // when a tagged release is available.
        .package(
            url: "https://github.com/NivDvir/screen-overlay-toolkit.git",
            revision: "cf7ef6c9487d61d0af9023a1639c96043582c648"
        ),
    ],
    targets: [
        .target(
            name: "reticle_osaurus",
            dependencies: [
                .product(name: "Reticle", package: "screen-overlay-toolkit"),
            ],
            path: "Sources/reticle_osaurus"
        ),
        .executableTarget(
            name: "HostHarness",
            path: "Tests/HostHarness"
        ),
    ]
)
