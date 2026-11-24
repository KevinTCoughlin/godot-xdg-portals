// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT
//
// A scripted stand-in for org.freedesktop.portal.Desktop.
//
// It exists so the native backend can be exercised end-to-end on a private
// session bus, with no desktop, no display and no real portal service. It
// implements exactly the surface this addon uses, answers deterministically,
// and drives the asynchronous paths (Request.Response, PropertiesChanged,
// ActionInvoked) on a fixed schedule.
//
// It is a test fixture, not a portal implementation: it is never installed and
// never shipped in a release archive.
//
// Options select the misbehaviour a smoke pass needs (see
// scripts/run_native_smoke.sh, which runs one pass per mode):
//
//   --response-delay MS      Delay before Request::Response (default 50). 0
//                            sends it straight after the method reply, which
//                            is what exposes a client that subscribes late.
//   --gamemode-other-active  QueryStatus reports GameMode active (1) for a pid
//                            that has not registered, as when another game
//                            holds it.
//   --first-get-delay MS     Stall the whole service for MS before answering
//                            the first property read, like a portal still
//                            starting up.
//   --exit-after-open-uri    Answer OpenURI, then exit without ever sending its
//                            Response, like a portal that crashed mid-request.
//   --wedged-bus PATH        Do not act as a portal at all: listen on the unix
//                            socket PATH and never answer, like a session bus
//                            that accepts connections and then hangs.

#include <gio/gio.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define PORTAL_PATH "/org/freedesktop/portal/desktop"

static GMainLoop *loop = NULL;
static GDBusConnection *bus = NULL;
static guint owner_id = 0;

static const gchar *INTROSPECTION_XML =
		"<node>"
		"  <interface name='org.freedesktop.portal.GameMode'>"
		"    <method name='QueryStatus'>"
		"      <arg type='i' name='pid' direction='in'/>"
		"      <arg type='i' name='result' direction='out'/>"
		"    </method>"
		"    <method name='RegisterGame'>"
		"      <arg type='i' name='pid' direction='in'/>"
		"      <arg type='i' name='result' direction='out'/>"
		"    </method>"
		"    <method name='UnregisterGame'>"
		"      <arg type='i' name='pid' direction='in'/>"
		"      <arg type='i' name='result' direction='out'/>"
		"    </method>"
		"    <property name='version' type='u' access='read'/>"
		"  </interface>"
		"  <interface name='org.freedesktop.portal.Inhibit'>"
		"    <method name='Inhibit'>"
		"      <arg type='s' name='window' direction='in'/>"
		"      <arg type='u' name='flags' direction='in'/>"
		"      <arg type='a{sv}' name='options' direction='in'/>"
		"      <arg type='o' name='handle' direction='out'/>"
		"    </method>"
		"    <property name='version' type='u' access='read'/>"
		"  </interface>"
		"  <interface name='org.freedesktop.portal.PowerProfileMonitor'>"
		"    <property name='power-saver-enabled' type='b' access='read'/>"
		"    <property name='version' type='u' access='read'/>"
		"  </interface>"
		"  <interface name='org.freedesktop.portal.OpenURI'>"
		"    <method name='OpenURI'>"
		"      <arg type='s' name='parent_window' direction='in'/>"
		"      <arg type='s' name='uri' direction='in'/>"
		"      <arg type='a{sv}' name='options' direction='in'/>"
		"      <arg type='o' name='handle' direction='out'/>"
		"    </method>"
		"    <method name='SchemeSupported'>"
		"      <arg type='s' name='scheme' direction='in'/>"
		"      <arg type='a{sv}' name='options' direction='in'/>"
		"      <arg type='b' name='supported' direction='out'/>"
		"    </method>"
		"    <property name='version' type='u' access='read'/>"
		"  </interface>"
		"  <interface name='org.freedesktop.portal.Notification'>"
		"    <method name='AddNotification'>"
		"      <arg type='s' name='id' direction='in'/>"
		"      <arg type='a{sv}' name='notification' direction='in'/>"
		"    </method>"
		"    <method name='RemoveNotification'>"
		"      <arg type='s' name='id' direction='in'/>"
		"    </method>"
		"    <signal name='ActionInvoked'>"
		"      <arg type='s' name='id'/>"
		"      <arg type='s' name='action'/>"
		"      <arg type='av' name='parameter'/>"
		"    </signal>"
		"    <property name='version' type='u' access='read'/>"
		"  </interface>"
		"  <interface name='org.freedesktop.portal.Request'>"
		"    <method name='Close'/>"
		"    <signal name='Response'>"
		"      <arg type='u' name='response'/>"
		"      <arg type='a{sv}' name='results'/>"
		"    </signal>"
		"  </interface>"
		"</node>";

static GDBusNodeInfo *introspection = NULL;
static gboolean power_saver_enabled = TRUE;
static const GDBusInterfaceVTable VTABLE;

// Options; see the header comment.
static guint response_delay_ms = 50;
static gboolean gamemode_other_active = FALSE;
static guint first_get_delay_ms = 0;
static gboolean exit_after_open_uri = FALSE;

// Pids registered through RegisterGame, so QueryStatus answers from state
// rather than a constant: 0 inactive, 1 active for others, 2 active and
// registered by this pid, as org.freedesktop.portal.GameMode specifies.
static GHashTable *registered_pids = NULL;

typedef struct {
	gchar *handle;
	gchar *sender;
	guint32 response;
	// Adds a value of each kind a portal's results can carry.
	gboolean detailed;
} PendingResponse;

static void pending_response_free(gpointer data) {
	PendingResponse *pending = data;
	g_free(pending->handle);
	g_free(pending->sender);
	g_free(pending);
}

// Emits org.freedesktop.portal.Request::Response on the predicted handle path.
static gboolean emit_response(gpointer data) {
	PendingResponse *pending = data;
	GVariantBuilder results;
	g_variant_builder_init(&results, G_VARIANT_TYPE("a{sv}"));
	g_variant_builder_add(&results, "{sv}", "session_handle", g_variant_new_string(pending->handle));
	if (pending->detailed) {
		static const gchar *const uris[] = { "https://a.example/", "https://b.example/", NULL };
		g_variant_builder_add(&results, "{sv}", "uris", g_variant_new_strv(uris, -1));
		g_variant_builder_add(&results, "{sv}", "count", g_variant_new_uint32(3));
		g_variant_builder_add(&results, "{sv}", "ratio", g_variant_new_double(0.25));
		g_variant_builder_add(&results, "{sv}", "granted", g_variant_new_boolean(TRUE));
	}

	GError *err = NULL;
	gboolean ok = g_dbus_connection_emit_signal(bus, pending->sender, pending->handle,
			"org.freedesktop.portal.Request", "Response",
			g_variant_new("(u@a{sv})", pending->response, g_variant_builder_end(&results)), &err);
	printf("fake-portal: emit Response to %s on %s: %s\n", pending->sender, pending->handle,
			ok ? "ok" : err->message);
	fflush(stdout);
	g_clear_error(&err);
	return G_SOURCE_REMOVE;
}

// An ActionInvoked the fixture will emit. `action` NULL means the historical
// stand-in "open-folder", used when the notification named no default action.
typedef struct {
	gchar *id;
	gchar *action;
} ScheduledAction;

static void scheduled_action_free(gpointer data) {
	ScheduledAction *scheduled = data;
	g_free(scheduled->id);
	g_free(scheduled->action);
	g_free(scheduled);
}

typedef struct {
	gchar *label;
	gchar *action;
} ParsedButton;

// Copies a string field. Empty is allowed for title, body and priority, and
// rejected for an action or a button label: those are tokens the addon
// promises to send non-empty.
static gchar *assign_string_field(const gchar *key, GVariant *value, gchar **slot, gboolean allow_empty) {
	if (*slot != NULL) {
		return g_strdup_printf("duplicate %s", key);
	}
	if (!g_variant_is_of_type(value, G_VARIANT_TYPE_STRING)) {
		return g_strdup_printf("%s is not a string", key);
	}
	const gchar *text = g_variant_get_string(value, NULL);
	if (!allow_empty && text[0] == '\0') {
		return g_strdup_printf("%s is empty", key);
	}
	*slot = g_strdup(text);
	return NULL;
}

static void free_parsed_buttons(ParsedButton *parsed, guint count) {
	for (guint i = 0; i < count; i++) {
		g_free(parsed[i].label);
		g_free(parsed[i].action);
	}
}

// Each button is exactly {label, action}, both strings. A `target` key, or
// any other key, is a client building a variant this addon must not send.
static gchar *parse_buttons(GVariant *value, ParsedButton *parsed, guint *r_count) {
	if (!g_variant_is_of_type(value, G_VARIANT_TYPE("aa{sv}"))) {
		return g_strdup("buttons is not aa{sv}");
	}
	const gsize count = g_variant_n_children(value);
	if (count > 16) {
		return g_strdup("too many buttons");
	}
	for (gsize i = 0; i < count; i++) {
		GVariant *button = g_variant_get_child_value(value, i);
		gchar *label = NULL;
		gchar *action = NULL;
		gchar *reason = NULL;
		GVariantIter fields;
		g_variant_iter_init(&fields, button);
		GVariant *field = NULL;
		while (reason == NULL && (field = g_variant_iter_next_value(&fields)) != NULL) {
			const gchar *key = NULL;
			GVariant *item = NULL;
			g_variant_get(field, "{&sv}", &key, &item);
			if (g_strcmp0(key, "label") == 0) {
				reason = assign_string_field("button label", item, &label, FALSE);
			} else if (g_strcmp0(key, "action") == 0) {
				reason = assign_string_field("button action", item, &action, FALSE);
			} else {
				reason = g_strdup_printf("button has unexpected key %s", key);
			}
			g_clear_pointer(&item, g_variant_unref);
			g_variant_unref(field);
		}
		if (reason == NULL && (label == NULL || action == NULL)) {
			reason = g_strdup("button is missing label or action");
		}
		if (reason == NULL) {
			parsed[*r_count].label = g_steal_pointer(&label);
			parsed[*r_count].action = g_steal_pointer(&action);
			*r_count += 1;
		}
		g_free(label);
		g_free(action);
		g_variant_unref(button);
		if (reason != NULL) {
			return reason;
		}
	}
	return NULL;
}

// The id "smoke-actions" is the native smoke test's notification. The payload
// has to be exactly what that test posts, including both buttons and no target,
// or AddNotification fails and the test cannot pass by accident.
static gchar *smoke_actions_rejection(const gchar *title, const gchar *body, const gchar *priority,
		const gchar *default_action, const ParsedButton *parsed, guint count) {
	if (g_strcmp0(title, "Title") != 0 || g_strcmp0(body, "Body") != 0 || g_strcmp0(priority, "high") != 0 ||
			g_strcmp0(default_action, "open") != 0) {
		return g_strdup("smoke-actions fields are not title/body/priority high/default-action open");
	}
	if (count != 2 || g_strcmp0(parsed[0].label, "Open") != 0 || g_strcmp0(parsed[0].action, "open") != 0 ||
			g_strcmp0(parsed[1].label, "Dismiss") != 0 || g_strcmp0(parsed[1].action, "dismiss") != 0) {
		return g_strdup("smoke-actions buttons are not Open/open then Dismiss/dismiss");
	}
	return NULL;
}

// NULL when the payload is acceptable. On success *r_default_action is a copy
// of default-action, or NULL when that key was absent.
static gchar *notification_rejection(GVariant *notification, const gchar *id, gchar **r_default_action) {
	*r_default_action = NULL;
	gchar *reason = NULL;
	gchar *title = NULL;
	gchar *body = NULL;
	gchar *priority = NULL;
	gchar *default_action = NULL;
	ParsedButton parsed[16];
	guint n_buttons = 0;
	memset(parsed, 0, sizeof(parsed));

	GVariantIter entries;
	g_variant_iter_init(&entries, notification);
	GVariant *entry = NULL;
	while (reason == NULL && (entry = g_variant_iter_next_value(&entries)) != NULL) {
		const gchar *key = NULL;
		GVariant *value = NULL;
		g_variant_get(entry, "{&sv}", &key, &value);
		if (g_strcmp0(key, "title") == 0) {
			reason = assign_string_field("title", value, &title, TRUE);
		} else if (g_strcmp0(key, "body") == 0) {
			reason = assign_string_field("body", value, &body, TRUE);
		} else if (g_strcmp0(key, "priority") == 0) {
			reason = assign_string_field("priority", value, &priority, TRUE);
		} else if (g_strcmp0(key, "default-action") == 0) {
			reason = assign_string_field("default-action", value, &default_action, FALSE);
		} else if (g_strcmp0(key, "buttons") == 0) {
			reason = parse_buttons(value, parsed, &n_buttons);
		} else {
			reason = g_strdup_printf("unexpected key %s", key);
		}
		g_clear_pointer(&value, g_variant_unref);
		g_variant_unref(entry);
	}
	if (reason == NULL && g_strcmp0(id, "smoke-actions") == 0) {
		reason = smoke_actions_rejection(title, body, priority, default_action, parsed, n_buttons);
	}
	if (reason == NULL && default_action != NULL) {
		*r_default_action = g_strdup(default_action);
	}
	g_free(title);
	g_free(body);
	g_free(priority);
	g_free(default_action);
	free_parsed_buttons(parsed, n_buttons);
	return reason;
}

static gboolean emit_action_invoked(gpointer data) {
	ScheduledAction *scheduled = data;
	const gchar *id = scheduled->id;
	const gchar *action = scheduled->action != NULL ? scheduled->action : "open-folder";
	GVariantBuilder parameters;
	g_variant_builder_init(&parameters, G_VARIANT_TYPE("av"));
	g_variant_builder_add(&parameters, "v", g_variant_new_string("slot-3"));
	if (g_strcmp0(id, "smoke-types") == 0) {
		// Container types the client must convert faithfully: a byte array and
		// a dictionary whose keys are not strings.
		static const guint8 bytes[] = { 1, 2, 255 };
		g_variant_builder_add(&parameters, "v",
				g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, bytes, sizeof(bytes), 1));
		GVariantBuilder by_number;
		g_variant_builder_init(&by_number, G_VARIANT_TYPE("a{us}"));
		g_variant_builder_add(&by_number, "{us}", 1, "one");
		g_variant_builder_add(&by_number, "{us}", 2, "two");
		g_variant_builder_add(&parameters, "v", g_variant_builder_end(&by_number));
	} else if (g_strcmp0(id, "smoke-scalars") == 0) {
		// One of every basic type, at the edges of its range, then the
		// containers that are not byte arrays or dictionaries.
		g_variant_builder_add(&parameters, "v", g_variant_new_boolean(TRUE));
		g_variant_builder_add(&parameters, "v", g_variant_new_byte(255));
		g_variant_builder_add(&parameters, "v", g_variant_new_int16(G_MININT16));
		g_variant_builder_add(&parameters, "v", g_variant_new_uint16(G_MAXUINT16));
		g_variant_builder_add(&parameters, "v", g_variant_new_int32(G_MININT32));
		g_variant_builder_add(&parameters, "v", g_variant_new_uint32(G_MAXUINT32));
		g_variant_builder_add(&parameters, "v", g_variant_new_int64(G_MININT64));
		// Above INT64_MAX: clamped, not wrapped to a negative number.
		g_variant_builder_add(&parameters, "v", g_variant_new_uint64(G_MAXUINT64));
		g_variant_builder_add(&parameters, "v", g_variant_new_uint64(42));
		g_variant_builder_add(&parameters, "v", g_variant_new_double(-1.5));
		g_variant_builder_add(&parameters, "v", g_variant_new_object_path("/org/example/Path"));
		g_variant_builder_add(&parameters, "v", g_variant_new_signature("a{sv}"));
		// A variant inside the variant is unwrapped all the way.
		g_variant_builder_add(&parameters, "v",
				g_variant_new_variant(g_variant_new_string("nested")));
		g_variant_builder_add(&parameters, "v", g_variant_new("(si)", "pair", 9));
		g_variant_builder_add(&parameters, "v", g_variant_new_parsed("@ay []"));
		g_variant_builder_add(&parameters, "v", g_variant_new_parsed("[<'x'>, <int32 2>]"));
		g_variant_builder_add(&parameters, "v", g_variant_new_parsed("{'k': <int32 5>}"));
		g_variant_builder_add(&parameters, "v", g_variant_new_parsed("@ai []"));
	}

	g_dbus_connection_emit_signal(bus, NULL, PORTAL_PATH,
			"org.freedesktop.portal.Notification", "ActionInvoked",
			g_variant_new("(ss@av)", id, action, g_variant_builder_end(&parameters)), NULL);
	return G_SOURCE_REMOVE;
}

static gboolean toggle_power_saver(gpointer data) {
	(void)data;
	power_saver_enabled = !power_saver_enabled;

	GVariantBuilder changed;
	g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));
	g_variant_builder_add(&changed, "{sv}", "power-saver-enabled",
			g_variant_new_boolean(power_saver_enabled));

	g_dbus_connection_emit_signal(bus, NULL, PORTAL_PATH,
			"org.freedesktop.DBus.Properties", "PropertiesChanged",
			g_variant_new("(s@a{sv}@as)", "org.freedesktop.portal.PowerProfileMonitor",
					g_variant_builder_end(&changed), g_variant_new_strv(NULL, 0)),
			NULL);
	return G_SOURCE_CONTINUE;
}

// Rebuilds the request path the client predicted, so the fixture also proves the
// client's handle derivation matches the portal specification.
static gchar *request_path_for(const gchar *sender, GVariant *options) {
	const gchar *token = NULL;
	if (!g_variant_lookup(options, "handle_token", "&s", &token)) {
		token = "t";
	}
	gchar *escaped = g_strdup(sender[0] == ':' ? sender + 1 : sender);
	for (gchar *c = escaped; *c != '\0'; c++) {
		if (*c == '.') {
			*c = '_';
		}
	}
	gchar *path = g_strdup_printf("%s/request/%s/%s", PORTAL_PATH, escaped, token);
	g_free(escaped);
	return path;
}

static void schedule_response(const gchar *sender, gchar *handle, guint32 response,
		gboolean detailed) {
	PendingResponse *pending = g_new0(PendingResponse, 1);
	pending->handle = handle;
	pending->sender = g_strdup(sender);
	pending->response = response;
	pending->detailed = detailed;
	g_timeout_add_full(G_PRIORITY_DEFAULT, response_delay_ms, emit_response, pending,
			pending_response_free);
}

static gboolean quit_loop(gpointer data) {
	(void)data;
	printf("fake-portal: exiting with a request still pending\n");
	fflush(stdout);
	g_main_loop_quit(loop);
	return G_SOURCE_REMOVE;
}

static gint32 game_mode_status_for(gint32 pid) {
	if (g_hash_table_contains(registered_pids, GINT_TO_POINTER(pid))) {
		return 2;
	}
	if (gamemode_other_active || g_hash_table_size(registered_pids) > 0) {
		return 1;
	}
	return 0;
}

static void handle_method_call(GDBusConnection *connection, const gchar *sender,
		const gchar *object_path, const gchar *interface_name, const gchar *method_name,
		GVariant *parameters, GDBusMethodInvocation *invocation, gpointer user_data) {
	(void)connection;
	(void)object_path;
	(void)user_data;

	printf("fake-portal: %s.%s from %s\n", interface_name, method_name, sender);
	fflush(stdout);

	if (g_strcmp0(interface_name, "org.freedesktop.portal.GameMode") == 0) {
		gint32 pid = 0;
		g_variant_get(parameters, "(i)", &pid);
		if (g_strcmp0(method_name, "QueryStatus") == 0) {
			g_dbus_method_invocation_return_value(invocation,
					g_variant_new("(i)", game_mode_status_for(pid)));
		} else if (g_strcmp0(method_name, "RegisterGame") == 0) {
			// The real portal rejects a second registration of a pid the daemon
			// already knows, with -1. A set that answered 0 both times hid that.
			if (g_hash_table_contains(registered_pids, GINT_TO_POINTER(pid))) {
				g_dbus_method_invocation_return_value(invocation, g_variant_new("(i)", -1));
			} else {
				g_hash_table_add(registered_pids, GINT_TO_POINTER(pid));
				g_dbus_method_invocation_return_value(invocation, g_variant_new("(i)", 0));
			}
		} else if (g_strcmp0(method_name, "UnregisterGame") == 0) {
			const gboolean was_registered = g_hash_table_remove(registered_pids, GINT_TO_POINTER(pid));
			g_dbus_method_invocation_return_value(invocation,
					g_variant_new("(i)", was_registered ? 0 : -1));
		} else {
			g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
					G_DBUS_ERROR_UNKNOWN_METHOD, "Unknown method %s", method_name);
		}
		return;
	}

	if (g_strcmp0(interface_name, "org.freedesktop.portal.Inhibit") == 0 &&
			g_strcmp0(method_name, "Inhibit") == 0) {
		GVariant *options = g_variant_get_child_value(parameters, 2);
		gchar *predicted = request_path_for(sender, options);
		gchar *handle = g_strconcat(predicted, "_actual", NULL);
		g_free(predicted);
		// The reason "smoke-other" ends the request with response 2 and a
		// results payload of every common kind, as a portal that gave up would.
		const gchar *reason = NULL;
		const gboolean other = g_variant_lookup(options, "reason", "&s", &reason) &&
				g_strcmp0(reason, "smoke-other") == 0;
		g_variant_unref(options);
		GError *error = NULL;
		GDBusInterfaceInfo *request_interface = g_dbus_node_info_lookup_interface(
				introspection, "org.freedesktop.portal.Request");
		g_dbus_connection_register_object(connection, handle, request_interface,
				&VTABLE, NULL, NULL, &error);
		if (error != NULL) {
			g_dbus_method_invocation_return_gerror(invocation, error);
			g_clear_error(&error);
			g_free(handle);
			return;
		}
		g_dbus_method_invocation_return_value(invocation, g_variant_new("(o)", handle));
		schedule_response(sender, handle, other ? 2 : 0, other);
		return;
	}

	if (g_strcmp0(interface_name, "org.freedesktop.portal.Request") == 0 &&
			g_strcmp0(method_name, "Close") == 0) {
		g_dbus_method_invocation_return_value(invocation, NULL);
		return;
	}

	if (g_strcmp0(interface_name, "org.freedesktop.portal.OpenURI") == 0) {
		if (g_strcmp0(method_name, "OpenURI") == 0) {
			GVariant *options = g_variant_get_child_value(parameters, 2);
			gchar *handle = request_path_for(sender, options);
			g_variant_unref(options);
			g_dbus_method_invocation_return_value(invocation, g_variant_new("(o)", handle));
			if (exit_after_open_uri) {
				// Leave the request pending forever: the reply goes out, the
				// Response never does. The delay lets the reply be flushed.
				g_free(handle);
				g_timeout_add(100, quit_loop, NULL);
				return;
			}
			// Reported as cancelled so the test can tell a real response code
			// apart from a locally synthesised one.
			schedule_response(sender, handle, 1, FALSE);
			return;
		}
		if (g_strcmp0(method_name, "SchemeSupported") == 0) {
			const gchar *scheme = NULL;
			g_variant_get_child(parameters, 0, "&s", &scheme);
			const gboolean supported = g_strcmp0(scheme, "https") == 0;
			g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", supported));
			return;
		}
	}

	if (g_strcmp0(interface_name, "org.freedesktop.portal.Notification") == 0) {
		if (g_strcmp0(method_name, "AddNotification") == 0) {
			const gchar *id = NULL;
			GVariant *notification = NULL;
			g_variant_get(parameters, "(&s@a{sv})", &id, &notification);
			gchar *action = NULL;
			gchar *reason = notification_rejection(notification, id, &action);
			g_variant_unref(notification);
			if (reason != NULL) {
				g_printerr("fake-portal: notification %s rejected: %s\n", id, reason);
				g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
						"notification payload rejected: %s", reason);
				g_free(reason);
				g_free(action);
				return;
			}
			printf("fake-portal: notification %s default-action=%s\n", id,
					action != NULL ? action : "(none)");
			fflush(stdout);
			g_dbus_method_invocation_return_value(invocation, NULL);
			ScheduledAction *scheduled = g_new0(ScheduledAction, 1);
			scheduled->id = g_strdup(id);
			scheduled->action = action;
			g_timeout_add_full(G_PRIORITY_DEFAULT, 50, emit_action_invoked, scheduled, scheduled_action_free);
			return;
		}
		if (g_strcmp0(method_name, "RemoveNotification") == 0) {
			g_dbus_method_invocation_return_value(invocation, NULL);
			return;
		}
	}

	g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
			"Unknown method %s.%s", interface_name, method_name);
}

static GVariant *handle_get_property(GDBusConnection *connection, const gchar *sender,
		const gchar *object_path, const gchar *interface_name, const gchar *property_name,
		GError **error, gpointer user_data) {
	(void)connection;
	(void)sender;
	(void)object_path;
	(void)user_data;

	if (first_get_delay_ms > 0) {
		// Blocking is the point: a portal that is still starting answers
		// nothing, not just this one read.
		printf("fake-portal: stalling %u ms before the first property read\n", first_get_delay_ms);
		fflush(stdout);
		g_usleep((gulong)first_get_delay_ms * 1000);
		first_get_delay_ms = 0;
	}

	if (g_strcmp0(property_name, "power-saver-enabled") == 0) {
		return g_variant_new_boolean(power_saver_enabled);
	}
	if (g_strcmp0(property_name, "version") == 0) {
		if (g_strcmp0(interface_name, "org.freedesktop.portal.OpenURI") == 0) {
			return g_variant_new_uint32(5);
		}
		if (g_strcmp0(interface_name, "org.freedesktop.portal.Inhibit") == 0) {
			return g_variant_new_uint32(3);
		}
		if (g_strcmp0(interface_name, "org.freedesktop.portal.Notification") == 0) {
			return g_variant_new_uint32(2);
		}
		return g_variant_new_uint32(1);
	}

	g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Unknown property %s",
			property_name);
	return NULL;
}

static const GDBusInterfaceVTable VTABLE = {
	handle_method_call,
	handle_get_property,
	NULL,
	{ NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL }
};

static void on_bus_acquired(GDBusConnection *connection, const gchar *name, gpointer user_data) {
	(void)name;
	(void)user_data;
	bus = connection;

	for (guint i = 0; introspection->interfaces[i] != NULL; i++) {
		if (g_strcmp0(introspection->interfaces[i]->name,
					"org.freedesktop.portal.Request") == 0) {
			continue;
		}
		GError *error = NULL;
		g_dbus_connection_register_object(connection, PORTAL_PATH, introspection->interfaces[i],
				&VTABLE, NULL, NULL, &error);
		if (error != NULL) {
			g_printerr("fake-portal: could not register %s: %s\n",
					introspection->interfaces[i]->name, error->message);
			g_error_free(error);
			g_main_loop_quit(loop);
			return;
		}
	}

	g_timeout_add(300, toggle_power_saver, NULL);
}

static void on_name_acquired(GDBusConnection *connection, const gchar *name, gpointer user_data) {
	(void)connection;
	(void)user_data;
	// The harness waits for this line before starting the client under test.
	printf("fake-portal: ready as %s\n", name);
	fflush(stdout);
}

static void on_name_lost(GDBusConnection *connection, const gchar *name, gpointer user_data) {
	(void)connection;
	(void)user_data;
	g_printerr("fake-portal: lost %s\n", name);
	g_main_loop_quit(loop);
}

// Listens on `path` and never reads or writes, so a client's authentication
// handshake waits forever. Connections queue in the listen backlog unaccepted.
static int run_wedged_bus(const char *path) {
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		perror("fake-portal: socket");
		return 1;
	}
	struct sockaddr_un address;
	memset(&address, 0, sizeof(address));
	address.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof(address.sun_path)) {
		g_printerr("fake-portal: socket path too long: %s\n", path);
		close(fd);
		return 1;
	}
	g_strlcpy(address.sun_path, path, sizeof(address.sun_path));
	unlink(path);
	if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 16) != 0) {
		perror("fake-portal: bind/listen");
		close(fd);
		return 1;
	}
	printf("fake-portal: ready as a wedged bus on %s\n", path);
	fflush(stdout);
	for (;;) {
		pause();
	}
}

static gboolean parse_uint(const char *text, guint *r_value) {
	guint64 value = 0;
	if (!g_ascii_string_to_unsigned(text, 10, 0, G_MAXUINT, &value, NULL)) {
		return FALSE;
	}
	*r_value = (guint)value;
	return TRUE;
}

int main(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		const char *option = argv[i];
		const char *value = i + 1 < argc ? argv[i + 1] : NULL;
		if (g_strcmp0(option, "--response-delay") == 0 && value != NULL && parse_uint(value, &response_delay_ms)) {
			i++;
		} else if (g_strcmp0(option, "--first-get-delay") == 0 && value != NULL && parse_uint(value, &first_get_delay_ms)) {
			i++;
		} else if (g_strcmp0(option, "--gamemode-other-active") == 0) {
			gamemode_other_active = TRUE;
		} else if (g_strcmp0(option, "--exit-after-open-uri") == 0) {
			exit_after_open_uri = TRUE;
		} else if (g_strcmp0(option, "--wedged-bus") == 0 && value != NULL) {
			return run_wedged_bus(value);
		} else {
			g_printerr("fake-portal: bad option %s\n", option);
			return 2;
		}
	}

	GError *error = NULL;
	introspection = g_dbus_node_info_new_for_xml(INTROSPECTION_XML, &error);
	if (introspection == NULL) {
		g_printerr("fake-portal: bad introspection XML: %s\n", error->message);
		g_error_free(error);
		return 1;
	}

	registered_pids = g_hash_table_new(g_direct_hash, g_direct_equal);
	loop = g_main_loop_new(NULL, FALSE);
	owner_id = g_bus_own_name(G_BUS_TYPE_SESSION, "org.freedesktop.portal.Desktop",
			G_BUS_NAME_OWNER_FLAGS_NONE, on_bus_acquired, on_name_acquired, on_name_lost,
			NULL, NULL);

	g_main_loop_run(loop);

	g_bus_unown_name(owner_id);
	g_main_loop_unref(loop);
	g_dbus_node_info_unref(introspection);
	g_hash_table_unref(registered_pids);
	return 0;
}
