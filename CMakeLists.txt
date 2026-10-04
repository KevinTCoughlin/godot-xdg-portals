# SPDX-FileCopyrightText: 2026 Kevin Coughlin
#
# SPDX-License-Identifier: MIT

cmake_minimum_required(VERSION 3.22)

project(
    xdg_portals
    VERSION 0.2.0
    DESCRIPTION "Godot 4 GDExtension for selected XDG Desktop Portal APIs"
    HOMEPAGE_URL "https://github.com/KevinTCoughlin/godot-xdg-portals"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

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

# godot-cpp's headers are third-party and warn under -Wextra -Wpedantic
# (unused parameters in the binder templates, among others). Mark them as
# system headers so the warnings below — and -Werror — apply to this project's
# code only. CMake 3.25's FetchContent SYSTEM would do the same, but the floor
# here is 3.22.
get_target_property(XDG_PORTALS_GODOT_CPP_TARGET godot::cpp ALIASED_TARGET)
if(NOT XDG_PORTALS_GODOT_CPP_TARGET)
    set(XDG_PORTALS_GODOT_CPP_TARGET godot::cpp)
endif()
get_target_property(XDG_PORTALS_GODOT_CPP_INCLUDES
    ${XDG_PORTALS_GODOT_CPP_TARGET} INTERFACE_INCLUDE_DIRECTORIES)
set_target_properties(${XDG_PORTALS_GODOT_CPP_TARGET} PROPERTIES
    INTERFACE_SYSTEM_INCLUDE_DIRECTORIES "${XDG_PORTALS_GODOT_CPP_INCLUDES}")

target_compile_options(xdg_portals PRIVATE
    -Wall -Wextra -Wpedantic
    -Wshadow
    -Wconversion
    -Wsign-conversion
    -Wold-style-cast
    -Wcast-qual
    -Wformat=2
    -Wimplicit-fallthrough
    -Wnon-virtual-dtor
    -Woverloaded-virtual
    -Wnull-dereference
    -Wdouble-promotion
)

# Off by default so a newer compiler's new warning never breaks a user's
# source build. CI turns it on.
option(XDG_PORTALS_WERROR "Treat compiler warnings as errors" OFF)
if(XDG_PORTALS_WERROR)
    target_compile_options(xdg_portals PRIVATE -Werror)
endif()

# AddressSanitizer + UndefinedBehaviorSanitizer for the native smoke test. The
# Godot binary is not instrumented, so the ASan runtime has to be preloaded
# into it; scripts/run_native_smoke.sh --sanitize does that. Linux only.
option(XDG_PORTALS_SANITIZE "Build with AddressSanitizer and UBSan (Linux only)" OFF)
if(XDG_PORTALS_SANITIZE)
    if(NOT XDG_PORTALS_PLATFORM STREQUAL "linux")
        message(FATAL_ERROR "XDG_PORTALS_SANITIZE is supported on Linux only.")
    endif()
    set(XDG_PORTALS_SANITIZER_FLAGS
        -fsanitize=address,undefined
        -fno-sanitize-recover=undefined
        -fno-omit-frame-pointer
    )
    target_compile_options(xdg_portals PRIVATE ${XDG_PORTALS_SANITIZER_FLAGS})
    # GCC records libasan/libubsan as dependencies of the library. Clang would
    # leave the runtime out of a shared library altogether; ask for the shared
    # runtime, with an rpath to it, so the smoke script can find it with ldd.
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        list(APPEND XDG_PORTALS_SANITIZER_FLAGS -shared-libsan -frtlib-add-rpath)
    endif()
    target_link_options(xdg_portals PRIVATE ${XDG_PORTALS_SANITIZER_FLAGS})
endif()

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
