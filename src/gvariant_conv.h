// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT

#ifndef XDG_PORTALS_GVARIANT_CONV_H
#define XDG_PORTALS_GVARIANT_CONV_H

#include <gio/gio.h>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace xdg_portals {

// Converts a GVariant into the closest Godot Variant.
//
// The mapping is intentionally one-way and read-only: the addon never turns
// user-supplied Godot values back into arbitrary D-Bus payloads, so there is no
// path from game code to an arbitrary bus call.
//
//   b            -> bool
//   y n q i u x t-> int
//   d            -> float
//   s o g        -> String
//   ay           -> PackedByteArray
//   a{**}        -> Dictionary, keys converted like any other value
//   a*           -> Array
//   (…) {**}     -> Array
//   v m*         -> unwrapped value (null for an empty maybe)
//   anything else-> Variant() (null)
godot::Variant gvariant_to_variant(GVariant *p_variant);

// Converts any dictionary (`a{**}`), such as the `a{sv}` payloads portals hand
// back with Response signals. Anything that is not a dictionary yields an empty
// one.
godot::Dictionary gvariant_dict_to_dictionary(GVariant *p_variant);

} // namespace xdg_portals

#endif // XDG_PORTALS_GVARIANT_CONV_H
