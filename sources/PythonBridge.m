#import "PythonBridge.h"
#include <Python/Python.h>

static NSString *exceptionText(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (!exc) return @"unknown Python error";
    NSString *out = @"Python error";
    PyObject *s = PyObject_Str(exc);
    if (s) {
        const char *c = PyUnicode_AsUTF8(s);
        if (c) out = [NSString stringWithUTF8String:c];
        Py_DECREF(s);
    } else {
        PyErr_Clear();
    }
    Py_DECREF(exc);
    return out;
}

@implementation PythonBridge

+ (NSString *)start {
    NSFileManager *fm = NSFileManager.defaultManager;

    // Find the app folder that actually holds python/lib. Try the main bundle,
    // the bundle this class was loaded from, and the executable's folder, since
    // apps run inside another container can report different paths.
    NSMutableArray<NSString *> *bases = [NSMutableArray array];
    NSArray<NSString *> *cands = @[
        NSBundle.mainBundle.resourcePath ?: @"",
        [NSBundle bundleForClass:self.class].resourcePath ?: @"",
        [NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent] ?: @"",
        NSBundle.mainBundle.bundlePath ?: @"",
    ];
    for (NSString *c in cands) {
        if (c.length && ![bases containsObject:c]) [bases addObject:c];
    }
    NSString *res = nil;
    for (NSString *b in bases) {
        if ([fm fileExistsAtPath:[b stringByAppendingPathComponent:@"python/lib"]]) { res = b; break; }
    }
    if (!res) {
        return [NSString stringWithFormat:@"python folder not found in %@", bases];
    }
    NSString *home = [res stringByAppendingPathComponent:@"python"];
    NSString *app = [res stringByAppendingPathComponent:@"app"];
    // Xcode copies the app/ folder reference with its original lowercase name.

    // Find the standard library folder, e.g. python/lib/python3.13
    NSString *libDir = [home stringByAppendingPathComponent:@"lib"];
    NSArray<NSString *> *libItems = [fm contentsOfDirectoryAtPath:libDir error:nil];
    NSString *ver = nil;
    for (NSString *item in libItems) {
        if ([item hasPrefix:@"python3"]) { ver = item; break; }
    }
    if (!ver) {
        return [NSString stringWithFormat:@"no stdlib found in app (python/lib = %@)", libItems ?: @[]];
    }
    NSString *stdlib = [libDir stringByAppendingPathComponent:ver];
    NSString *dynload = [stdlib stringByAppendingPathComponent:@"lib-dynload"];
    NSString *runnerFile = [app stringByAppendingPathComponent:@"runner.py"];
    NSString *encodingsFile = [stdlib stringByAppendingPathComponent:@"encodings/__init__.py"];
    BOOL hasEnc = [fm fileExistsAtPath:encodingsFile];
    NSString *diag = [NSString stringWithFormat:@"[%@ encodings=%d dynload=%d runner=%d]",
                      ver,
                      hasEnc,
                      [fm fileExistsAtPath:dynload],
                      [fm fileExistsAtPath:runnerFile]];
    if (!hasEnc) {
        return [NSString stringWithFormat:@"Python standard library is incomplete: %@ %@", encodingsFile, diag];
    }
    if (![fm fileExistsAtPath:dynload]) {
        return [NSString stringWithFormat:@"Python native modules folder is missing: %@ %@", dynload, diag];
    }
    if (![fm fileExistsAtPath:runnerFile]) {
        return [NSString stringWithFormat:@"Python app runner is missing: %@ %@", runnerFile, diag];
    }

    PyStatus status;
    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    status = Py_PreInitialize(&pre);
    if (PyStatus_Exception(status)) {
        return [NSString stringWithFormat:@"preinit: %s %@", status.err_msg ?: "unknown", diag];
    }

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;

    status = PyConfig_SetBytesString(&config, &config.home, home.UTF8String);
    if (PyStatus_Exception(status)) {
        PyConfig_Clear(&config);
        return [NSString stringWithFormat:@"config: %s", status.err_msg ?: "unknown"];
    }
    // Use only the paths packaged with this app. PyConfig_Read() would first
    // populate module_search_paths with inferred defaults; appending our paths
    // after that can make imports depend on paths that are not in the bundle.
    // With module_search_paths_set enabled on the fresh isolated config,
    // CPython calculates its prefix metadata but keeps this explicit list.
    config.module_search_paths_set = 1;
    NSString *pkgs = [res stringByAppendingPathComponent:@"app_packages"];
    NSArray<NSString *> *paths = @[stdlib, dynload, app, pkgs];
    for (NSString *p in paths) {
        wchar_t *w = Py_DecodeLocale(p.UTF8String, NULL);
        if (w == NULL) {
            PyConfig_Clear(&config);
            return [NSString stringWithFormat:@"could not convert Python import path to Unicode: %@", p];
        }
        status = PyWideStringList_Append(&config.module_search_paths, w);
        PyMem_RawFree(w);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return [NSString stringWithFormat:@"path: %s", status.err_msg ?: "unknown"];
        }
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        return [NSString stringWithFormat:@"init: %s %@", status.err_msg ?: "unknown", diag];
    }

    PyObject *m = PyImport_ImportModule("runner");
    if (!m) {
        return [@"runner import failed: " stringByAppendingString:exceptionText()];
    }
    Py_DECREF(m);

    // Release the lock so later calls can take it from any thread.
    PyEval_SaveThread();
    return nil;
}

+ (NSString *)call:(NSString *)function arg:(NSString *)arg {
    PyGILState_STATE g = PyGILState_Ensure();
    NSString *result = @"";
    PyObject *mod = PyImport_ImportModule("runner");
    if (!mod) {
        result = [@"error: " stringByAppendingString:exceptionText()];
    } else {
        PyObject *r = PyObject_CallMethod(mod, function.UTF8String, "s", arg.UTF8String);
        if (!r) {
            result = [@"error: " stringByAppendingString:exceptionText()];
        } else {
            const char *c = PyUnicode_AsUTF8(r);
            if (c) result = [NSString stringWithUTF8String:c] ?: @"";
            Py_DECREF(r);
        }
        Py_DECREF(mod);
    }
    PyGILState_Release(g);
    return result;
}

+ (void)stopThread:(unsigned long)ident {
    PyGILState_STATE g = PyGILState_Ensure();
    PyThreadState_SetAsyncExc(ident, PyExc_KeyboardInterrupt);
    PyGILState_Release(g);
}

@end
