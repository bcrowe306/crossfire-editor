#+build darwin
package crossfire_editor

import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"

// SDL loads the bundle's Vulkan loader, and the loader finds the bundle's MoltenVK (bundle.odin)
@(private="package")
setupBundleVulkan :: proc(contents: string) {
	loader := filepath.join({contents, "Frameworks", "libvulkan.1.dylib"}, context.temp_allocator) or_else ""
	if os.exists(loader) do sdl.SetHint(sdl.HINT_VULKAN_LIBRARY, strings.clone_to_cstring(loader, context.temp_allocator))
	driver := filepath.join({contents, "Resources", "vulkan", "icd.d", "MoltenVK_icd.json"}, context.temp_allocator) or_else ""
	if os.exists(driver) && os.get_env("VK_DRIVER_FILES", context.temp_allocator) == "" && os.get_env("VK_ICD_FILENAMES", context.temp_allocator) == "" {
		_ = os.set_env("VK_DRIVER_FILES", driver)
		_ = os.set_env("VK_ICD_FILENAMES", driver)
	}
}
