// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT

#include "xdg_portal_native.h"

#include "gvariant_conv.h"
#include "portal_constants.h"

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <chrono>

using namespace godot;

namespace xdg_portals {

namespace {

// Set XDG_PORTALS_DEBUG=1 to trace bus traffic on stderr. Diagnosing portal
// problems otherwise means guessing, because the portal service logs elsewhere.
bool debug_enabled() {
	static const bool enabled = g_getenv("XDG_PORTALS_DEBUG") != nullptr;
	return enabled;
}

#define XDGP_LOG(...)                          \
	do {                                       \
		if (debug_enabled()) {                 \
			g_printerr("[xdg_portals] " __VA_ARGS__); \
		}                                      \
	} while (0)

// One unit of work marshalled onto the worker thread.
//
// This exists because several GLib entry points capture whatever GMainContext
// is thread-default *at call time* and dispatch their work there:
// `g_dbus_connection_call()` dispatches its reply callback through it, and
// `g_dbus_connection_signal_subscribe()` resolves a well-known sender name to
// its current unique name through it. Called bare from Godot's main thread they
// attach to GLib's global default context, which nothing in a Godot process
// ever iterates — replies never arrive and subscribed signals silently never
// match their sender.
//
// Pushing the worker's context as thread-default on the main thread does not
// work either: the running GMainLoop owns that context, so the push fails
// (GLib logs `assertion 'acquired_context' failed`) and leaves the wrong
// context in place. The only correct option is to run those calls *on* the
// worker thread, where the context already is thread-default.
struct WorkerTask {
	std::function<void()> work;
	std::mutex mutex;
	std::condition_variable finished;
	bool done = false;
};

gboolean run_worker_task(gpointer p_data) {
	std::shared_ptr<WorkerTask> *task = static_cast<std::shared_ptr<WorkerTask> *>(p_data);
	(*task)->work();
	{
		std::lock_guard<std::mutex> guard((*task)->mutex);
		(*task)->done = true;
	}
	(*task)->finished.notify_all();
	return G_SOURCE_REMOVE;
}

void destroy_worker_task(gpointer p_data) {
	delete static_cast<std::shared_ptr<WorkerTask> *>(p_data);
}

// Payload handed to the async reply callback of an interactive call.
struct RequestCallContext {
	XdgPortalNative *owner = nullptr;
	String handle;
	String context;
};

// The portal spec asks clients to derive the request object path from their own
// unique bus name so they can subscribe before the call is made.
String sanitized_unique_name(GDBusConnection *p_connection) {
	const gchar *unique = g_dbus_connection_get_unique_name(p_connection);
	if (unique == nullptr) {
		return String();
	}
	String name = String::utf8(unique);
	if (name.begins_with(":")) {
		name = name.substr(1);
	}
	return name.replace(".", "_");
}

bool is_valid_scheme(const String &p_scheme) {
	if (p_scheme.is_empty()) {
		return false;
	}
	for (int i = 0; i < p_scheme.length(); i++) {
		const char32_t c = p_scheme[i];
		const bool alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
		const bool digit = c >= '0' && c <= '9';
		if (i == 0) {
			if (!alpha) {
				return false;
			}
		} else if (!alpha && !digit && c != '+' && c != '-' && c != '.') {
			return false;
		}
	}
	return true;
}

} // namespace

XdgPortalNative::XdgPortalNative() {
	if (!connect_bus()) {
		return;
	}

	// Watch the power profile monitor up front so `power_saver_state()` can stay
	// a cheap cached read instead of a bus round-trip per frame.
	const bool has_power_monitor = read_interface_version(IFACE_POWER_PROFILE_MONITOR) >= 0;
	const bool has_notifications = read_interface_version(IFACE_NOTIFICATION) >= 0;

	run_on_worker([this, has_power_monitor, has_notifications]() {
		if (has_power_monitor) {
			power_saver_subscription = g_dbus_connection_signal_subscribe(connection,
					PORTAL_BUS_NAME, IFACE_PROPERTIES, "PropertiesChanged", PORTAL_OBJECT_PATH,
					IFACE_POWER_PROFILE_MONITOR, G_DBUS_SIGNAL_FLAGS_NONE,
					&XdgPortalNative::on_properties_changed, this, nullptr);
		}
		if (has_notifications) {
			action_invoked_subscription = g_dbus_connection_signal_subscribe(connection,
					PORTAL_BUS_NAME, IFACE_NOTIFICATION, "ActionInvoked", PORTAL_OBJECT_PATH,
					nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
					&XdgPortalNative::on_action_invoked, this, nullptr);
		}
	});

	if (has_power_monitor) {
		refresh_power_saver();
	}
}

XdgPortalNative::~XdgPortalNative() {
	teardown();
}

bool XdgPortalNative::connect_bus() {
	context = g_main_context_new();
	cancellable = g_cancellable_new();

	// Creating the connection while our context is the thread-default binds all
	// of its signal dispatching to the worker thread below.
	g_main_context_push_thread_default(context);

	GError *error = nullptr;
	gchar *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, &error);
	if (address == nullptr) {
		unavailable_reason = error != nullptr
				? String::utf8(error->message)
				: String("No session bus address is available.");
		g_clear_error(&error);
		g_main_context_pop_thread_default(context);
		g_clear_object(&cancellable);
		g_main_context_unref(context);
		context = nullptr;
		return false;
	}

	connection = g_dbus_connection_new_for_address_sync(address,
			static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
					G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
			nullptr, cancellable, &error);
	g_free(address);
	g_main_context_pop_thread_default(context);

	if (connection == nullptr) {
		unavailable_reason = error != nullptr
				? String::utf8(error->message)
				: String("Could not connect to the session bus.");
		g_clear_error(&error);
		g_clear_object(&cancellable);
		g_main_context_unref(context);
		context = nullptr;
		return false;
	}

	// A dropped bus must not take the game down with it.
	g_dbus_connection_set_exit_on_close(connection, FALSE);

	loop = g_main_loop_new(context, FALSE);
	// The worker owns the context: it pushes it as thread-default so that every
	// callback dispatched from the loop sees it, and runs the loop until
	// teardown. Nothing else may push this context (see WorkerTask above).
	worker = std::thread([this]() {
		g_main_context_push_thread_default(context);
		g_main_loop_run(loop);
		g_main_context_pop_thread_default(context);
	});
	return true;
}

void XdgPortalNative::run_on_worker(std::function<void()> p_work) {
	if (context == nullptr) {
		return;
	}
	// A callback dispatched from the loop already runs on the worker.
	if (g_main_context_is_owner(context)) {
		p_work();
		return;
	}

	std::shared_ptr<WorkerTask> task = std::make_shared<WorkerTask>();
	task->work = std::move(p_work);

	// The task owns everything the callback touches, so a timed-out wait can
	// never leave the worker writing to a dead stack frame.
	g_main_context_invoke_full(context, G_PRIORITY_DEFAULT, &run_worker_task,
			new std::shared_ptr<WorkerTask>(task), &destroy_worker_task);

	std::unique_lock<std::mutex> lock(task->mutex);
	if (!task->finished.wait_for(lock, std::chrono::milliseconds(SYNC_CALL_TIMEOUT_MS),
				[&task]() { return task->done; })) {
		XDGP_LOG("timed out waiting for a worker task\n");
	}
}

void XdgPortalNative::teardown() {
	shutting_down.store(true);

	if (cancellable != nullptr) {
		g_cancellable_cancel(cancellable);
	}

	if (connection != nullptr) {
		std::lock_guard<std::mutex> guard(state_mutex);
		for (const auto &entry : request_subscriptions) {
			g_dbus_connection_signal_unsubscribe(connection, entry.second);
		}
		request_subscriptions.clear();
		if (power_saver_subscription != 0) {
			g_dbus_connection_signal_unsubscribe(connection, power_saver_subscription);
			power_saver_subscription = 0;
		}
		if (action_invoked_subscription != 0) {
			g_dbus_connection_signal_unsubscribe(connection, action_invoked_subscription);
			action_invoked_subscription = 0;
		}
	}

	if (loop != nullptr) {
		g_main_loop_quit(loop);
	}
	if (worker.joinable()) {
		worker.join();
	}
	if (loop != nullptr) {
		g_main_loop_unref(loop);
		loop = nullptr;
	}
	if (connection != nullptr) {
		g_dbus_connection_close_sync(connection, nullptr, nullptr);
		g_object_unref(connection);
		connection = nullptr;
	}
	g_clear_object(&cancellable);
	if (context != nullptr) {
		g_main_context_unref(context);
		context = nullptr;
	}
}

// --- Signal plumbing --------------------------------------------------------

void XdgPortalNative::emit_error(const String &p_context, const String &p_message) {
	call_deferred("emit_signal", "portal_error", p_context, p_message);
}

void XdgPortalNative::emit_request_completed(const String &p_handle, int p_response, const Dictionary &p_results) {
	call_deferred("emit_signal", "request_completed", p_handle, p_response, p_results);
}

// --- Discovery --------------------------------------------------------------

bool XdgPortalNative::is_available() const {
	return connection != nullptr;
}

String XdgPortalNative::get_unavailable_reason() const {
	return unavailable_reason;
}

GVariant *XdgPortalNative::call_portal_sync(const char *p_interface, const char *p_method,
		GVariant *p_params, const GVariantType *p_reply_type, const char *p_context) {
	if (connection == nullptr) {
		if (p_params != nullptr) {
			g_variant_unref(g_variant_ref_sink(p_params));
		}
		return nullptr;
	}

	GError *error = nullptr;
	GVariant *reply = g_dbus_connection_call_sync(connection, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH,
			p_interface, p_method, p_params, p_reply_type, G_DBUS_CALL_FLAGS_NONE,
			SYNC_CALL_TIMEOUT_MS, cancellable, &error);
	if (reply == nullptr) {
		if (error != nullptr) {
			emit_error(String::utf8(p_context), String::utf8(error->message));
			g_error_free(error);
		}
		return nullptr;
	}
	return reply;
}

int XdgPortalNative::read_interface_version(const char *p_interface) {
	if (connection == nullptr) {
		return -1;
	}

	// A missing interface is an expected outcome, not an error worth surfacing
	// to game code, so this does not go through `call_portal_sync`.
	GError *error = nullptr;
	GVariant *reply = g_dbus_connection_call_sync(connection, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH,
			IFACE_PROPERTIES, "Get", g_variant_new("(ss)", p_interface, "version"),
			G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, SYNC_CALL_TIMEOUT_MS, cancellable, &error);
	if (reply == nullptr) {
		g_clear_error(&error);
		return -1;
	}

	GVariant *boxed = nullptr;
	g_variant_get(reply, "(v)", &boxed);
	int version = -1;
	if (boxed != nullptr) {
		const Variant value = gvariant_to_variant(boxed);
		if (value.get_type() == Variant::INT) {
			version = static_cast<int>(static_cast<int64_t>(value));
		}
		g_variant_unref(boxed);
	}
	g_variant_unref(reply);
	return version;
}

Dictionary XdgPortalNative::get_interface_versions() {
	Dictionary versions;
	static const char *const interfaces[] = {
		IFACE_GAME_MODE,
		IFACE_INHIBIT,
		IFACE_POWER_PROFILE_MONITOR,
		IFACE_OPEN_URI,
		IFACE_NOTIFICATION,
	};
	for (const char *interface : interfaces) {
		versions[String::utf8(interface)] = read_interface_version(interface);
	}
	return versions;
}

// --- GameMode ---------------------------------------------------------------

int XdgPortalNative::game_mode_query_status(int p_pid) {
	GVariant *reply = call_portal_sync(IFACE_GAME_MODE, "QueryStatus",
			g_variant_new("(i)", static_cast<gint32>(p_pid)), G_VARIANT_TYPE("(i)"),
			"GameMode.QueryStatus");
	if (reply == nullptr) {
		return -1;
	}
	gint32 status = -1;
	g_variant_get(reply, "(i)", &status);
	g_variant_unref(reply);
	return static_cast<int>(status);
}

int XdgPortalNative::game_mode_register(int p_pid) {
	GVariant *reply = call_portal_sync(IFACE_GAME_MODE, "RegisterGame",
			g_variant_new("(i)", static_cast<gint32>(p_pid)), G_VARIANT_TYPE("(i)"),
			"GameMode.RegisterGame");
	if (reply == nullptr) {
		return -1;
	}
	gint32 result = -1;
	g_variant_get(reply, "(i)", &result);
	g_variant_unref(reply);
	return static_cast<int>(result);
}

int XdgPortalNative::game_mode_unregister(int p_pid) {
	GVariant *reply = call_portal_sync(IFACE_GAME_MODE, "UnregisterGame",
			g_variant_new("(i)", static_cast<gint32>(p_pid)), G_VARIANT_TYPE("(i)"),
			"GameMode.UnregisterGame");
	if (reply == nullptr) {
		return -1;
	}
	gint32 result = -1;
	g_variant_get(reply, "(i)", &result);
	g_variant_unref(reply);
	return static_cast<int>(result);
}

// --- Requests ---------------------------------------------------------------

String XdgPortalNative::prepare_request(String &r_token) {
	const String unique = sanitized_unique_name(connection);
	if (unique.is_empty()) {
		return String();
	}

	guint counter = 0;
	{
		std::lock_guard<std::mutex> guard(state_mutex);
		counter = ++handle_counter;
	}
	r_token = vformat("godot_xdg_%d_%d", static_cast<int64_t>(counter),
			static_cast<int64_t>(g_random_int() & 0x7fffffff));

	const String handle = "/org/freedesktop/portal/desktop/request/" + unique + "/" + r_token;
	subscribe_request(handle);
	return handle;
}

void XdgPortalNative::subscribe_request(const String &p_handle) {
	std::shared_ptr<guint> id = std::make_shared<guint>(0);
	run_on_worker([this, p_handle, id]() {
		*id = g_dbus_connection_signal_subscribe(connection, PORTAL_BUS_NAME,
				IFACE_REQUEST, "Response", p_handle.utf8().get_data(), nullptr,
				G_DBUS_SIGNAL_FLAGS_NONE, &XdgPortalNative::on_request_response, this, nullptr);
	});
	XDGP_LOG("subscribed %u to %s\n", *id, p_handle.utf8().get_data());
	if (*id == 0) {
		return;
	}
	std::lock_guard<std::mutex> guard(state_mutex);
	request_subscriptions[p_handle] = *id;
}

void XdgPortalNative::unsubscribe_request(const String &p_handle) {
	guint id = 0;
	{
		std::lock_guard<std::mutex> guard(state_mutex);
		const auto it = request_subscriptions.find(p_handle);
		if (it == request_subscriptions.end()) {
			return;
		}
		id = it->second;
		request_subscriptions.erase(it);
	}
	if (connection != nullptr) {
		g_dbus_connection_signal_unsubscribe(connection, id);
	}
}

void XdgPortalNative::call_portal_async(const char *p_interface, const char *p_method,
		GVariant *p_params, const String &p_handle, const char *p_context) {
	RequestCallContext *payload = new RequestCallContext();
	payload->owner = this;
	payload->handle = p_handle;
	payload->context = String::utf8(p_context);

	// `p_params` is floating; sink it here so it survives the hop to the worker.
	GVariant *params = g_variant_ref_sink(p_params);
	run_on_worker([this, p_interface, p_method, params, payload]() {
		g_dbus_connection_call(connection, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH, p_interface,
				p_method, params, G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE,
				SYNC_CALL_TIMEOUT_MS, cancellable, &XdgPortalNative::on_request_call_finished,
				payload);
		g_variant_unref(params);
	});
}

void XdgPortalNative::on_request_call_finished(GObject *p_source, GAsyncResult *p_result, gpointer p_user_data) {
	RequestCallContext *payload = static_cast<RequestCallContext *>(p_user_data);
	XdgPortalNative *self = payload->owner;

	GError *error = nullptr;
	GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(p_source), p_result, &error);
	XDGP_LOG("async reply for %s: %s\n", payload->handle.utf8().get_data(),
			reply != nullptr ? "ok" : (error != nullptr ? error->message : "failed"));

	if (reply == nullptr) {
		const bool cancelled = error != nullptr && g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
		if (!cancelled) {
			self->emit_error(payload->context,
					error != nullptr ? String::utf8(error->message) : String("The portal call failed."));
			// Complete the request locally: a caller waiting on `request_completed`
			// must never be stranded because the call itself failed.
			self->unsubscribe_request(payload->handle);
			self->emit_request_completed(payload->handle, 2, Dictionary());
		}
		g_clear_error(&error);
		delete payload;
		return;
	}

	// The portal is allowed to hand back a different handle than the one we
	// predicted; when it does, follow the real one instead.
	const gchar *actual = nullptr;
	g_variant_get(reply, "(&o)", &actual);
	if (actual != nullptr) {
		const String actual_handle = String::utf8(actual);
		if (actual_handle != payload->handle) {
			self->unsubscribe_request(payload->handle);
			self->subscribe_request(actual_handle);
		}
	}
	g_variant_unref(reply);
	delete payload;
}

void XdgPortalNative::on_request_response(GDBusConnection *, const gchar *, const gchar *p_path,
		const gchar *, const gchar *, GVariant *p_parameters, gpointer p_user_data) {
	XdgPortalNative *self = static_cast<XdgPortalNative *>(p_user_data);
	XDGP_LOG("Response received on %s\n", p_path);
	if (self->shutting_down.load()) {
		return;
	}

	guint32 response = 2;
	GVariant *results = nullptr;
	g_variant_get(p_parameters, "(u@a{sv})", &response, &results);

	const Dictionary payload = gvariant_dict_to_dictionary(results);
	if (results != nullptr) {
		g_variant_unref(results);
	}

	const String handle = String::utf8(p_path);
	self->unsubscribe_request(handle);
	self->emit_request_completed(handle, static_cast<int>(response), payload);
}

String XdgPortalNative::inhibit(int p_flags, const String &p_reason, const String &p_parent_window) {
	// Only the four documented bits are accepted; anything else is a caller bug
	// that would otherwise be forwarded verbatim to the portal.
	const int valid_mask = 1 | 2 | 4 | 8;
	if (connection == nullptr || p_flags <= 0 || (p_flags & ~valid_mask) != 0) {
		if (connection != nullptr) {
			emit_error("Inhibit.Inhibit", vformat("Invalid inhibit flags: %d.", p_flags));
		}
		return String();
	}

	String token;
	const String handle = prepare_request(token);
	if (handle.is_empty()) {
		return String();
	}

	GVariantBuilder options;
	g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
	g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token.utf8().get_data()));
	g_variant_builder_add(&options, "{sv}", "reason", g_variant_new_string(p_reason.utf8().get_data()));

	call_portal_async(IFACE_INHIBIT, "Inhibit",
			g_variant_new("(sua{sv})", p_parent_window.utf8().get_data(),
					static_cast<guint32>(p_flags), &options),
			handle, "Inhibit.Inhibit");
	return handle;
}

bool XdgPortalNative::close_request(const String &p_handle) {
	if (connection == nullptr || !p_handle.begins_with("/") || !g_variant_is_object_path(p_handle.utf8().get_data())) {
		return false;
	}

	GError *error = nullptr;
	GVariant *reply = g_dbus_connection_call_sync(connection, PORTAL_BUS_NAME,
			p_handle.utf8().get_data(), IFACE_REQUEST, "Close", nullptr, nullptr,
			G_DBUS_CALL_FLAGS_NONE, SYNC_CALL_TIMEOUT_MS, cancellable, &error);
	unsubscribe_request(p_handle);

	if (reply == nullptr) {
		if (error != nullptr) {
			emit_error("Request.Close", String::utf8(error->message));
			g_error_free(error);
		}
		return false;
	}
	g_variant_unref(reply);
	return true;
}

// --- PowerProfileMonitor ----------------------------------------------------

void XdgPortalNative::refresh_power_saver() {
	GError *error = nullptr;
	GVariant *reply = g_dbus_connection_call_sync(connection, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH,
			IFACE_PROPERTIES, "Get",
			g_variant_new("(ss)", IFACE_POWER_PROFILE_MONITOR, PROP_POWER_SAVER_ENABLED),
			G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, SYNC_CALL_TIMEOUT_MS, cancellable, &error);
	if (reply == nullptr) {
		g_clear_error(&error);
		return;
	}

	GVariant *boxed = nullptr;
	g_variant_get(reply, "(v)", &boxed);
	if (boxed != nullptr) {
		const Variant value = gvariant_to_variant(boxed);
		if (value.get_type() == Variant::BOOL) {
			std::lock_guard<std::mutex> guard(state_mutex);
			power_saver_known = true;
			power_saver_enabled = static_cast<bool>(value);
		}
		g_variant_unref(boxed);
	}
	g_variant_unref(reply);
}

void XdgPortalNative::on_properties_changed(GDBusConnection *, const gchar *, const gchar *,
		const gchar *, const gchar *, GVariant *p_parameters, gpointer p_user_data) {
	XdgPortalNative *self = static_cast<XdgPortalNative *>(p_user_data);
	if (self->shutting_down.load()) {
		return;
	}

	const gchar *interface_name = nullptr;
	GVariant *changed = nullptr;
	GVariant *invalidated = nullptr;
	g_variant_get(p_parameters, "(&s@a{sv}@as)", &interface_name, &changed, &invalidated);

	if (interface_name != nullptr && g_strcmp0(interface_name, IFACE_POWER_PROFILE_MONITOR) == 0 && changed != nullptr) {
		GVariant *value = g_variant_lookup_value(changed, PROP_POWER_SAVER_ENABLED, G_VARIANT_TYPE_BOOLEAN);
		if (value != nullptr) {
			const bool enabled = g_variant_get_boolean(value);
			bool changed_state = false;
			{
				std::lock_guard<std::mutex> guard(self->state_mutex);
				changed_state = !self->power_saver_known || self->power_saver_enabled != enabled;
				self->power_saver_known = true;
				self->power_saver_enabled = enabled;
			}
			if (changed_state) {
				self->call_deferred("emit_signal", "power_saver_changed", enabled);
			}
			g_variant_unref(value);
		}
	}

	if (changed != nullptr) {
		g_variant_unref(changed);
	}
	if (invalidated != nullptr) {
		g_variant_unref(invalidated);
	}
}

int XdgPortalNative::power_saver_state() {
	std::lock_guard<std::mutex> guard(state_mutex);
	if (!power_saver_known) {
		return -1;
	}
	return power_saver_enabled ? 1 : 0;
}

// --- OpenURI ----------------------------------------------------------------

String XdgPortalNative::open_uri(const String &p_uri, bool p_ask, const String &p_parent_window) {
	if (connection == nullptr) {
		return String();
	}

	const int separator = p_uri.find(":");
	if (separator <= 0) {
		emit_error("OpenURI.OpenURI", "The URI has no scheme.");
		return String();
	}
	const String scheme = p_uri.substr(0, separator);
	if (!is_valid_scheme(scheme)) {
		emit_error("OpenURI.OpenURI", vformat("Malformed URI scheme: %s.", scheme));
		return String();
	}
	// `file:` would hand out a local path descriptor; the addon never opens one.
	if (scheme.to_lower() == "file") {
		emit_error("OpenURI.OpenURI", "The file: scheme is not allowed.");
		return String();
	}

	String token;
	const String handle = prepare_request(token);
	if (handle.is_empty()) {
		return String();
	}

	GVariantBuilder options;
	g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
	g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token.utf8().get_data()));
	g_variant_builder_add(&options, "{sv}", "ask", g_variant_new_boolean(p_ask));

	call_portal_async(IFACE_OPEN_URI, "OpenURI",
			g_variant_new("(ssa{sv})", p_parent_window.utf8().get_data(),
					p_uri.utf8().get_data(), &options),
			handle, "OpenURI.OpenURI");
	return handle;
}

int XdgPortalNative::scheme_supported(const String &p_scheme) {
	if (connection == nullptr || !is_valid_scheme(p_scheme)) {
		return -1;
	}
	if (p_scheme.to_lower() == "file") {
		return 0;
	}
	if (read_interface_version(IFACE_OPEN_URI) < OPEN_URI_SCHEME_SUPPORTED_MIN_VERSION) {
		return -1;
	}

	GVariantBuilder options;
	g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
	GVariant *reply = call_portal_sync(IFACE_OPEN_URI, "SchemeSupported",
			g_variant_new("(sa{sv})", p_scheme.utf8().get_data(), &options),
			G_VARIANT_TYPE("(b)"), "OpenURI.SchemeSupported");
	if (reply == nullptr) {
		return -1;
	}
	gboolean supported = FALSE;
	g_variant_get(reply, "(b)", &supported);
	g_variant_unref(reply);
	return supported ? 1 : 0;
}

// --- Notification -----------------------------------------------------------

bool XdgPortalNative::add_notification(const String &p_id, const String &p_title,
		const String &p_body, const String &p_priority) {
	if (connection == nullptr || p_id.is_empty()) {
		return false;
	}

	GVariantBuilder notification;
	g_variant_builder_init(&notification, G_VARIANT_TYPE("a{sv}"));
	g_variant_builder_add(&notification, "{sv}", "title", g_variant_new_string(p_title.utf8().get_data()));
	if (!p_body.is_empty()) {
		g_variant_builder_add(&notification, "{sv}", "body", g_variant_new_string(p_body.utf8().get_data()));
	}
	if (!p_priority.is_empty()) {
		g_variant_builder_add(&notification, "{sv}", "priority", g_variant_new_string(p_priority.utf8().get_data()));
	}

	GVariant *reply = call_portal_sync(IFACE_NOTIFICATION, "AddNotification",
			g_variant_new("(s@a{sv})", p_id.utf8().get_data(), g_variant_builder_end(&notification)),
			nullptr, "Notification.AddNotification");
	if (reply == nullptr) {
		return false;
	}
	g_variant_unref(reply);
	return true;
}

bool XdgPortalNative::remove_notification(const String &p_id) {
	if (connection == nullptr || p_id.is_empty()) {
		return false;
	}
	GVariant *reply = call_portal_sync(IFACE_NOTIFICATION, "RemoveNotification",
			g_variant_new("(s)", p_id.utf8().get_data()), nullptr, "Notification.RemoveNotification");
	if (reply == nullptr) {
		return false;
	}
	g_variant_unref(reply);
	return true;
}

void XdgPortalNative::on_action_invoked(GDBusConnection *, const gchar *, const gchar *,
		const gchar *, const gchar *, GVariant *p_parameters, gpointer p_user_data) {
	XdgPortalNative *self = static_cast<XdgPortalNative *>(p_user_data);
	if (self->shutting_down.load()) {
		return;
	}

	const gchar *id = nullptr;
	const gchar *action = nullptr;
	GVariant *parameters = nullptr;
	g_variant_get(p_parameters, "(&s&s@av)", &id, &action, &parameters);

	Array converted;
	if (parameters != nullptr) {
		const Variant value = gvariant_to_variant(parameters);
		if (value.get_type() == Variant::ARRAY) {
			converted = value;
		}
		g_variant_unref(parameters);
	}

	self->call_deferred("emit_signal", "notification_action_invoked",
			String::utf8(id != nullptr ? id : ""), String::utf8(action != nullptr ? action : ""), converted);
}

// --- Bindings ---------------------------------------------------------------

void XdgPortalNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_available"), &XdgPortalNative::is_available);
	ClassDB::bind_method(D_METHOD("get_unavailable_reason"), &XdgPortalNative::get_unavailable_reason);
	ClassDB::bind_method(D_METHOD("get_interface_versions"), &XdgPortalNative::get_interface_versions);

	ClassDB::bind_method(D_METHOD("game_mode_query_status", "pid"), &XdgPortalNative::game_mode_query_status);
	ClassDB::bind_method(D_METHOD("game_mode_register", "pid"), &XdgPortalNative::game_mode_register);
	ClassDB::bind_method(D_METHOD("game_mode_unregister", "pid"), &XdgPortalNative::game_mode_unregister);

	ClassDB::bind_method(D_METHOD("inhibit", "flags", "reason", "parent_window"), &XdgPortalNative::inhibit);
	ClassDB::bind_method(D_METHOD("close_request", "handle"), &XdgPortalNative::close_request);

	ClassDB::bind_method(D_METHOD("power_saver_state"), &XdgPortalNative::power_saver_state);

	ClassDB::bind_method(D_METHOD("open_uri", "uri", "ask", "parent_window"), &XdgPortalNative::open_uri);
	ClassDB::bind_method(D_METHOD("scheme_supported", "scheme"), &XdgPortalNative::scheme_supported);

	ClassDB::bind_method(D_METHOD("add_notification", "id", "title", "body", "priority"),
			&XdgPortalNative::add_notification);
	ClassDB::bind_method(D_METHOD("remove_notification", "id"), &XdgPortalNative::remove_notification);

	ADD_SIGNAL(MethodInfo("power_saver_changed", PropertyInfo(Variant::BOOL, "enabled")));
	ADD_SIGNAL(MethodInfo("request_completed",
			PropertyInfo(Variant::STRING, "handle"),
			PropertyInfo(Variant::INT, "response"),
			PropertyInfo(Variant::DICTIONARY, "results")));
	ADD_SIGNAL(MethodInfo("notification_action_invoked",
			PropertyInfo(Variant::STRING, "id"),
			PropertyInfo(Variant::STRING, "action"),
			PropertyInfo(Variant::ARRAY, "parameters")));
	ADD_SIGNAL(MethodInfo("portal_error",
			PropertyInfo(Variant::STRING, "context"),
			PropertyInfo(Variant::STRING, "message")));
}

} // namespace xdg_portals
