// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT

#ifndef XDG_PORTALS_MAC_POWER_MONITOR_H
#define XDG_PORTALS_MAC_POWER_MONITOR_H

#include <godot_cpp/classes/ref_counted.hpp>

namespace xdg_portals {

// Reads macOS Low Power Mode and reports changes to it.
//
// This is the one capability of the five that has a genuine macOS equivalent:
// -[NSProcessInfo isLowPowerModeEnabled] answers the same question as the
// portal's `power-saver-enabled` property, and
// NSProcessInfoPowerStateDidChangeNotification is a real change notification
// rather than a poll. See docs/roadmap.md for why the other four are not here.
//
// Threading
// ---------
// Nothing like the GIO backend's worker loop is needed. The notification is
// delivered on an NSOperationQueue this class owns, and the observer block
// hands the result to Godot with call_deferred(), so script code only ever sees
// the signal on the main thread. The observer is registered lazily on the first
// read and removed in the destructor.
//
// The class deliberately holds no Objective-C types in this header: it is
// included from register_types.cpp, which is plain C++.
class MacPowerMonitor : public godot::RefCounted {
	GDCLASS(MacPowerMonitor, godot::RefCounted)

public:
	MacPowerMonitor();
	~MacPowerMonitor();

	// -1 unknown, 0 disabled, 1 enabled. Matches the backend contract's
	// power_saver_state(), so the GDScript adapter needs no translation.
	int64_t power_saver_state();

protected:
	static void _bind_methods();

private:
	void start_observing();
	void emit_power_saver_changed(bool p_enabled);

	// Opaque handle to the NSObject returned by addObserverForName:, and to the
	// NSOperationQueue it is delivered on. Void so this header stays C++.
	void *observer_ = nullptr;
	void *queue_ = nullptr;
	bool observing_ = false;
};

} // namespace xdg_portals

#endif // XDG_PORTALS_MAC_POWER_MONITOR_H
