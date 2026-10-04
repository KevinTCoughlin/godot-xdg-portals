// SPDX-FileCopyrightText: 2026 Kevin Coughlin
//
// SPDX-License-Identifier: MIT

// Preloaded into Godot, ahead of the ASan runtime, by
// `scripts/run_native_smoke.sh --sanitize`. Test harness only; never shipped.
//
// It does two things, both needed only because Godot itself is not built with
// sanitizers:
//
// 1. Godot opens GDExtension libraries with RTLD_DEEPBIND (unless Godot was
//    itself built with sanitizers), and the ASan runtime refuses to load any
//    library opened that way, since a deep-bound library would bypass ASan's
//    malloc and free interceptors
//    (https://github.com/google/sanitizers/issues/611). This dlopen() strips
//    the flag and forwards to the next dlopen() in lookup order, which is
//    ASan's interceptor. Without DEEPBIND the extension's symbols bind in
//    global order instead; the Godot executable exports no godot-cpp symbols,
//    so that changes nothing the smoke test can observe.
//
// 2. dlclose() is a no-op. Godot unloads extensions before exit, and
//    LeakSanitizer runs after that, so the extension's frames in a leak report
//    would otherwise print as `<unknown module>`. Keeping it mapped is what
//    makes a report point at a line in src/.
//
// 3. It removes LD_PRELOAD from the environment once the process has loaded,
//    so that helper processes Godot spawns (it runs `sh` during startup) do
//    not inherit a sanitizer runtime they were never built for.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>

typedef void *(*dlopen_fn)(const char *, int);

void *dlopen(const char *p_file, int p_mode) {
	static dlopen_fn next = NULL;
	if (next == NULL) {
		next = (dlopen_fn)dlsym(RTLD_NEXT, "dlopen");
	}
	return next(p_file, p_mode & ~RTLD_DEEPBIND);
}

int dlclose(void *p_handle) {
	(void)p_handle;
	return 0;
}

__attribute__((constructor)) static void forget_preload(void) {
	unsetenv("LD_PRELOAD");
}
