// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT

#ifndef XDG_PORTALS_XDG_PORTAL_NATIVE_H
#define XDG_PORTALS_XDG_PORTAL_NATIVE_H

#include <gio/gio.h>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

namespace xdg_portals {

// Native GIO-backed bridge to org.freedesktop.portal.Desktop.
//
// Threading model
// ---------------
// The class owns a private GDBusConnection bound to a private GMainContext that
// is driven by one worker thread. All incoming D-Bus signals are therefore
// dispatched on that worker thread and are handed to Godot with
// `call_deferred()`, so script code only ever sees them on the main thread.
//
// Outgoing calls are of two kinds:
//   * Non-interactive calls (property reads, GameMode, Notification, Request
//     .Close) are issued synchronously with a bounded timeout.
//   * Interactive calls (Inhibit, OpenURI) predict their request handle, watch
//     it for `org.freedesktop.portal.Request::Response`, and are then issued
//     asynchronously. They never block the caller.
class XdgPortalNative : public godot::RefCounted {
	GDCLASS(XdgPortalNative, godot::RefCounted)

public:
	XdgPortalNative();
	~XdgPortalNative() override;

	// --- Discovery -----------------------------------------------------------
	bool is_available() const;
	godot::String get_unavailable_reason() const;
	// Interface name -> version, or -1 when the interface is not exported.
	godot::Dictionary get_interface_versions();

	// --- org.freedesktop.portal.GameMode -------------------------------------
	int game_mode_query_status(int p_pid);
	int game_mode_register(int p_pid);
	int game_mode_unregister(int p_pid);

	// --- org.freedesktop.portal.Inhibit --------------------------------------
	// Returns the request handle, or an empty string when the call could not be
	// started at all.
	godot::String inhibit(int p_flags, const godot::String &p_reason, const godot::String &p_parent_window);
	bool close_request(const godot::String &p_handle);

	// --- org.freedesktop.portal.PowerProfileMonitor --------------------------
	// -1 unknown, 0 disabled, 1 enabled.
	int power_saver_state();

	// --- org.freedesktop.portal.OpenURI --------------------------------------
	godot::String open_uri(const godot::String &p_uri, bool p_ask, const godot::String &p_parent_window);
	// -1 unknown (interface or method unavailable), 0 unsupported, 1 supported.
	int scheme_supported(const godot::String &p_scheme);

	// --- org.freedesktop.portal.Notification ---------------------------------
	bool add_notification(const godot::String &p_id, const godot::String &p_title,
			const godot::String &p_body, const godot::String &p_priority);
	bool remove_notification(const godot::String &p_id);

protected:
	static void _bind_methods();

private:
	// Worker-thread plumbing.
	GMainContext *context = nullptr;
	GMainLoop *loop = nullptr;
	GDBusConnection *connection = nullptr;
	GCancellable *cancellable = nullptr;
	std::thread worker;
	std::atomic<bool> shutting_down{ false };

	godot::String unavailable_reason;

	// Guards `power_saver_*`, `request_subscriptions` and `handle_counter`.
	mutable std::mutex state_mutex;
	bool power_saver_known = false;
	bool power_saver_enabled = false;
	guint power_saver_subscription = 0;
	guint action_invoked_subscription = 0;
	std::map<godot::String, guint> request_subscriptions;
	guint handle_counter = 0;

	// Helpers.
	bool connect_bus();
	void teardown();
	// Runs `p_work` on the worker thread, where the private GMainContext is
	// thread-default, and waits for it (bounded by SYNC_CALL_TIMEOUT_MS). Every
	// GLib call that captures the thread-default context must go through this.
	void run_on_worker(std::function<void()> p_work);

	// Synchronous, bounded call against the portal object. Returns nullptr and
	// emits `portal_error` on failure.
	GVariant *call_portal_sync(const char *p_interface, const char *p_method, GVariant *p_params,
			const GVariantType *p_reply_type, const char *p_context);
	int read_interface_version(const char *p_interface);
	// Predicts the handle for the next interactive request and subscribes to its
	// Response signal before the call is issued, as the portal spec requires.
	godot::String prepare_request(godot::String &r_token);
	// Fires an interactive call. On failure the request is completed locally with
	// RESPONSE_OTHER so callers are never left waiting forever.
	void call_portal_async(const char *p_interface, const char *p_method, GVariant *p_params,
			const godot::String &p_handle, const char *p_context);
	void subscribe_request(const godot::String &p_handle);
	void unsubscribe_request(const godot::String &p_handle);
	void refresh_power_saver();

	void emit_error(const godot::String &p_context, const godot::String &p_message);
	void emit_request_completed(const godot::String &p_handle, int p_response, const godot::Dictionary &p_results);

	static void on_request_response(GDBusConnection *p_connection, const gchar *p_sender,
			const gchar *p_path, const gchar *p_interface, const gchar *p_signal,
			GVariant *p_parameters, gpointer p_user_data);
	static void on_properties_changed(GDBusConnection *p_connection, const gchar *p_sender,
			const gchar *p_path, const gchar *p_interface, const gchar *p_signal,
			GVariant *p_parameters, gpointer p_user_data);
	static void on_action_invoked(GDBusConnection *p_connection, const gchar *p_sender,
			const gchar *p_path, const gchar *p_interface, const gchar *p_signal,
			GVariant *p_parameters, gpointer p_user_data);
	static void on_request_call_finished(GObject *p_source, GAsyncResult *p_result, gpointer p_user_data);
};

} // namespace xdg_portals

#endif // XDG_PORTALS_XDG_PORTAL_NATIVE_H
