// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT

#include "gvariant_conv.h"

#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

using namespace godot;

namespace xdg_portals {

namespace {

bool is_dict(GVariant *p_variant) {
	return g_variant_is_of_type(p_variant, G_VARIANT_TYPE_DICTIONARY);
}

PackedByteArray bytes_to_packed(GVariant *p_variant) {
	PackedByteArray bytes;
	gsize count = 0;
	const auto *data = static_cast<const uint8_t *>(
			g_variant_get_fixed_array(p_variant, &count, sizeof(guint8)));
	if (data == nullptr || count == 0) {
		return bytes;
	}
	bytes.resize(static_cast<int64_t>(count));
	uint8_t *out = bytes.ptrw();
	for (gsize i = 0; i < count; i++) {
		out[i] = data[i];
	}
	return bytes;
}

} // namespace

// The recursion follows the value's own nesting, which is bounded: every value
// converted here arrived over the bus, and GDBus rejects messages nested deeper
// than the D-Bus specification's limit of 64 containers.
// NOLINTNEXTLINE(misc-no-recursion)
Variant gvariant_to_variant(GVariant *p_variant) {
	if (p_variant == nullptr) {
		return Variant();
	}

	const GVariantClass klass = g_variant_classify(p_variant);
	switch (klass) {
		case G_VARIANT_CLASS_BOOLEAN:
			return Variant(static_cast<bool>(g_variant_get_boolean(p_variant)));
		case G_VARIANT_CLASS_BYTE:
			return Variant(static_cast<int64_t>(g_variant_get_byte(p_variant)));
		case G_VARIANT_CLASS_INT16:
			return Variant(static_cast<int64_t>(g_variant_get_int16(p_variant)));
		case G_VARIANT_CLASS_UINT16:
			return Variant(static_cast<int64_t>(g_variant_get_uint16(p_variant)));
		case G_VARIANT_CLASS_INT32:
			return Variant(static_cast<int64_t>(g_variant_get_int32(p_variant)));
		case G_VARIANT_CLASS_UINT32:
			return Variant(static_cast<int64_t>(g_variant_get_uint32(p_variant)));
		case G_VARIANT_CLASS_INT64:
			return Variant(static_cast<int64_t>(g_variant_get_int64(p_variant)));
		case G_VARIANT_CLASS_UINT64:
			// D-Bus `t` can exceed int64; clamping is preferable to wrapping.
			{
				const guint64 value = g_variant_get_uint64(p_variant);
				const auto limit = static_cast<guint64>(INT64_MAX);
				return Variant(static_cast<int64_t>(value > limit ? limit : value));
			}
		case G_VARIANT_CLASS_HANDLE:
			return Variant(static_cast<int64_t>(g_variant_get_handle(p_variant)));
		case G_VARIANT_CLASS_DOUBLE:
			return Variant(static_cast<double>(g_variant_get_double(p_variant)));
		case G_VARIANT_CLASS_STRING:
		case G_VARIANT_CLASS_OBJECT_PATH:
		case G_VARIANT_CLASS_SIGNATURE:
			return Variant(String::utf8(g_variant_get_string(p_variant, nullptr)));
		case G_VARIANT_CLASS_VARIANT: {
			GVariant *inner = g_variant_get_variant(p_variant);
			Variant result = gvariant_to_variant(inner);
			g_variant_unref(inner);
			return result;
		}
		case G_VARIANT_CLASS_MAYBE: {
			GVariant *inner = g_variant_get_maybe(p_variant);
			if (inner == nullptr) {
				return Variant();
			}
			Variant result = gvariant_to_variant(inner);
			g_variant_unref(inner);
			return result;
		}
		case G_VARIANT_CLASS_ARRAY:
			if (is_dict(p_variant)) {
				return Variant(gvariant_dict_to_dictionary(p_variant));
			}
			// Binary payloads (`ay`) are bytes, not a list of small integers.
			if (g_variant_is_of_type(p_variant, G_VARIANT_TYPE_BYTESTRING)) {
				return Variant(bytes_to_packed(p_variant));
			}
			[[fallthrough]];
		case G_VARIANT_CLASS_TUPLE:
		// A lone dict entry, outside an array, is a key/value pair.
		case G_VARIANT_CLASS_DICT_ENTRY: {
			Array array;
			const gsize count = g_variant_n_children(p_variant);
			for (gsize i = 0; i < count; i++) {
				GVariant *child = g_variant_get_child_value(p_variant, i);
				array.push_back(gvariant_to_variant(child));
				g_variant_unref(child);
			}
			return Variant(array);
		}
		default:
			return Variant();
	}
}

// NOLINTNEXTLINE(misc-no-recursion): bounded as above.
Dictionary gvariant_dict_to_dictionary(GVariant *p_variant) {
	Dictionary dictionary;
	if (p_variant == nullptr || !is_dict(p_variant)) {
		return dictionary;
	}

	GVariantIter iter;
	g_variant_iter_init(&iter, p_variant);
	GVariant *entry = nullptr;
	while ((entry = g_variant_iter_next_value(&iter)) != nullptr) {
		GVariant *key = g_variant_get_child_value(entry, 0);
		GVariant *value = g_variant_get_child_value(entry, 1);
		// Keys are basic types, so this is a String or an int (or a bool, or a
		// float) — never a container.
		dictionary[gvariant_to_variant(key)] = gvariant_to_variant(value);
		g_variant_unref(key);
		g_variant_unref(value);
		g_variant_unref(entry);
	}
	return dictionary;
}

} // namespace xdg_portals
