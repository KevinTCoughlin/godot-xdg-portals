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

#include <gio/gio.h>
#include <stdio.h>

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
		"</node>";

static GDBusNodeInfo *introspection = NULL;
static gboolean power_saver_enabled = TRUE;

typedef struct {
	gchar *handle;
	gchar *sender;
	guint32 response;
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

static gboolean emit_action_invoked(gpointer data) {
	gchar *id = data;
	GVariantBuilder parameters;
	g_variant_builder_init(&parameters, G_VARIANT_TYPE("av"));
	g_variant_builder_add(&parameters, "v", g_variant_new_string("slot-3"));

	g_dbus_connection_emit_signal(bus, NULL, PORTAL_PATH,
			"org.freedesktop.portal.Notification", "ActionInvoked",
			g_variant_new("(ss@av)", id, "open-folder", g_variant_builder_end(&parameters)), NULL);
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

static void schedule_response(const gchar *sender, gchar *handle, guint32 response) {
	PendingResponse *pending = g_new0(PendingResponse, 1);
	pending->handle = handle;
	pending->sender = g_strdup(sender);
	pending->response = response;
	g_timeout_add_full(G_PRIORITY_DEFAULT, 50, emit_response, pending, pending_response_free);
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
		if (g_strcmp0(method_name, "QueryStatus") == 0) {
			g_dbus_method_invocation_return_value(invocation, g_variant_new("(i)", 1));
		} else if (g_strcmp0(method_name, "RegisterGame") == 0 ||
				g_strcmp0(method_name, "UnregisterGame") == 0) {
			g_dbus_method_invocation_return_value(invocation, g_variant_new("(i)", 0));
		} else {
			g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
					G_DBUS_ERROR_UNKNOWN_METHOD, "Unknown method %s", method_name);
		}
		return;
	}

	if (g_strcmp0(interface_name, "org.freedesktop.portal.Inhibit") == 0 &&
			g_strcmp0(method_name, "Inhibit") == 0) {
		GVariant *options = g_variant_get_child_value(parameters, 2);
		gchar *handle = request_path_for(sender, options);
		g_variant_unref(options);
		g_dbus_method_invocation_return_value(invocation, g_variant_new("(o)", handle));
		schedule_response(sender, handle, 0);
		return;
	}

	if (g_strcmp0(interface_name, "org.freedesktop.portal.OpenURI") == 0) {
		if (g_strcmp0(method_name, "OpenURI") == 0) {
			GVariant *options = g_variant_get_child_value(parameters, 2);
			gchar *handle = request_path_for(sender, options);
			g_variant_unref(options);
			g_dbus_method_invocation_return_value(invocation, g_variant_new("(o)", handle));
			// Reported as cancelled so the test can tell a real response code
			// apart from a locally synthesised one.
			schedule_response(sender, handle, 1);
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
			g_variant_get_child(parameters, 0, "&s", &id);
			g_dbus_method_invocation_return_value(invocation, NULL);
			g_timeout_add_full(G_PRIORITY_DEFAULT, 50, emit_action_invoked, g_strdup(id), g_free);
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

int main(void) {
	GError *error = NULL;
	introspection = g_dbus_node_info_new_for_xml(INTROSPECTION_XML, &error);
	if (introspection == NULL) {
		g_printerr("fake-portal: bad introspection XML: %s\n", error->message);
		g_error_free(error);
		return 1;
	}

	loop = g_main_loop_new(NULL, FALSE);
	owner_id = g_bus_own_name(G_BUS_TYPE_SESSION, "org.freedesktop.portal.Desktop",
			G_BUS_NAME_OWNER_FLAGS_NONE, on_bus_acquired, on_name_acquired, on_name_lost,
			NULL, NULL);

	g_main_loop_run(loop);

	g_bus_unown_name(owner_id);
	g_main_loop_unref(loop);
	g_dbus_node_info_unref(introspection);
	return 0;
}
