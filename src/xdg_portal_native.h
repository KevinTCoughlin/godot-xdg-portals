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
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

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
// The worker makes every signal subscription, and the portal name watch, as it
// starts: before any call can be issued, and whether or not the portal is
// running yet. Subscriptions name the portal's well-known name as sender, so
// they follow whichever process owns it.
//
// Outgoing calls are of two kinds:
//   * Non-interactive calls (property reads, GameMode, Notification, Request
//     .Close) are bounded by SYNC_CALL_TIMEOUT_MS.
//   * Interactive calls (Inhibit, OpenURI) predict their request handle and are
//     issued asynchronously. One subscription to every
//     `org.freedesktop.portal.Request::Response` from the portal routes each
//     Response to its request by object path. They never block the caller.
//
// A request always completes: with the portal's Response, or locally with
// RESPONSE_OTHER (2) when the call fails or the portal goes away first.
class XdgPortalNative : public godot::RefCounted {
	// The macro body is godot-cpp's; its generated casts are not ours to restyle.
	GDCLASS(XdgPortalNative, godot::RefCounted) // NOLINT(misc-const-correctness,modernize-use-auto)

public:
	XdgPortalNative();
	~XdgPortalNative() override;

	// --- Discovery -----------------------------------------------------------
	bool is_available() const;
	godot::String get_unavailable_reason() const;
	// Interface name -> version, or -1 when the interface is not exported.
	// Cached per portal instance; the cache is dropped when the portal restarts.
	godot::Dictionary get_interface_versions();

	// --- org.freedesktop.portal.GameMode -------------------------------------
	// Each returns the portal's own code. For QueryStatus: 0 inactive, 1 active,
	// 2 active and registered by `p_pid`, -1 failed or unknown.
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
	// An interactive request, keyed by the handle returned to the caller.
	struct Request {
		// Where the portal's Request object lives: the predicted handle until
		// the call returns, then whatever path the portal answered with.
		godot::String path;
		// The D-Bus member that started it, for error reports.
		godot::String context;
		bool is_inhibit = false;
		// An Inhibit request answered with success stays open, holding the
		// inhibition, until it is closed; it is no longer pending.
		bool answered = false;
	};

	// A Response that arrived for a path no request claims yet. It can only be
	// ours while a call is in flight, because the portal may answer on a path
	// the client learns only from that call's reply.
	struct UnclaimedResponse {
		godot::String path;
		guint32 response = 2;
		godot::Dictionary results;
	};

	// Worker-thread plumbing.
	GMainContext *context = nullptr;
	GMainLoop *loop = nullptr;
	GDBusConnection *connection = nullptr;
	GCancellable *cancellable = nullptr;
	std::thread worker;
	std::atomic<bool> shutting_down{ false };

	// Touched only on the worker thread.
	guint response_subscription = 0;
	guint power_saver_subscription = 0;
	guint action_invoked_subscription = 0;
	guint portal_name_watch = 0;

	godot::String unavailable_reason;

	// Guards everything below.
	mutable std::mutex state_mutex;
	bool power_saver_known = false;
	// Whether the state has ever been known, so a re-read after the portal
	// restarts can tell a change from a first answer.
	bool power_saver_known_once = false;
	bool power_saver_enabled = false;
	// Whether the portal name has been reported owned or unowned at least once,
	// and by whom. An empty owner means nobody owns it right now.
	bool portal_owner_seen = false;
	godot::String portal_owner;
	// Bumped on every owner change, so a read that started against one portal
	// instance cannot fill the cache for the next.
	guint64 portal_generation = 0;
	std::map<godot::String, int> cached_versions;
	std::map<godot::String, Request> requests;
	// Object path -> public handle, for routing Response signals.
	std::map<godot::String, godot::String> request_paths;
	std::deque<UnclaimedResponse> unclaimed_responses;
	int calls_in_flight = 0;
	guint handle_counter = 0;

	// Helpers.
	bool connect_bus();
	void start_worker();
	// Run on the worker as it starts and as it stops.
	void subscribe_all();
	void unsubscribe_all();
	void teardown();
	// Runs `p_work` on the worker thread, where the private GMainContext is
	// thread-default, and waits for it (bounded by SYNC_CALL_TIMEOUT_MS). Every
	// GLib call that captures the thread-default context must go through this.
	// `p_work` must own everything it touches: after a timeout it may still run
	// later, when the caller's stack frame is gone.
	void run_on_worker(std::function<void()> p_work);

	// Synchronous, bounded call against the portal object. Returns nullptr and
	// emits `portal_error` on failure.
	GVariant *call_portal_sync(const char *p_interface, const char *p_method, GVariant *p_params,
			const GVariantType *p_reply_type, const char *p_context);
	// Reads several properties in parallel, bounded by one SYNC_CALL_TIMEOUT_MS
	// for the lot. Each result is the unboxed value, owned by the caller, or
	// nullptr. `r_definitive` says, per property, whether the answer may be
	// cached: a value, or the portal saying the interface does not exist.
	std::vector<GVariant *> read_properties(const std::vector<std::pair<const char *, const char *>> &p_properties,
			std::vector<bool> &r_definitive);
	// Versions for `p_interfaces`, from the cache where possible.
	std::vector<int> read_interface_versions(const std::vector<const char *> &p_interfaces);
	int read_interface_version(const char *p_interface);

	// Predicts the handle for the next interactive request and registers it, so
	// a Response is routed to it however early it arrives.
	godot::String begin_request(godot::String &r_token, const char *p_context);
	// Fires an interactive call. On failure the request is completed locally with
	// RESPONSE_OTHER so callers are never left waiting forever.
	void call_portal_async(const char *p_interface, const char *p_method, GVariant *p_params,
			const godot::String &p_handle);
	// The two outcomes of an interactive call's reply, on the worker.
	void on_call_failed(const godot::String &p_handle, const GError *p_error);
	void on_call_started(const godot::String &p_handle, const godot::String &p_actual_path);
	// Routes a Response to its request and completes it. Returns false when no
	// request claims `p_path`.
	bool deliver_response(const godot::String &p_path, guint32 p_response, const godot::Dictionary &p_results);
	// Completes every request still waiting for a Response with RESPONSE_OTHER.
	void fail_pending_requests(const godot::String &p_reason);
	void forget_request_locked(const godot::String &p_handle);

	void apply_power_saver(bool p_enabled, bool p_from_signal);
	void refresh_power_saver_async();

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
	static void on_portal_appeared(GDBusConnection *p_connection, const gchar *p_name,
			const gchar *p_owner, gpointer p_user_data);
	static void on_portal_vanished(GDBusConnection *p_connection, const gchar *p_name, gpointer p_user_data);
	static void on_request_call_finished(GObject *p_source, GAsyncResult *p_result, gpointer p_user_data);
	static void on_power_saver_read(GObject *p_source, GAsyncResult *p_result, gpointer p_user_data);
};

} // namespace xdg_portals

#endif // XDG_PORTALS_XDG_PORTAL_NATIVE_H
