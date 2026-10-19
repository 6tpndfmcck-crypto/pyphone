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
    NSString *res = NSBundle.mainBundle.resourcePath;
    NSString *home = [res stringByAppendingPathComponent:@"python"];
    NSString *app = [res stringByAppendingPathComponent:@"App"];

    // Find the stdlib folder (python/lib/python3.x) and report clearly if it is missing.
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *libDir = [home stringByAppendingPathComponent:@"lib"];
    NSArray *items = [fm contentsOfDirectoryAtPath:libDir error:nil];
    NSString *ver = nil;
    for (NSString *i in items) if ([i hasPrefix:@"python3."]) ver = i;
    if (!ver) {
        return [NSString stringWithFormat:@"stdlib missing: no python3.x in %@ (found: %@)",
                libDir, items ? [items componentsJoinedByString:@", "] : @"folder does not exist"];
    }
    NSString *stdlib = [libDir stringByAppendingPathComponent:ver];
    if (![fm fileExistsAtPath:[stdlib stringByAppendingPathComponent:@"encodings"]]) {
        return [NSString stringWithFormat:@"stdlib incomplete: no encodings in %@", stdlib];
    }
    NSString *dynload = [stdlib stringByAppendingPathComponent:@"lib-dynload"];

    PyStatus status;
    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    status = Py_PreInitialize(&pre);
    if (PyStatus_Exception(status)) {
        return [NSString stringWithFormat:@"preinit: %s", status.err_msg ?: "unknown"];
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

    // Set the module search path explicitly instead of relying on auto-detection.
    config.module_search_paths_set = 1;
    for (NSString *p in @[stdlib, dynload]) {
        wchar_t *w = Py_DecodeLocale(p.UTF8String, NULL);
        if (!w) {
            PyConfig_Clear(&config);
            return @"config: could not decode a module path";
        }
        status = PyWideStringList_Append(&config.module_search_paths, w);
        PyMem_RawFree(w);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return [NSString stringWithFormat:@"config paths: %s", status.err_msg ?: "unknown"];
        }
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        return [NSString stringWithFormat:@"init: %s", status.err_msg ?: "unknown"];
    }

    NSString *cmd = [NSString stringWithFormat:@"import sys\nsys.path.insert(0, \"%@\")\n", app];
    if (PyRun_SimpleString(cmd.UTF8String) != 0) {
        return @"could not set module path";
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
