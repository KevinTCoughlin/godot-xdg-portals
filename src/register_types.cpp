// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT

#include "register_types.h"

#if defined(__linux__)
#include "xdg_portal_native.h"
#elif defined(__APPLE__)
#include "mac_power_monitor.h"
#endif

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

// Each platform registers only the classes it can back. A class that is absent
// simply fails the facade's ClassDB lookup, which is already how every
// unsupported platform degrades to the null backend.
void initialize_xdg_portals_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
#if defined(__linux__)
	GDREGISTER_CLASS(xdg_portals::XdgPortalNative);
#elif defined(__APPLE__)
	GDREGISTER_CLASS(xdg_portals::MacPowerMonitor);
#endif
}

void uninitialize_xdg_portals_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

GDExtensionBool GDE_EXPORT xdg_portals_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_xdg_portals_module);
	init_obj.register_terminator(uninitialize_xdg_portals_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}

} // extern "C"
