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

# Linux builds the full portal bridge; macOS builds only the power monitor,
# which is the one capability with a genuine platform equivalent (see
# docs/roadmap.md). Everything else uses the pure-GDScript null backend and
# needs no native build at all.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(XDG_PORTALS_PLATFORM "linux")
    set(XDG_PORTALS_LIB_SUFFIX "so")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(XDG_PORTALS_PLATFORM "macos")
    set(XDG_PORTALS_LIB_SUFFIX "dylib")
    enable_language(OBJCXX)
else()
    message(FATAL_ERROR
        "No native build exists for ${CMAKE_SYSTEM_NAME}. That platform uses "
        "the pure-GDScript null backend and needs none."
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

if(XDG_PORTALS_PLATFORM STREQUAL "linux")
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0>=2.66 glib-2.0>=2.66 gobject-2.0>=2.66)

    add_library(xdg_portals SHARED
        src/gvariant_conv.cpp
        src/register_types.cpp
        src/xdg_portal_native.cpp
    )
    target_link_libraries(xdg_portals PRIVATE godot::cpp PkgConfig::GIO)
else()
    # Universal by default so one archive serves both Apple architectures.
    if(NOT CMAKE_OSX_ARCHITECTURES)
        set(CMAKE_OSX_ARCHITECTURES "x86_64;arm64" CACHE STRING "" FORCE)
    endif()
    # isLowPowerModeEnabled needs macOS 12; godot-cpp's own floor is higher.
    if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
        set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "" FORCE)
    endif()

    add_library(xdg_portals SHARED
        src/register_types.cpp
        src/mac_power_monitor.mm
    )
    # The bridge casts in mac_power_monitor.mm are ARC constructs.
    set_source_files_properties(src/mac_power_monitor.mm PROPERTIES
        COMPILE_OPTIONS "-fobjc-arc")
    target_link_libraries(xdg_portals PRIVATE godot::cpp "-framework Foundation")
endif()

target_include_directories(xdg_portals PRIVATE src)
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

# macOS libraries are universal, so the architecture is not part of the name —
# xdg_portals.gdextension keys them on `macos.<target>` alone.
if(XDG_PORTALS_PLATFORM STREQUAL "macos")
    set(XDG_PORTALS_OUTPUT_NAME "xdg_portals.macos.${GODOTCPP_TARGET}")
else()
    set(XDG_PORTALS_OUTPUT_NAME "xdg_portals.linux.${GODOTCPP_TARGET}.${XDG_PORTALS_ARCH}")
endif()

set_target_properties(xdg_portals PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "${XDG_PORTALS_OUTPUT_NAME}"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/addons/xdg_portals/bin"
    # Without this a macOS SHARED library is built as a .dylib but Godot is
    # given the name it expects only through the suffix set here.
    SUFFIX ".${XDG_PORTALS_LIB_SUFFIX}"
)

message(STATUS
    "xdg_portals -> addons/xdg_portals/bin/lib${XDG_PORTALS_OUTPUT_NAME}.${XDG_PORTALS_LIB_SUFFIX}")
