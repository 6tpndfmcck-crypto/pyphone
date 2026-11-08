#import <UIKit/UIKit.h>
#include <Python/Python.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <SDL2/SDL_system.h>
#import "PythonBridge.h"

// These references and all SDL video operations are confined to the main queue.
static UIWindow *editorWindow;
static UIWindow *gameWindow;
static UIButton *gameStop;
static unsigned long gameThread;
static unsigned long gameGeneration;
static NSString *previousRenderer;
static BOOL prepared;
static NSMutableArray *lifecycleObservers;

static void observeLifecycle(NSNotificationName name, void (*callback)(void)) {
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            PyGILState_STATE gil = PyGILState_Ensure();
            if (prepared) callback();
            PyGILState_Release(gil);
        }];
    [lifecycleObservers addObject:observer];
}

static PyObject *callMain(PyObject *self, PyObject *args) {
    PyObject *function, *positional, *keywords;
    if (!PyArg_ParseTuple(args, "OO!O!:call_main", &function,
                         &PyTuple_Type, &positional, &PyDict_Type, &keywords)) return NULL;
    if (!PyCallable_Check(function)) {
        PyErr_SetString(PyExc_TypeError, "call_main requires a callable");
        return NULL;
    }
    if (NSThread.isMainThread) return PyObject_Call(function, positional, keywords);

    __block PyObject *result = NULL;
    __block PyObject *exception = NULL;
    // Release the worker's GIL before dispatching; the UI thread needs it to
    // call Pygame. Move exceptions back to the originating Python thread.
    Py_BEGIN_ALLOW_THREADS
    dispatch_sync(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            PyGILState_STATE gil = PyGILState_Ensure();
            result = PyObject_Call(function, positional, keywords);
            if (!result) exception = PyErr_GetRaisedException();
            PyGILState_Release(gil);
        }
    });
    Py_END_ALLOW_THREADS
    if (exception) PyErr_SetRaisedException(exception);
    return result;
}

static PyObject *prepare(PyObject *self, PyObject *unused) {
    if (prepared) Py_RETURN_NONE;
    prepared = YES;
    if (!editorWindow) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) { editorWindow = window; break; }
            }
            if (editorWindow) break;
        }
    }
    SDL_SetMainReady();
    const char *renderer = SDL_GetHint(SDL_HINT_RENDER_DRIVER);
    previousRenderer = renderer ? [NSString stringWithUTF8String:renderer] : nil;
    SDL_SetHint(SDL_HINT_RENDER_DRIVER, "metal");
    // SwiftUI owns UIApplication and its run loop. Avoid re-entering that run
    // loop while dispatch_sync is executing a Pygame call with the GIL held.
    SDL_iPhoneSetEventPump(SDL_FALSE);
    // Disabling SDL's nested pump also removes its lifecycle observers. Forward
    // notifications explicitly while SwiftUI owns the application run loop.
    lifecycleObservers = [NSMutableArray array];
    observeLifecycle(UIApplicationDidBecomeActiveNotification, SDL_OnApplicationDidBecomeActive);
    observeLifecycle(UIApplicationWillResignActiveNotification, SDL_OnApplicationWillResignActive);
    observeLifecycle(UIApplicationDidEnterBackgroundNotification, SDL_OnApplicationDidEnterBackground);
    observeLifecycle(UIApplicationWillEnterForegroundNotification, SDL_OnApplicationWillEnterForeground);
    observeLifecycle(UIApplicationWillTerminateNotification, SDL_OnApplicationWillTerminate);
    observeLifecycle(UIApplicationDidReceiveMemoryWarningNotification, SDL_OnApplicationDidReceiveMemoryWarning);
    observeLifecycle(UIApplicationDidChangeStatusBarOrientationNotification, SDL_OnApplicationDidChangeStatusBarOrientation);
    Py_RETURN_NONE;
}

@interface PygameStopTarget : NSObject
+ (void)stop:(UIButton *)sender;
@end
@implementation PygameStopTarget
+ (void)stop:(UIButton *)sender {
    sender.enabled = NO;
    unsigned long ident = gameThread;
    unsigned long generation = gameGeneration;
    if (ident) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        PyGILState_STATE gil = PyGILState_Ensure();
        // Cleanup can finish before this control task obtains the GIL. Never
        // interrupt an unrelated script after the game has already closed.
        if (gameThread == ident && gameGeneration == generation) [PythonBridge stopThread:ident];
        PyGILState_Release(gil);
    });
}
@end

static PyObject *show(PyObject *self, PyObject *unused) {
    SDL_Window *window = SDL_GetKeyboardFocus();
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!window || !SDL_GetWindowWMInfo(window, &info) || info.subsystem != SDL_SYSWM_UIKIT) {
        PyErr_SetString(PyExc_RuntimeError, "Pygame did not create an SDL UIKit window");
        return NULL;
    }
    UIWindow *nativeWindow = info.info.uikit.window;
    if (nativeWindow != gameWindow) {
        gameWindow = nativeWindow;
        // SDL2 creates a UIWindow without a scene. Join the existing SwiftUI
        // scene so the window is visible on modern iOS.
        if (editorWindow.windowScene && gameWindow.windowScene != editorWindow.windowScene) {
            gameWindow.hidden = YES;
            gameWindow.windowScene = editorWindow.windowScene;
        }
        UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
        gameStop = stop;
        [stop setTitle:@"Stop game" forState:UIControlStateNormal];
        stop.accessibilityIdentifier = @"pygameStopButton";
        stop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        [stop setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        stop.layer.cornerRadius = 10;
        stop.translatesAutoresizingMaskIntoConstraints = NO;
        [stop addTarget:PygameStopTarget.class action:@selector(stop:) forControlEvents:UIControlEventTouchUpInside];
        [gameWindow addSubview:stop];
        [NSLayoutConstraint activateConstraints:@[
            [stop.topAnchor constraintEqualToAnchor:gameWindow.safeAreaLayoutGuide.topAnchor constant:8],
            [stop.trailingAnchor constraintEqualToAnchor:gameWindow.safeAreaLayoutGuide.trailingAnchor constant:-12],
            [stop.widthAnchor constraintEqualToConstant:112],
            [stop.heightAnchor constraintEqualToConstant:44],
        ]];
    }
    // SDL can replace its controller's view when set_mode recreates a renderer.
    // Keep the Stop control above that view even when the UIWindow is reused.
    [gameWindow bringSubviewToFront:gameStop];
    [gameWindow makeKeyAndVisible];
    Py_RETURN_NONE;
}

static PyObject *restore(PyObject *self, PyObject *unused) {
    if (!prepared) Py_RETURN_NONE;
    prepared = NO;
    gameWindow.hidden = YES;
    gameWindow = nil;
    gameStop = nil;
    [editorWindow makeKeyAndVisible];
    editorWindow = nil;
    gameThread = 0;
    gameGeneration++;
    if (previousRenderer) SDL_SetHint(SDL_HINT_RENDER_DRIVER, previousRenderer.UTF8String);
    else SDL_ResetHint(SDL_HINT_RENDER_DRIVER);
    previousRenderer = nil;
    for (id observer in lifecycleObservers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    lifecycleObservers = nil;
    SDL_iPhoneSetEventPump(SDL_TRUE);
    Py_RETURN_NONE;
}

static PyObject *setThread(PyObject *self, PyObject *arg) {
    unsigned long ident = PyLong_AsUnsignedLong(arg);
    if (PyErr_Occurred()) return NULL;
    gameThread = ident;
    gameGeneration++;
    Py_RETURN_NONE;
}

static PyMethodDef methods[] = {
    {"call_main", callMain, METH_VARARGS, "Run an SDL operation on the UIKit thread."},
    {"prepare", prepare, METH_NOARGS, "Prepare embedded SDL and remember the editor window."},
    {"show", show, METH_NOARGS, "Show SDL's window in the active iOS scene."},
    {"restore", restore, METH_NOARGS, "Restore the editor window."},
    {"set_thread", setThread, METH_O, "Set the thread interrupted by Stop game."},
    {NULL, NULL, 0, NULL},
};
static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "_pyphone_pygame", NULL, -1, methods};
PyMODINIT_FUNC PyInit__pyphone_pygame(void) { return PyModule_Create(&module); }
