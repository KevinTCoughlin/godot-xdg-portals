# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT

cmake_minimum_required(VERSION 3.22)

project(
    xdg_portals
    VERSION 0.1.0
    DESCRIPTION "Godot 4 GDExtension for selected XDG Desktop Portal APIs"
    HOMEPAGE_URL "https://github.com/KevinTCoughlin/godot-xdg-portals"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR
        "The XdgPortalNative extension is Linux-only. Other platforms use the "
        "pure-GDScript null backend and need no native build."
    )
endif()

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# godot-cpp is pinned to the tag matching the minimum supported engine version.
set(XDG_PORTALS_GODOT_CPP_TAG "godot-4.4.1-stable" CACHE STRING
    "godot-cpp git tag to build against")
set(XDG_PORTALS_GODOT_CPP_PATH "" CACHE PATH
    "Path to a local godot-cpp checkout; leave empty to fetch the pinned tag")

set(GODOTCPP_TARGET "template_release" CACHE STRING
    "godot-cpp build target (template_debug|template_release|editor)")

include(FetchContent)
if(XDG_PORTALS_GODOT_CPP_PATH)
    FetchContent_Declare(godot-cpp SOURCE_DIR "${XDG_PORTALS_GODOT_CPP_PATH}")
else()
    FetchContent_Declare(
        godot-cpp
        GIT_REPOSITORY https://github.com/godotengine/godot-cpp.git
        GIT_TAG ${XDG_PORTALS_GODOT_CPP_TAG}
        GIT_SHALLOW TRUE
    )
endif()
FetchContent_MakeAvailable(godot-cpp)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0>=2.66 glib-2.0>=2.66 gobject-2.0>=2.66)

add_library(xdg_portals SHARED
    src/gvariant_conv.cpp
    src/register_types.cpp
    src/xdg_portal_native.cpp
)

target_include_directories(xdg_portals PRIVATE src)
target_link_libraries(xdg_portals PRIVATE godot::cpp PkgConfig::GIO)
target_compile_options(xdg_portals PRIVATE -Wall -Wextra -Wpedantic)

# Godot resolves libraries by the `<name>.<platform>.<target>.<arch>` convention
# declared in addons/xdg_portals/xdg_portals.gdextension.
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64")
    set(XDG_PORTALS_ARCH "x86_64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
    set(XDG_PORTALS_ARCH "arm64")
else()
    set(XDG_PORTALS_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
endif()

set_target_properties(xdg_portals PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "xdg_portals.linux.${GODOTCPP_TARGET}.${XDG_PORTALS_ARCH}"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/addons/xdg_portals/bin"
)

message(STATUS "xdg_portals -> addons/xdg_portals/bin/lib$<TARGET_PROPERTY:xdg_portals,OUTPUT_NAME>.so")
