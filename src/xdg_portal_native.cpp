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

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

using namespace godot;

namespace xdg_portals {

namespace {

// Set XDG_PORTALS_DEBUG=1 to trace bus traffic on stderr. Diagnosing portal
// problems otherwise means guessing, because the portal service logs elsewhere.
bool debug_enabled() {
	static const bool enabled = g_getenv("XDG_PORTALS_DEBUG") != nullptr;
	return enabled;
}

#define XDGP_LOG(...)                                 \
	do {                                              \
		if (debug_enabled()) {                        \
			g_printerr("[xdg_portals] " __VA_ARGS__); \
		}                                             \
	} while (0)

// Response code used whenever a request ends without the portal's answer.
constexpr guint32 RESPONSE_OTHER = 2;

// The interfaces whose version is reported by get_interface_versions().
constexpr std::array<const char *, 5> PORTAL_INTERFACES = {
	IFACE_GAME_MODE,
	IFACE_INHIBIT,
	IFACE_POWER_PROFILE_MONITOR,
	IFACE_OPEN_URI,
	IFACE_NOTIFICATION,
};

// Responses held while waiting for a call's reply to name their path. Real
// portals answer on the predicted path, so this only fills when a portal
// answers on a different one faster than its own reply is dispatched; the cap
// keeps other clients' Responses, which a path-less subscription also sees,
// from accumulating.
constexpr std::size_t MAX_UNCLAIMED_RESPONSES = 32;

// Bounds the final drain of the worker's context at teardown. Each iteration
// dispatches one batch of ready sources; a few suffice in practice.
constexpr int MAX_DRAIN_ITERATIONS = 1000;

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
	const auto *task = static_cast<std::shared_ptr<WorkerTask> *>(p_data);
	(*task)->work();
	{
		const std::scoped_lock guard((*task)->mutex);
		(*task)->done = true;
	}
	(*task)->finished.notify_all();
	return G_SOURCE_REMOVE;
}

// Also runs for a task that never ran because the context was torn down first:
// destroying the std::function then releases whatever it captured.
void destroy_worker_task(gpointer p_data) {
	delete static_cast<std::shared_ptr<WorkerTask> *>(p_data);
}

// Payload handed to the async reply callback of an interactive call.
struct RequestCallContext {
	XdgPortalNative *owner = nullptr;
	String handle;
};

struct VariantUnref {
	void operator()(GVariant *p_variant) const { g_variant_unref(p_variant); }
};
using VariantPtr = std::unique_ptr<GVariant, VariantUnref>;

// An interactive call waiting to be issued on the worker. Owns its parameters
// and reply payload until the call takes them, so a task that is dropped
// unrun at teardown leaks neither.
struct PendingCall {
	VariantPtr params;
	std::unique_ptr<RequestCallContext> payload;
};

// Results of a parallel property read. Shared between the waiting caller and
// the reply callbacks, so a caller that gave up never leaves a callback
// writing to freed memory, and a late value is freed with the batch.
struct PropertyBatch {
	std::mutex mutex;
	std::condition_variable finished;
	std::vector<VariantPtr> values;
	std::vector<bool> definitive;
	std::size_t remaining = 0;
};

struct PropertyRead {
	std::shared_ptr<PropertyBatch> batch;
	std::size_t index = 0;
};

// Whether a failed property read is the portal's own answer that the property
// does not exist — worth caching — rather than a timeout or a missing service.
bool is_definitive_absence(const GError *p_error) {
	return p_error != nullptr && p_error->domain == G_DBUS_ERROR &&
			(p_error->code == G_DBUS_ERROR_INVALID_ARGS ||
					p_error->code == G_DBUS_ERROR_UNKNOWN_INTERFACE ||
					p_error->code == G_DBUS_ERROR_UNKNOWN_PROPERTY ||
					p_error->code == G_DBUS_ERROR_UNKNOWN_METHOD ||
					p_error->code == G_DBUS_ERROR_UNKNOWN_OBJECT);
}

void on_property_read(GObject *p_source, GAsyncResult *p_result, gpointer p_user_data) {
	const std::unique_ptr<PropertyRead> read(static_cast<PropertyRead *>(p_user_data));

	GError *error = nullptr;
	GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(p_source), p_result, &error);
	GVariant *value = nullptr;
	bool definitive = false;
	if (reply != nullptr) {
		g_variant_get(reply, "(v)", &value);
		g_variant_unref(reply);
		definitive = true;
	} else {
		definitive = is_definitive_absence(error);
		g_clear_error(&error);
	}

	{
		const std::scoped_lock guard(read->batch->mutex);
		read->batch->values[read->index].reset(value);
		read->batch->definitive[read->index] = definitive;
		read->batch->remaining--;
	}
	read->batch->finished.notify_all();
}

// Outcome of the bounded asynchronous bus connection in connect_bus().
struct ConnectAttempt {
	GDBusConnection *connection = nullptr;
	GError *error = nullptr;
	bool done = false;
};

void on_bus_connected(GObject * /*p_source*/, GAsyncResult *p_result, gpointer p_user_data) {
	const std::unique_ptr<std::shared_ptr<ConnectAttempt>> attempt(
			static_cast<std::shared_ptr<ConnectAttempt> *>(p_user_data));
	(*attempt)->connection = g_dbus_connection_new_for_address_finish(p_result, &(*attempt)->error);
	(*attempt)->done = true;
}

gboolean set_flag(gpointer p_data) {
	*static_cast<bool *>(p_data) = true;
	return G_SOURCE_REMOVE;
}

// Iterates `p_context` until `p_attempt` is done or `p_timeout_ms` passes.
void iterate_until_done(GMainContext *p_context, const ConnectAttempt &p_attempt, guint p_timeout_ms) {
	bool timed_out = false;
	GSource *timer = g_timeout_source_new(p_timeout_ms);
	g_source_set_callback(timer, &set_flag, &timed_out, nullptr);
	g_source_attach(timer, p_context);
	while (!p_attempt.done && !timed_out) {
		g_main_context_iteration(p_context, TRUE);
	}
	g_source_destroy(timer);
	g_source_unref(timer);
}

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
	start_worker();

	// One parallel read seeds the power-saver state and the version cache, so
	// startup costs at most one timeout however many reads are slow, and the
	// facade's first capability refresh is answered from the cache.
	std::vector<std::pair<const char *, const char *>> properties;
	properties.emplace_back(IFACE_POWER_PROFILE_MONITOR, PROP_POWER_SAVER_ENABLED);
	for (const char *interface : PORTAL_INTERFACES) {
		properties.emplace_back(interface, "version");
	}
	guint64 generation = 0;
	{
		const std::scoped_lock guard(state_mutex);
		generation = portal_generation;
	}
	std::vector<bool> definitive;
	std::vector<GVariant *> values = read_properties(properties, definitive);

	bool power_known = false;
	if (values[0] != nullptr) {
		if (g_variant_is_of_type(values[0], G_VARIANT_TYPE_BOOLEAN)) {
			apply_power_saver(g_variant_get_boolean(values[0]), false);
			power_known = true;
		}
		g_variant_unref(values[0]);
	}
	{
		const std::scoped_lock guard(state_mutex);
		for (std::size_t i = 1; i < values.size(); i++) {
			int version = -1;
			if (values[i] != nullptr) {
				const Variant converted = gvariant_to_variant(values[i]);
				if (converted.get_type() == Variant::INT) {
					version = static_cast<int>(static_cast<int64_t>(converted));
				}
				g_variant_unref(values[i]);
			}
			if (definitive[i] && generation == portal_generation) {
				cached_versions[String::utf8(PORTAL_INTERFACES[i - 1])] = version;
			}
		}
	}

	// A portal that is still starting may not have answered in time. Ask again
	// without waiting; the answer is applied whenever it comes.
	if (!power_known) {
		run_on_worker([this]() { refresh_power_saver_async(); });
	}
}

XdgPortalNative::~XdgPortalNative() {
	teardown();
}

bool XdgPortalNative::connect_bus() {
	context = g_main_context_new();
	cancellable = g_cancellable_new();

	GError *error = nullptr;
	gchar *address = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, nullptr, &error);
	if (address == nullptr) {
		unavailable_reason = error != nullptr
				? String::utf8(error->message)
				: String("No session bus address is available.");
		g_clear_error(&error);
		g_clear_object(&cancellable);
		g_main_context_unref(context);
		context = nullptr;
		return false;
	}

	// Creating the connection while our context is the thread-default binds all
	// of its signal dispatching to the worker thread started below. The worker
	// is not running yet, so pushing it here is safe (see WorkerTask above).
	g_main_context_push_thread_default(context);

	// A synchronous connect has no timeout: a bus that accepts the socket and
	// then never answers the handshake would hang the game at startup. Connect
	// asynchronously and iterate the context ourselves, bounded.
	//
	// GDBusConnectionFlags is a bit-flag enum, so an OR of two flags is valid
	// even though no single enumerator equals it. GLib before 2.88 does not mark
	// it G_GNUC_FLAG_ENUM (Ubuntu 24.04 ships 2.80), and without that the
	// analyzer cannot tell.
	const auto attempt = std::make_shared<ConnectAttempt>();
	g_dbus_connection_new_for_address(address,
			static_cast<GDBusConnectionFlags>(G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | // NOLINT(clang-analyzer-optin.core.EnumCastOutOfRange)
					G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION),
			nullptr, cancellable, &on_bus_connected, new std::shared_ptr<ConnectAttempt>(attempt));
	g_free(address);

	iterate_until_done(context, *attempt, CONNECT_TIMEOUT_MS);
	if (!attempt->done) {
		// Cancelling unblocks the handshake; give the cancellation a moment to
		// be delivered so nothing is left running against our context.
		g_cancellable_cancel(cancellable);
		iterate_until_done(context, *attempt, CONNECT_CANCEL_GRACE_MS);
	}
	g_main_context_pop_thread_default(context);

	if (!attempt->done || attempt->connection == nullptr) {
		const bool timed_out = !attempt->done || g_cancellable_is_cancelled(cancellable);
		if (timed_out) {
			unavailable_reason = vformat("Timed out connecting to the session bus after %d ms.",
					CONNECT_TIMEOUT_MS);
		} else {
			unavailable_reason = attempt->error != nullptr
					? String::utf8(attempt->error->message)
					: String("Could not connect to the session bus.");
		}
		g_clear_error(&attempt->error);
		// If the attempt never finished, GLib still holds a task bound to this
		// context; its reference keeps the context alive, never iterated, and
		// the attempt is abandoned with it.
		g_clear_object(&cancellable);
		g_main_context_unref(context);
		context = nullptr;
		return false;
	}

	connection = attempt->connection;
	attempt->connection = nullptr;

	// A dropped bus must not take the game down with it.
	g_dbus_connection_set_exit_on_close(connection, FALSE);
	return true;
}

void XdgPortalNative::start_worker() {
	loop = g_main_loop_new(context, FALSE);
	// The worker owns the context: it pushes it as thread-default so that every
	// callback dispatched from the loop sees it, and runs the loop until
	// teardown. Nothing else may push this context (see WorkerTask above).
	worker = std::thread([this]() {
		g_main_context_push_thread_default(context);
		// Before the loop runs, so no call made through run_on_worker() can
		// overtake the subscriptions it depends on.
		subscribe_all();
		g_main_loop_run(loop);
		unsubscribe_all();
		// Closing here, with the context still current, lets the cancelled and
		// failed calls it causes be delivered by the drain below.
		g_dbus_connection_close_sync(connection, nullptr, nullptr);
		// Deliver what is still queued: replies to cancelled calls free their
		// payloads, and worker tasks that never ran release what they captured.
		for (int i = 0; i < MAX_DRAIN_ITERATIONS && g_main_context_iteration(context, FALSE); i++) {
		}
		g_main_context_pop_thread_default(context);
	});
}

void XdgPortalNative::subscribe_all() {
	// Every Response from the portal, whatever its path. Subscribing per path
	// cannot work for a portal that answers on a path other than the one
	// predicted: the client learns that path from the call's reply, and a match
	// rule added then can be overtaken by a Response sent straight after it.
	response_subscription = g_dbus_connection_signal_subscribe(connection, PORTAL_BUS_NAME,
			IFACE_REQUEST, "Response", nullptr, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
			&XdgPortalNative::on_request_response, this, nullptr);
	// Made unconditionally, not only when the interface answered at startup: a
	// portal that was slow or not yet running then would otherwise never be
	// listened to.
	power_saver_subscription = g_dbus_connection_signal_subscribe(connection,
			PORTAL_BUS_NAME, IFACE_PROPERTIES, "PropertiesChanged", PORTAL_OBJECT_PATH,
			IFACE_POWER_PROFILE_MONITOR, G_DBUS_SIGNAL_FLAGS_NONE,
			&XdgPortalNative::on_properties_changed, this, nullptr);
	action_invoked_subscription = g_dbus_connection_signal_subscribe(connection,
			PORTAL_BUS_NAME, IFACE_NOTIFICATION, "ActionInvoked", PORTAL_OBJECT_PATH,
			nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
			&XdgPortalNative::on_action_invoked, this, nullptr);
	// Tells a portal that crashed or restarted apart from one that is just quiet.
	portal_name_watch = g_bus_watch_name_on_connection(connection, PORTAL_BUS_NAME,
			G_BUS_NAME_WATCHER_FLAGS_NONE, &XdgPortalNative::on_portal_appeared,
			&XdgPortalNative::on_portal_vanished, this, nullptr);
	XDGP_LOG("subscribed: response %u, power %u, action %u, watch %u\n", response_subscription,
			power_saver_subscription, action_invoked_subscription, portal_name_watch);
}

void XdgPortalNative::unsubscribe_all() {
	for (guint *id : { &response_subscription, &power_saver_subscription, &action_invoked_subscription }) {
		if (*id != 0) {
			g_dbus_connection_signal_unsubscribe(connection, *id);
			*id = 0;
		}
	}
	if (portal_name_watch != 0) {
		g_bus_unwatch_name(portal_name_watch);
		portal_name_watch = 0;
	}
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
	{
		const std::scoped_lock guard(state_mutex);
		requests.clear();
		request_paths.clear();
		unclaimed_responses.clear();
		cached_versions.clear();
	}
	if (connection != nullptr) {
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
	if (shutting_down.load()) {
		return;
	}
	call_deferred("emit_signal", "portal_error", p_context, p_message);
}

void XdgPortalNative::emit_request_completed(const String &p_handle, int p_response, const Dictionary &p_results) {
	if (shutting_down.load()) {
		return;
	}
	call_deferred("emit_signal", "request_completed", p_handle, p_response, p_results);
}

// --- Portal lifecycle -------------------------------------------------------

void XdgPortalNative::on_portal_appeared(GDBusConnection * /*p_connection*/, const gchar * /*p_name*/,
		const gchar *p_owner, gpointer p_user_data) {
	auto *self = static_cast<XdgPortalNative *>(p_user_data);
	if (self->shutting_down.load()) {
		return;
	}
	const String owner = String::utf8(p_owner);
	bool replaced = false;
	{
		const std::scoped_lock guard(self->state_mutex);
		// The first report is the portal as found at startup; the constructor
		// has already read its state. Any later owner is a new instance.
		replaced = self->portal_owner_seen && self->portal_owner != owner;
		self->portal_owner_seen = true;
		self->portal_owner = owner;
		if (replaced) {
			self->portal_generation++;
			self->cached_versions.clear();
		}
	}
	XDGP_LOG("portal owned by %s%s\n", p_owner, replaced ? " (new instance)" : "");
	if (replaced) {
		// Requests are per instance: whatever the old one had not answered, it
		// never will.
		self->fail_pending_requests("The portal service was replaced before answering.");
		self->refresh_power_saver_async();
	}
}

void XdgPortalNative::on_portal_vanished(GDBusConnection * /*p_connection*/, const gchar * /*p_name*/,
		gpointer p_user_data) {
	auto *self = static_cast<XdgPortalNative *>(p_user_data);
	if (self->shutting_down.load()) {
		return;
	}
	bool was_owned = false;
	{
		const std::scoped_lock guard(self->state_mutex);
		was_owned = !self->portal_owner.is_empty();
		self->portal_owner_seen = true;
		self->portal_owner = String();
		self->portal_generation++;
		self->cached_versions.clear();
		// Nobody is left to report the state; it is unknown until a portal is.
		self->power_saver_known = false;
	}
	XDGP_LOG("portal name has no owner%s\n", was_owned ? " (it went away)" : "");
	if (was_owned) {
		self->fail_pending_requests("The portal service went away before answering.");
	}
}

void XdgPortalNative::fail_pending_requests(const String &p_reason) {
	std::vector<std::pair<String, String>> failed;
	{
		const std::scoped_lock guard(state_mutex);
		for (const auto &entry : requests) {
			if (!entry.second.answered) {
				failed.emplace_back(entry.first, entry.second.context);
			}
		}
		// Answered Inhibit requests are dropped too: their Request objects died
		// with the old instance, and the inhibitions with them.
		requests.clear();
		request_paths.clear();
		unclaimed_responses.clear();
	}
	for (const auto &request : failed) {
		XDGP_LOG("failing %s: %s\n", request.first.utf8().get_data(), p_reason.utf8().get_data());
		emit_error(request.second, p_reason);
		emit_request_completed(request.first, static_cast<int>(RESPONSE_OTHER), Dictionary());
	}
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

std::vector<GVariant *> XdgPortalNative::read_properties(
		const std::vector<std::pair<const char *, const char *>> &p_properties, std::vector<bool> &r_definitive) {
	r_definitive.assign(p_properties.size(), false);
	std::vector<GVariant *> values(p_properties.size(), nullptr);
	if (connection == nullptr || p_properties.empty()) {
		return values;
	}

	const auto batch = std::make_shared<PropertyBatch>();
	batch->values.resize(p_properties.size());
	batch->definitive.assign(p_properties.size(), false);
	batch->remaining = p_properties.size();
	// Copied into the task: it may run after this frame has returned.
	run_on_worker([this, batch, properties = p_properties]() {
		for (std::size_t i = 0; i < properties.size(); i++) {
			g_dbus_connection_call(connection, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH, IFACE_PROPERTIES,
					"Get", g_variant_new("(ss)", properties[i].first, properties[i].second),
					G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, SYNC_CALL_TIMEOUT_MS, cancellable,
					&on_property_read, new PropertyRead{ batch, i });
		}
	});

	// Each call carries its own SYNC_CALL_TIMEOUT_MS, so in the normal case
	// every one has answered or failed by then. The margin covers dispatch.
	std::unique_lock<std::mutex> lock(batch->mutex);
	if (!batch->finished.wait_for(lock, std::chrono::milliseconds(SYNC_CALL_TIMEOUT_MS + 250),
				[&batch]() { return batch->remaining == 0; })) {
		XDGP_LOG("timed out waiting for %zu property read(s)\n", batch->remaining);
	}
	// Take what has arrived; anything later is freed with the batch.
	for (std::size_t i = 0; i < values.size(); i++) {
		values[i] = batch->values[i].release();
		r_definitive[i] = batch->definitive[i];
	}
	return values;
}

std::vector<int> XdgPortalNative::read_interface_versions(const std::vector<const char *> &p_interfaces) {
	std::vector<int> versions(p_interfaces.size(), -1);
	if (connection == nullptr) {
		return versions;
	}

	std::vector<std::size_t> missing;
	guint64 generation = 0;
	{
		const std::scoped_lock guard(state_mutex);
		generation = portal_generation;
		for (std::size_t i = 0; i < p_interfaces.size(); i++) {
			const auto it = cached_versions.find(String::utf8(p_interfaces[i]));
			if (it != cached_versions.end()) {
				versions[i] = it->second;
			} else {
				missing.push_back(i);
			}
		}
	}
	if (missing.empty()) {
		return versions;
	}

	// A missing interface is an expected outcome, not an error worth surfacing
	// to game code, so these reads do not emit `portal_error`.
	std::vector<std::pair<const char *, const char *>> properties;
	properties.reserve(missing.size());
	for (const std::size_t index : missing) {
		properties.emplace_back(p_interfaces[index], "version");
	}
	std::vector<bool> definitive;
	std::vector<GVariant *> values = read_properties(properties, definitive);

	const std::scoped_lock guard(state_mutex);
	for (std::size_t i = 0; i < missing.size(); i++) {
		int version = -1;
		if (values[i] != nullptr) {
			const Variant converted = gvariant_to_variant(values[i]);
			if (converted.get_type() == Variant::INT) {
				version = static_cast<int>(static_cast<int64_t>(converted));
			}
			g_variant_unref(values[i]);
		}
		versions[missing[i]] = version;
		// Only an answer from the instance the read started against is cached;
		// a timeout is not an answer.
		if (definitive[i] && generation == portal_generation) {
			cached_versions[String::utf8(p_interfaces[missing[i]])] = version;
		}
	}
	return versions;
}

int XdgPortalNative::read_interface_version(const char *p_interface) {
	return read_interface_versions({ p_interface })[0];
}

Dictionary XdgPortalNative::get_interface_versions() {
	const std::vector<const char *> interfaces(PORTAL_INTERFACES.begin(), PORTAL_INTERFACES.end());
	const std::vector<int> versions = read_interface_versions(interfaces);
	Dictionary result;
	for (std::size_t i = 0; i < interfaces.size(); i++) {
		result[String::utf8(interfaces[i])] = versions[i];
	}
	return result;
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

String XdgPortalNative::begin_request(String &r_token, const char *p_context) {
	const String unique = sanitized_unique_name(connection);
	if (unique.is_empty()) {
		return String();
	}

	const std::scoped_lock guard(state_mutex);
	const guint counter = ++handle_counter;
	r_token = vformat("godot_xdg_%d_%d", static_cast<int64_t>(counter),
			static_cast<int64_t>(g_random_int() & 0x7fffffff));
	const String handle = "/org/freedesktop/portal/desktop/request/" + unique + "/" + r_token;

	Request request;
	request.path = handle;
	request.context = String::utf8(p_context);
	request.is_inhibit = g_strcmp0(p_context, "Inhibit.Inhibit") == 0;
	requests[handle] = request;
	request_paths[handle] = handle;
	calls_in_flight++;
	return handle;
}

void XdgPortalNative::forget_request_locked(const String &p_handle) {
	const auto it = requests.find(p_handle);
	if (it == requests.end()) {
		return;
	}
	request_paths.erase(it->second.path);
	request_paths.erase(p_handle);
	requests.erase(it);
}

void XdgPortalNative::call_portal_async(const char *p_interface, const char *p_method,
		GVariant *p_params, const String &p_handle) {
	const auto call = std::make_shared<PendingCall>();
	// `p_params` is floating; sink it here so it survives the hop to the worker.
	call->params.reset(g_variant_ref_sink(p_params));
	call->payload = std::make_unique<RequestCallContext>();
	call->payload->owner = this;
	call->payload->handle = p_handle;

	run_on_worker([this, p_interface, p_method, call]() {
		// The call takes the payload; the parameters are released with `call`.
		g_dbus_connection_call(connection, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH, p_interface,
				p_method, call->params.get(), G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE,
				SYNC_CALL_TIMEOUT_MS, cancellable, &XdgPortalNative::on_request_call_finished,
				call->payload.release());
	});
}

void XdgPortalNative::on_request_call_finished(GObject *p_source, GAsyncResult *p_result, gpointer p_user_data) {
	const std::unique_ptr<RequestCallContext> payload(static_cast<RequestCallContext *>(p_user_data));

	GError *error = nullptr;
	GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(p_source), p_result, &error);
	if (reply == nullptr) {
		XDGP_LOG("async call for %s failed: %s\n", payload->handle.utf8().get_data(),
				error != nullptr ? error->message : "?");
		payload->owner->on_call_failed(payload->handle, error);
		g_clear_error(&error);
		return;
	}

	const gchar *actual = nullptr;
	g_variant_get(reply, "(&o)", &actual);
	const String actual_path = String::utf8(actual != nullptr ? actual : "");
	g_variant_unref(reply);
	XDGP_LOG("async reply for %s: %s\n", payload->handle.utf8().get_data(), actual_path.utf8().get_data());
	payload->owner->on_call_started(payload->handle, actual_path);
}

void XdgPortalNative::on_call_failed(const String &p_handle, const GError *p_error) {
	bool owned = false;
	String call_context;
	{
		const std::scoped_lock guard(state_mutex);
		calls_in_flight--;
		// The request may already be gone: completed by a portal restart, or
		// forgotten at teardown.
		const auto it = requests.find(p_handle);
		owned = it != requests.end();
		if (owned) {
			call_context = it->second.context;
		}
		forget_request_locked(p_handle);
		if (calls_in_flight == 0) {
			unclaimed_responses.clear();
		}
	}
	const bool cancelled = p_error != nullptr && g_error_matches(p_error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
	if (!owned || cancelled) {
		return;
	}
	emit_error(call_context, p_error != nullptr ? String::utf8(p_error->message) : String("The portal call failed."));
	// Complete the request locally: a caller waiting on `request_completed`
	// must never be stranded because the call itself failed.
	emit_request_completed(p_handle, static_cast<int>(RESPONSE_OTHER), Dictionary());
}

void XdgPortalNative::on_call_started(const String &p_handle, const String &p_actual_path) {
	// The portal is allowed to hand back a different handle than the one we
	// predicted. Record the real path first, then drop the predicted one, so
	// there is never a moment when neither routes to the request.
	UnclaimedResponse early;
	bool answered_early = false;
	{
		const std::scoped_lock guard(state_mutex);
		calls_in_flight--;
		const auto it = requests.find(p_handle);
		if (it != requests.end() && !p_actual_path.is_empty() && p_actual_path != it->second.path) {
			request_paths[p_actual_path] = p_handle;
			request_paths.erase(it->second.path);
			it->second.path = p_actual_path;
		}
		// A Response on that path may have overtaken this reply.
		for (auto pending = unclaimed_responses.begin(); pending != unclaimed_responses.end(); ++pending) {
			if (pending->path == p_actual_path) {
				early = *pending;
				answered_early = true;
				unclaimed_responses.erase(pending);
				break;
			}
		}
		if (calls_in_flight == 0) {
			unclaimed_responses.clear();
		}
	}
	if (answered_early) {
		XDGP_LOG("delivering an early Response on %s\n", early.path.utf8().get_data());
		deliver_response(early.path, early.response, early.results);
	}
}

bool XdgPortalNative::deliver_response(const String &p_path, guint32 p_response, const Dictionary &p_results) {
	String handle;
	{
		const std::scoped_lock guard(state_mutex);
		const auto path = request_paths.find(p_path);
		if (path == request_paths.end()) {
			return false;
		}
		handle = path->second;
		const auto it = requests.find(handle);
		if (it == requests.end() || it->second.answered) {
			return true;
		}
		if (it->second.is_inhibit && p_response == 0) {
			// The inhibition lasts until the request is closed, so keep the
			// path that close_request() needs.
			it->second.answered = true;
		} else {
			forget_request_locked(handle);
		}
	}
	emit_request_completed(handle, static_cast<int>(p_response), p_results);
	return true;
}

void XdgPortalNative::on_request_response(GDBusConnection * /*p_connection*/, const gchar * /*p_sender*/,
		const gchar *p_path, const gchar * /*p_interface*/, const gchar * /*p_signal*/, GVariant *p_parameters,
		gpointer p_user_data) {
	auto *self = static_cast<XdgPortalNative *>(p_user_data);
	XDGP_LOG("Response received on %s\n", p_path);
	if (self->shutting_down.load()) {
		return;
	}
	if (!g_variant_is_of_type(p_parameters, G_VARIANT_TYPE("(ua{sv})"))) {
		return;
	}

	guint32 response = RESPONSE_OTHER;
	GVariant *results = nullptr;
	g_variant_get(p_parameters, "(u@a{sv})", &response, &results);
	const Dictionary payload = gvariant_dict_to_dictionary(results);
	if (results != nullptr) {
		g_variant_unref(results);
	}

	const String path = String::utf8(p_path);
	if (self->deliver_response(path, response, payload)) {
		return;
	}

	// Not ours yet, and perhaps never: this subscription also sees other
	// clients' Responses. Hold it only while one of our calls could still name
	// this path.
	const std::scoped_lock guard(self->state_mutex);
	if (self->calls_in_flight > 0) {
		if (self->unclaimed_responses.size() >= MAX_UNCLAIMED_RESPONSES) {
			self->unclaimed_responses.pop_front();
		}
		self->unclaimed_responses.push_back(UnclaimedResponse{ path, response, payload });
	}
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
	String handle = begin_request(token, "Inhibit.Inhibit");
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
			handle);
	return handle;
}

bool XdgPortalNative::close_request(const String &p_handle) {
	if (connection == nullptr || !p_handle.begins_with("/") || !g_variant_is_object_path(p_handle.utf8().get_data())) {
		return false;
	}

	String actual_path = p_handle;
	{
		const std::scoped_lock guard(state_mutex);
		const auto it = requests.find(p_handle);
		if (it != requests.end()) {
			actual_path = it->second.path;
		}
	}
	GError *error = nullptr;
	GVariant *reply = g_dbus_connection_call_sync(connection, PORTAL_BUS_NAME,
			actual_path.utf8().get_data(), IFACE_REQUEST, "Close", nullptr, nullptr,
			G_DBUS_CALL_FLAGS_NONE, SYNC_CALL_TIMEOUT_MS, cancellable, &error);

	if (reply == nullptr) {
		if (error != nullptr) {
			emit_error("Request.Close", String::utf8(error->message));
			g_error_free(error);
		}
		return false;
	}
	g_variant_unref(reply);
	// A closed request emits no Response, by specification.
	const std::scoped_lock guard(state_mutex);
	forget_request_locked(p_handle);
	return true;
}

// --- PowerProfileMonitor ----------------------------------------------------

void XdgPortalNative::apply_power_saver(bool p_enabled, bool p_from_signal) {
	bool emit = false;
	{
		const std::scoped_lock guard(state_mutex);
		// A change notification is reported even when the previous state was
		// unknown. A re-read is reported only when it differs from the last
		// value we had, so a restarted portal does not produce a phantom change.
		emit = p_from_signal ? (!power_saver_known || power_saver_enabled != p_enabled)
							 : (power_saver_known_once && power_saver_enabled != p_enabled);
		power_saver_known = true;
		power_saver_known_once = true;
		power_saver_enabled = p_enabled;
	}
	if (emit && !shutting_down.load()) {
		call_deferred("emit_signal", "power_saver_changed", Variant(p_enabled));
	}
}

void XdgPortalNative::refresh_power_saver_async() {
	// Runs on the worker, so the reply is dispatched there. `this` outlives the
	// call: teardown cancels it and drains the reply before anything is freed.
	g_dbus_connection_call(connection, PORTAL_BUS_NAME, PORTAL_OBJECT_PATH, IFACE_PROPERTIES, "Get",
			g_variant_new("(ss)", IFACE_POWER_PROFILE_MONITOR, PROP_POWER_SAVER_ENABLED),
			G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, SYNC_CALL_TIMEOUT_MS, cancellable,
			&XdgPortalNative::on_power_saver_read, this);
}

void XdgPortalNative::on_power_saver_read(GObject *p_source, GAsyncResult *p_result, gpointer p_user_data) {
	auto *self = static_cast<XdgPortalNative *>(p_user_data);
	GError *error = nullptr;
	GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(p_source), p_result, &error);
	if (reply == nullptr) {
		XDGP_LOG("power-saver re-read failed: %s\n", error != nullptr ? error->message : "?");
		g_clear_error(&error);
		return;
	}
	GVariant *value = nullptr;
	g_variant_get(reply, "(v)", &value);
	if (value != nullptr) {
		if (g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN) && !self->shutting_down.load()) {
			self->apply_power_saver(g_variant_get_boolean(value), false);
		}
		g_variant_unref(value);
	}
	g_variant_unref(reply);
}

void XdgPortalNative::on_properties_changed(GDBusConnection * /*p_connection*/, const gchar * /*p_sender*/,
		const gchar * /*p_path*/, const gchar * /*p_interface*/, const gchar * /*p_signal*/,
		GVariant *p_parameters, gpointer p_user_data) {
	auto *self = static_cast<XdgPortalNative *>(p_user_data);
	if (self->shutting_down.load()) {
		return;
	}
	if (!g_variant_is_of_type(p_parameters, G_VARIANT_TYPE("(sa{sv}as)"))) {
		return;
	}

	const gchar *interface_name = nullptr;
	GVariant *changed = nullptr;
	GVariant *invalidated = nullptr;
	g_variant_get(p_parameters, "(&s@a{sv}@as)", &interface_name, &changed, &invalidated);

	if (interface_name != nullptr && g_strcmp0(interface_name, IFACE_POWER_PROFILE_MONITOR) == 0 && changed != nullptr) {
		GVariant *value = g_variant_lookup_value(changed, PROP_POWER_SAVER_ENABLED, G_VARIANT_TYPE_BOOLEAN);
		if (value != nullptr) {
			self->apply_power_saver(g_variant_get_boolean(value), true);
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
	const std::scoped_lock guard(state_mutex);
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

	const int64_t separator = p_uri.find(":");
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
	String handle = begin_request(token, "OpenURI.OpenURI");
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
			handle);
	return handle;
}

int XdgPortalNative::scheme_supported(const String &p_scheme) {
	if (connection == nullptr || !is_valid_scheme(p_scheme)) {
		return -1;
	}
	if (p_scheme.to_lower() == "file") {
		return 0;
	}
	// Cached: this used to cost a bus round-trip per call.
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

void XdgPortalNative::on_action_invoked(GDBusConnection * /*p_connection*/, const gchar * /*p_sender*/,
		const gchar * /*p_path*/, const gchar * /*p_interface*/, const gchar * /*p_signal*/,
		GVariant *p_parameters, gpointer p_user_data) {
	auto *self = static_cast<XdgPortalNative *>(p_user_data);
	if (self->shutting_down.load()) {
		return;
	}
	if (!g_variant_is_of_type(p_parameters, G_VARIANT_TYPE("(ssav)"))) {
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
