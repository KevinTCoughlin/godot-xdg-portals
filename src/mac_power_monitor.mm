// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT

#include "mac_power_monitor.h"

#import <Foundation/Foundation.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable.hpp>

using namespace godot;

namespace xdg_portals {

void MacPowerMonitor::_bind_methods() {
	ClassDB::bind_method(D_METHOD("power_saver_state"), &MacPowerMonitor::power_saver_state);
	ADD_SIGNAL(MethodInfo("power_saver_changed", PropertyInfo(Variant::BOOL, "enabled")));
}

MacPowerMonitor::MacPowerMonitor() {}

MacPowerMonitor::~MacPowerMonitor() {
	// Order matters, for the same reason teardown() joins the worker in the GIO
	// backend: stop new deliveries first, then wait for any block already
	// running, so no observer can touch `this` after it is gone.
	if (observer_ != nullptr) {
		NSObject *observer = (__bridge_transfer NSObject *)observer_;
		[[NSNotificationCenter defaultCenter] removeObserver:observer];
		observer_ = nullptr;
	}
	if (queue_ != nullptr) {
		// Balances the __bridge_retained cast in start_observing().
		NSOperationQueue *queue = (__bridge_transfer NSOperationQueue *)queue_;
		[queue waitUntilAllOperationsAreFinished];
		queue_ = nullptr;
	}
	observing_ = false;
}

int64_t MacPowerMonitor::power_saver_state() {
	// isLowPowerModeEnabled is available from macOS 12; the deployment target
	// is higher than that, so no responds-to check is needed. Unlike the
	// portal, this cannot fail or time out — the value is always knowable, so
	// -1 is never returned here. The tri-state is kept anyway so the GDScript
	// adapter matches the backend contract exactly.
	start_observing();
	const BOOL enabled = [[NSProcessInfo processInfo] isLowPowerModeEnabled];
	return enabled ? 1 : 0;
}

void MacPowerMonitor::start_observing() {
	if (observing_) {
		return;
	}
	observing_ = true;

	NSOperationQueue *queue = [[NSOperationQueue alloc] init];
	queue.maxConcurrentOperationCount = 1;
	queue_ = (__bridge_retained void *)queue;

	// The block is delivered on `queue`, not the main thread, so the emission
	// is deferred rather than made directly — same rule the GIO backend follows
	// for its worker thread.
	MacPowerMonitor *self_ptr = this;
	id observer = [[NSNotificationCenter defaultCenter]
			addObserverForName:NSProcessInfoPowerStateDidChangeNotification
						object:nil
						 queue:queue
					usingBlock:^(NSNotification *) {
						const BOOL now = [[NSProcessInfo processInfo] isLowPowerModeEnabled];
						self_ptr->emit_power_saver_changed(now == YES);
					}];
	observer_ = (__bridge_retained void *)observer;
}

void MacPowerMonitor::emit_power_saver_changed(bool p_enabled) {
	call_deferred("emit_signal", "power_saver_changed", p_enabled);
}

} // namespace xdg_portals
