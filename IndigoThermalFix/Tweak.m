#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/log.h>

#ifndef DEFAULT_TARGET_FPS
#define DEFAULT_TARGET_FPS 30
#endif

// Log helper
static os_log_t get_log(void) {
    static os_log_t log = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.adobelabs.bonsai.thermalfix", "IndigoThermalFix");
    });
    return log;
}

#define LOG(fmt, ...) do { \
    os_log(get_log(), "[IndigoThermalFix] " fmt, ##__VA_ARGS__); \
    NSLog(@"[IndigoThermalFix] " fmt, ##__VA_ARGS__); \
} while(0)

// Configurable target FPS (defaults to 30, can be overridden via NSUserDefaults @"IndigoTargetFPS")
static NSInteger get_target_fps(void) {
    static NSInteger targetFPS = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNumber *val = [[NSUserDefaults standardUserDefaults] objectForKey:@"IndigoTargetFPS"];
        if (val && [val integerValue] > 0) {
            targetFPS = [val integerValue];
        } else {
            targetFPS = DEFAULT_TARGET_FPS;
        }
        LOG("Configured target viewfinder frame rate: %ld FPS", (long)targetFPS);
    });
    return targetFPS;
}

// Function to apply frame rate limit to MTKView and its backing layer
static void apply_viewfinder_fps_cap(MTKView *view) {
    if (!view || ![view isKindOfClass:[MTKView class]]) return;

    NSInteger targetFPS = get_target_fps();

    // 1. Cap MTKView preferredFramesPerSecond
    if (view.preferredFramesPerSecond != targetFPS) {
        view.preferredFramesPerSecond = targetFPS;
        LOG("Set preferredFramesPerSecond = %ld on MTKView %p", (long)targetFPS, view);
    }

    // 2. On iOS 15+ ProMotion displays, configure CAFrameRateRange
    if (@available(iOS 15.0, *)) {
        float minFps = (targetFPS < 30) ? (float)targetFPS : 30.0f;
        float maxFps = (float)targetFPS;
        float prefFps = (float)targetFPS;
        CAFrameRateRange range = CAFrameRateRangeMake(minFps, maxFps, prefFps);

        if ([view respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
            view.preferredFrameRateRange = range;
            LOG("Set MTKView.preferredFrameRateRange = (min: %.1f, max: %.1f, pref: %.1f) on %p",
                minFps, maxFps, prefFps, view);
        }

        // Also enforce range on backing CAMetalLayer
        CALayer *layer = view.layer;
        if (layer && [layer respondsToSelector:@selector(setPreferredFrameRateRange:)]) {
            layer.preferredFrameRateRange = range;
            LOG("Set CALayer.preferredFrameRateRange = (min: %.1f, max: %.1f, pref: %.1f) on layer %p",
                minFps, maxFps, prefFps, layer);
        }
    }
}

// -----------------------------------------------------------------------------
// Method Swizzling
// -----------------------------------------------------------------------------

static void safe_swizzle(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel || !newImp || !origImp) return;
    Method origMethod = class_getInstanceMethod(cls, sel);
    if (!origMethod) return;

    const char *types = method_getTypeEncoding(origMethod);
    if (class_addMethod(cls, sel, newImp, types)) {
        *origImp = method_getImplementation(origMethod);
    } else {
        *origImp = method_setImplementation(origMethod, newImp);
    }
}

// Hook -[MTKView setDelegate:]
static void (*orig_MTKView_setDelegate)(MTKView *self, SEL _cmd, id<MTKViewDelegate> delegate);
static void hook_MTKView_setDelegate(MTKView *self, SEL _cmd, id<MTKViewDelegate> delegate) {
    orig_MTKView_setDelegate(self, _cmd, delegate);
    apply_viewfinder_fps_cap(self);
}

// Hook -[MTKView setPaused:]
static void (*orig_MTKView_setPaused)(MTKView *self, SEL _cmd, BOOL paused);
static void hook_MTKView_setPaused(MTKView *self, SEL _cmd, BOOL paused) {
    orig_MTKView_setPaused(self, _cmd, paused);
    if (!paused) {
        apply_viewfinder_fps_cap(self);
    }
}

// Hook -[MTKView initWithFrame:device:]
static instancetype (*orig_MTKView_initWithFrame_device)(MTKView *self, SEL _cmd, CGRect frame, id<MTLDevice> device);
static instancetype hook_MTKView_initWithFrame_device(MTKView *self, SEL _cmd, CGRect frame, id<MTLDevice> device) {
    MTKView *view = orig_MTKView_initWithFrame_device(self, _cmd, frame, device);
    if (view) {
        apply_viewfinder_fps_cap(view);
    }
    return view;
}

// Hook -[MTKView init]
static instancetype (*orig_MTKView_init)(MTKView *self, SEL _cmd);
static instancetype hook_MTKView_init(MTKView *self, SEL _cmd) {
    MTKView *view = orig_MTKView_init(self, _cmd);
    if (view) {
        apply_viewfinder_fps_cap(view);
    }
    return view;
}

// Hook -[MTKView didMoveToWindow]
static void (*orig_MTKView_didMoveToWindow)(MTKView *self, SEL _cmd);
static void hook_MTKView_didMoveToWindow(MTKView *self, SEL _cmd) {
    orig_MTKView_didMoveToWindow(self, _cmd);
    if (self.window != nil) {
        apply_viewfinder_fps_cap(self);
    }
}

// Hook -[MTKView setPreferredFramesPerSecond:]
static void (*orig_MTKView_setPreferredFramesPerSecond)(MTKView *self, SEL _cmd, NSInteger fps);
static void hook_MTKView_setPreferredFramesPerSecond(MTKView *self, SEL _cmd, NSInteger fps) {
    NSInteger maxAllowed = get_target_fps();
    NSInteger clamped = (fps > maxAllowed) ? maxAllowed : fps;
    if (clamped <= 0) clamped = maxAllowed;
    orig_MTKView_setPreferredFramesPerSecond(self, _cmd, clamped);
}

// Hook -[MTKView setPreferredFrameRateRange:]
static void (*orig_MTKView_setPreferredFrameRateRange)(MTKView *self, SEL _cmd, CAFrameRateRange range);
static void hook_MTKView_setPreferredFrameRateRange(MTKView *self, SEL _cmd, CAFrameRateRange range) {
    if (@available(iOS 15.0, *)) {
        NSInteger maxAllowed = get_target_fps();
        if (range.maximum > maxAllowed) {
            range.maximum = (float)maxAllowed;
        }
        if (range.preferred > maxAllowed) {
            range.preferred = (float)maxAllowed;
        }
    }
    orig_MTKView_setPreferredFrameRateRange(self, _cmd, range);
}

// -----------------------------------------------------------------------------
// Constructor Entry Point
// -----------------------------------------------------------------------------

__attribute__((constructor)) static void init_indigo_thermal_fix(void) {
    @autoreleasepool {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
        LOG("Initialized in process %d (%@)", pid, bundleId);

        Class mtkViewClass = objc_getClass("MTKView");
        if (!mtkViewClass) {
            // Attempt to load MetalKit framework if not yet loaded
            [[NSBundle bundleWithPath:@"/System/Library/Frameworks/MetalKit.framework"] load];
            mtkViewClass = objc_getClass("MTKView");
        }

        if (!mtkViewClass) {
            LOG("ERROR: MTKView class could not be resolved. Swizzling aborted.");
            return;
        }

        safe_swizzle(mtkViewClass, @selector(setDelegate:),
                     (IMP)hook_MTKView_setDelegate,
                     (IMP *)&orig_MTKView_setDelegate);

        safe_swizzle(mtkViewClass, @selector(setPaused:),
                     (IMP)hook_MTKView_setPaused,
                     (IMP *)&orig_MTKView_setPaused);

        safe_swizzle(mtkViewClass, @selector(initWithFrame:device:),
                     (IMP)hook_MTKView_initWithFrame_device,
                     (IMP *)&orig_MTKView_initWithFrame_device);

        safe_swizzle(mtkViewClass, @selector(init),
                     (IMP)hook_MTKView_init,
                     (IMP *)&orig_MTKView_init);

        safe_swizzle(mtkViewClass, @selector(didMoveToWindow),
                     (IMP)hook_MTKView_didMoveToWindow,
                     (IMP *)&orig_MTKView_didMoveToWindow);

        safe_swizzle(mtkViewClass, @selector(setPreferredFramesPerSecond:),
                     (IMP)hook_MTKView_setPreferredFramesPerSecond,
                     (IMP *)&orig_MTKView_setPreferredFramesPerSecond);

        if (@available(iOS 15.0, *)) {
            safe_swizzle(mtkViewClass, @selector(setPreferredFrameRateRange:),
                         (IMP)hook_MTKView_setPreferredFrameRateRange,
                         (IMP *)&orig_MTKView_setPreferredFrameRateRange);
        }

        LOG("Successfully hooked MTKView methods. Viewfinder frame rate capped at %ld FPS.",
            (long)get_target_fps());
    }
}
