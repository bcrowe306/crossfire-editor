#+build !darwin
package editor

// Only macOS bundles carry their own Vulkan (bundle_darwin.odin)
@(private="package")
setupBundleVulkan :: proc(contents: string) {}
