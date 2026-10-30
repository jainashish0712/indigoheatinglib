#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreML/CoreML.h>
#import <mach/mach.h>
#import <mach/thread_act.h>
#import <stdatomic.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#ifndef DEFAULT_TARGET_FPS
#define DEFAULT_TARGET_FPS 30
#endif

// Safe CAFrameRateRange definition if sub-header is not explicitly present
#if __has_include(<QuartzCore/CAFrameRateRange.h>)
#import <QuartzCore/CAFrameRateRange.h>
#else
typedef struct {
    float minimum;
    float maximum;
    float preferred;
} CAFrameRateRange;

static inline CAFrameRateRange CAFrameRateRangeMake(float minimum, float maximum, float preferred) {
    CAFrameRateRange range;
    range.minimum = minimum;
    range.maximum = maximum;
    range.preferred = preferred;
    return range;
}
#endif

// Unified OS log helper
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

// -----------------------------------------------------------------------------
// Real-Time CPU & GPU Usage Tracking Engine
// -----------------------------------------------------------------------------

static atomic_int g_active_capture_count = 0;
static atomic_uint_fast64_t g_gpu_time_ns = 0;
static CFTimeInterval g_last_gpu_sample_time = 0.0;
static const char *kModelFileNameKey = "kModelFileName";

static void record_gpu_duration(double duration_seconds) {
    if (duration_seconds <= 0.0 || duration_seconds > 2.0) return;
    uint64_t ns = (uint64_t)(duration_seconds * 1e9);
    atomic_fetch_add(&g_gpu_time_ns, ns);
}

static float get_process_cpu_usage(void) {
    kern_return_t kr;
    thread_array_t thread_list;
    mach_msg_type_number_t thread_count;

    kr = task_threads(mach_task_self(), &thread_list, &thread_count);
    if (kr != KERN_SUCCESS) {
        return 0.0f;
    }

    float total_cpu = 0.0f;
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        thread_info_data_t thinfo;
        mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
        kr = thread_info(thread_list[i], THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if (kr == KERN_SUCCESS) {
            thread_basic_info_t basic_info_th = (thread_basic_info_t)thinfo;
            if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
                total_cpu += (basic_info_th->cpu_usage / (float)TH_USAGE_SCALE) * 100.0f;
            }
        }
    }

    vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_act_t));

    // Normalize aggregate CPU load across active processor cores
    static NSUInteger coreCount = 0;
    static dispatch_once_t coreOnce;
    dispatch_once(&coreOnce, ^{
        coreCount = [[NSProcessInfo processInfo] activeProcessorCount];
        if (coreCount == 0) coreCount = 1;
    });

    float normalized = total_cpu / (float)coreCount;
    if (normalized > 100.0f) normalized = 100.0f;
    if (normalized < 0.0f) normalized = 0.0f;
    return normalized;
}

static float get_process_gpu_usage(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (g_last_gpu_sample_time <= 0.0) {
        g_last_gpu_sample_time = now;
        atomic_store(&g_gpu_time_ns, 0);
        return 0.0f;
    }

    CFTimeInterval elapsed = now - g_last_gpu_sample_time;
    g_last_gpu_sample_time = now;
    if (elapsed <= 0.0) return 0.0f;

    uint64_t total_ns = atomic_exchange(&g_gpu_time_ns, 0);
    double active_seconds = (double)total_ns / 1e9;
    float gpu_pct = (float)((active_seconds / elapsed) * 100.0);
    if (gpu_pct > 100.0f) gpu_pct = 100.0f;
    if (gpu_pct < 0.0f) gpu_pct = 0.0f;
    return gpu_pct;
}

// -----------------------------------------------------------------------------
// On-Screen Performance Badge HUD Overlay
// -----------------------------------------------------------------------------

static UIView *g_badge_container = nil;
static UILabel *g_badge_label = nil;

static void update_badge_ui(void) {
    if (!g_badge_label || !g_badge_container) return;

    float cpu = get_process_cpu_usage();
    float gpu = get_process_gpu_usage();
    BOOL isCapturing = (atomic_load(&g_active_capture_count) > 0);

    if (isCapturing) {
        g_badge_label.text = [NSString stringWithFormat:@"CPU: %.0f%% | GPU: %.0f%% 📸", cpu, gpu];
        g_badge_container.backgroundColor = [UIColor colorWithRed:0.10f green:0.25f blue:0.15f alpha:0.80f];
    } else {
        g_badge_label.text = [NSString stringWithFormat:@"CPU: %.0f%% | GPU: %.0f%%", cpu, gpu];
        g_badge_container.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.65f];
    }
}

static void attach_badge_to_window(UIWindow *window) {
    if (!window || ![window isKindOfClass:[UIWindow class]]) return;
    if (g_badge_container && g_badge_container.superview == window) {
        [window bringSubviewToFront:g_badge_container];
        return;
    }

    if (!g_badge_container) {
        CGFloat badgeWidth = 148.0f;
        CGFloat badgeHeight = 24.0f;

        CGFloat screenWidth = window.bounds.size.width;
        if (screenWidth <= 0) screenWidth = [UIScreen mainScreen].bounds.size.width;

        CGFloat topY = 52.0f;
        if (@available(iOS 11.0, *)) {
            if (window.safeAreaInsets.top > 0) {
                topY = window.safeAreaInsets.top + 4.0f;
            }
        }

        CGRect frame = CGRectMake(screenWidth - badgeWidth - 12.0f, topY, badgeWidth, badgeHeight);
        g_badge_container = [[UIView alloc] initWithFrame:frame];
        g_badge_container.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.65f];
        g_badge_container.layer.cornerRadius = badgeHeight / 2.0f;
        g_badge_container.layer.masksToBounds = YES;
        g_badge_container.layer.borderWidth = 0.5f;
        g_badge_container.layer.borderColor = [UIColor colorWithWhite:1.0f alpha:0.25f].CGColor;
        g_badge_container.userInteractionEnabled = NO;
        g_badge_container.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

        g_badge_label = [[UILabel alloc] initWithFrame:g_badge_container.bounds];
        g_badge_label.backgroundColor = [UIColor clearColor];
        g_badge_label.textColor = [UIColor whiteColor];
        g_badge_label.textAlignment = NSTextAlignmentCenter;
        if (@available(iOS 13.0, *)) {
            g_badge_label.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
        } else {
            g_badge_label.font = [UIFont boldSystemFontOfSize:11.0];
        }
        g_badge_label.text = @"CPU: --% | GPU: --%";
        g_badge_label.userInteractionEnabled = NO;
        g_badge_label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [g_badge_container addSubview:g_badge_label];

        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0
                                                repeats:YES
                                                  block:^(NSTimer * _Nonnull t) {
            (void)t;
            update_badge_ui();
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        LOG("Initialized on-screen CPU/GPU performance badge HUD.");
    }

    if (g_badge_container.superview != window) {
        [g_badge_container removeFromSuperview];
        [window addSubview:g_badge_container];
    }
    [window bringSubviewToFront:g_badge_container];
}

// -----------------------------------------------------------------------------
// Viewfinder MTKView FPS Cap (Downstream Consumer)
// -----------------------------------------------------------------------------

static void apply_viewfinder_fps_cap(MTKView *view) {
    if (!view || ![view isKindOfClass:[MTKView class]]) return;

    NSInteger targetFPS = get_target_fps();

    // 1. Cap MTKView preferredFramesPerSecond (Standard MTKView property available since iOS 9.0)
    if (view.preferredFramesPerSecond != targetFPS) {
        view.preferredFramesPerSecond = targetFPS;
        LOG("Set preferredFramesPerSecond = %ld on MTKView %p", (long)targetFPS, (__bridge void *)view);
    }

    // 2. On iOS 15+ ProMotion displays, configure CAFrameRateRange dynamically via objc_msgSend
    if (@available(iOS 15.0, *)) {
        float minFps = (targetFPS < 30) ? (float)targetFPS : 30.0f;
        float maxFps = (float)targetFPS;
        float prefFps = (float)targetFPS;
        CAFrameRateRange range = CAFrameRateRangeMake(minFps, maxFps, prefFps);
        SEL setRangeSel = sel_registerName("setPreferredFrameRateRange:");

        // Enforce range on MTKView if supported
        if ([view respondsToSelector:setRangeSel]) {
            void (*setMtkRange)(id, SEL, CAFrameRateRange) = (void (*)(id, SEL, CAFrameRateRange))objc_msgSend;
            setMtkRange(view, setRangeSel, range);
            LOG("Set MTKView.preferredFrameRateRange = (min: %.1f, max: %.1f, pref: %.1f) on %p",
                minFps, maxFps, prefFps, (__bridge void *)view);
        }

        // Also enforce range on backing CAMetalLayer if supported
        CALayer *layer = view.layer;
        if (layer && [layer respondsToSelector:setRangeSel]) {
            void (*setLayerRange)(id, SEL, CAFrameRateRange) = (void (*)(id, SEL, CAFrameRateRange))objc_msgSend;
            setLayerRange(layer, setRangeSel, range);
            LOG("Set CALayer.preferredFrameRateRange = (min: %.1f, max: %.1f, pref: %.1f) on layer %p",
                minFps, maxFps, prefFps, (__bridge void *)layer);
        }
    }
}

// -----------------------------------------------------------------------------
// AVFoundation Camera Sensor & Preview Stream FPS Cap (Upstream Producer)
// -----------------------------------------------------------------------------

static void apply_device_fps_cap(AVCaptureDevice *device, NSInteger targetFPS) {
    if (!device) return;
    if (![device hasMediaType:AVMediaTypeVideo]) return;

    CMTime frameDuration = CMTimeMake(1, (int32_t)targetFPS);
    NSError *error = nil;
    if ([device lockForConfiguration:&error]) {
        @try {
            BOOL supported = NO;
            for (AVFrameRateRange *range in device.activeFormat.videoSupportedFrameRateRanges) {
                if (range.minFrameRate <= (Float64)targetFPS && (Float64)targetFPS <= range.maxFrameRate) {
                    supported = YES;
                    break;
                }
            }
            if (supported) {
                device.activeVideoMinFrameDuration = frameDuration;
                device.activeVideoMaxFrameDuration = frameDuration;
                LOG("Set AVCaptureDevice %p frame duration to 1/%ld s (%ld FPS)",
                    (__bridge void *)device, (long)targetFPS, (long)targetFPS);
            } else {
                LOG("AVCaptureDevice %p format does not support %ld FPS directly",
                    (__bridge void *)device, (long)targetFPS);
            }
        } @catch (NSException *e) {
            LOG("Exception while setting AVCaptureDevice %p frame duration: %@",
                (__bridge void *)device, e.reason);
        }
        [device unlockForConfiguration];
    } else {
        LOG("Could not lock AVCaptureDevice %p: %@",
            (__bridge void *)device, error ? [error localizedDescription] : @"unknown");
    }
}

static void apply_video_output_settings(AVCaptureVideoDataOutput *output) {
    if (!output || ![output isKindOfClass:[AVCaptureVideoDataOutput class]]) return;

    if (!output.alwaysDiscardsLateVideoFrames) {
        output.alwaysDiscardsLateVideoFrames = YES;
        LOG("Set alwaysDiscardsLateVideoFrames = YES on AVCaptureVideoDataOutput %p",
            (__bridge void *)output);
    }
}

static void apply_session_fps_cap(AVCaptureSession *session) {
    if (!session || ![session isKindOfClass:[AVCaptureSession class]]) return;

    NSInteger targetFPS = get_target_fps();

    // 1. Cap each video capture device input to physically limit sensor ISP readout
    for (AVCaptureInput *input in session.inputs) {
        if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
            apply_device_fps_cap(((AVCaptureDeviceInput *)input).device, targetFPS);
        }
    }

    // 2. Configure each video data output feeding preview demosaic
    for (AVCaptureOutput *output in session.outputs) {
        if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
            apply_video_output_settings((AVCaptureVideoDataOutput *)output);
        }
    }
}

// -----------------------------------------------------------------------------
// CoreML Hardware Acceleration & In-Depth ComputeUnit Logging
// -----------------------------------------------------------------------------

static __thread BOOL g_in_prediction_log = NO;

static void log_coreml_inference(MLModel *model) {
    MLModelConfiguration *config = model.configuration;
    MLComputeUnits units = config ? config.computeUnits : MLComputeUnitsCPUOnly;

    const char *unitDesc = "Unknown";
    const char *cpuOnlyAnswer = "YES (WARNING: running on CPU only!)";

    switch (units) {
        case MLComputeUnitsAll: // 0
            unitDesc = "MLComputeUnitsAll (Apple Neural Engine [ANE] + GPU + CPU)";
            cpuOnlyAnswer = "NO (Hardware acceleration active on Apple Neural Engine / GPU)";
            break;
        case MLComputeUnitsCPUOnly: // 1
            unitDesc = "MLComputeUnitsCPUOnly (CPU ONLY)";
            cpuOnlyAnswer = "YES (cpuOnly is active! Warning: No ANE acceleration)";
            break;
        case MLComputeUnitsCPUAndGPU: // 2
            unitDesc = "MLComputeUnitsCPUAndGPU (GPU + CPU)";
            cpuOnlyAnswer = "NO (Hardware acceleration active on GPU)";
            break;
        case 3: // MLComputeUnitsCPUAndNeuralEngine
            unitDesc = "MLComputeUnitsCPUAndNeuralEngine (Apple Neural Engine [ANE] + CPU)";
            cpuOnlyAnswer = "NO (Hardware acceleration active on Apple Neural Engine)";
            break;
        default:
            unitDesc = "Custom";
            cpuOnlyAnswer = (units == MLComputeUnitsCPUOnly) ? "YES" : "NO";
            break;
    }

    NSString *modelName = objc_getAssociatedObject(model, kModelFileNameKey);
    if (!modelName && model.modelDescription && model.modelDescription.metadata) {
        modelName = model.modelDescription.metadata[MLModelDescriptionKey];
    }
    if (!modelName) {
        modelName = NSStringFromClass([model class]);
    }

    LOG("🧠 >>> PROCESSING CoreML Model: '%@'", modelName);
    LOG("    ├─ Configured computeUnits: %ld [%s]", (long)units, unitDesc);
    LOG("    └─ Is cpuOnly used? -> %s", cpuOnlyAnswer);
}

// Hook -[MLModelConfiguration setComputeUnits:]
static void (*orig_MLModelConfiguration_setComputeUnits)(MLModelConfiguration *self, SEL _cmd, MLComputeUnits units);
static void hook_MLModelConfiguration_setComputeUnits(MLModelConfiguration *self, SEL _cmd, MLComputeUnits units) {
    if (units == MLComputeUnitsCPUOnly) {
        LOG("Intercepted MLModelConfiguration.setComputeUnits(CPUOnly) -> Overriding to MLComputeUnitsAll (Apple Neural Engine + GPU + CPU)");
        units = MLComputeUnitsAll;
    }
    orig_MLModelConfiguration_setComputeUnits(self, _cmd, units);
}

// Hook +[MLModel modelWithContentsOfURL:configuration:error:]
static MLModel *(*orig_MLModel_modelWithContentsOfURL_configuration_error)(Class self, SEL _cmd, NSURL *url, MLModelConfiguration *configuration, NSError * __autoreleasing *error);
static MLModel *hook_MLModel_modelWithContentsOfURL_configuration_error(Class self, SEL _cmd, NSURL *url, MLModelConfiguration *configuration, NSError * __autoreleasing *error) {
    if (configuration && configuration.computeUnits == MLComputeUnitsCPUOnly) {
        LOG("MLModel loading from %@ with CPUOnly -> Overriding computeUnits to MLComputeUnitsAll (Apple Neural Engine)", url ? url.lastPathComponent : @"unknown");
        configuration.computeUnits = MLComputeUnitsAll;
    }
    MLModel *model = orig_MLModel_modelWithContentsOfURL_configuration_error(self, _cmd, url, configuration, error);
    if (model && url) {
        objc_setAssociatedObject(model, kModelFileNameKey, url.lastPathComponent, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return model;
}

// Hook -[MLModel initWithContentsOfURL:configuration:error:]
static MLModel *(*orig_MLModel_initWithContentsOfURL_configuration_error)(MLModel *self, SEL _cmd, NSURL *url, MLModelConfiguration *configuration, NSError * __autoreleasing *error);
static MLModel *hook_MLModel_initWithContentsOfURL_configuration_error(MLModel *self, SEL _cmd, NSURL *url, MLModelConfiguration *configuration, NSError * __autoreleasing *error) {
    if (configuration && configuration.computeUnits == MLComputeUnitsCPUOnly) {
        LOG("MLModel initializing from %@ with CPUOnly -> Overriding computeUnits to MLComputeUnitsAll (Apple Neural Engine)", url ? url.lastPathComponent : @"unknown");
        configuration.computeUnits = MLComputeUnitsAll;
    }
    MLModel *model = orig_MLModel_initWithContentsOfURL_configuration_error(self, _cmd, url, configuration, error);
    if (model && url) {
        objc_setAssociatedObject(model, kModelFileNameKey, url.lastPathComponent, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return model;
}

// Hook -[MLModel predictionFromFeatures:options:error:]
static id<MLFeatureProvider> (*orig_MLModel_predictionFromFeatures_options_error)(MLModel *self, SEL _cmd, id<MLFeatureProvider> input, MLPredictionOptions *options, NSError * __autoreleasing *error);
static id<MLFeatureProvider> hook_MLModel_predictionFromFeatures_options_error(MLModel *self, SEL _cmd, id<MLFeatureProvider> input, MLPredictionOptions *options, NSError * __autoreleasing *error) {
    if (!g_in_prediction_log) {
        g_in_prediction_log = YES;
        log_coreml_inference(self);
        id<MLFeatureProvider> res = orig_MLModel_predictionFromFeatures_options_error(self, _cmd, input, options, error);
        g_in_prediction_log = NO;
        return res;
    }
    return orig_MLModel_predictionFromFeatures_options_error(self, _cmd, input, options, error);
}

// Hook -[MLModel predictionsFromBatch:options:error:]
static id<MLBatchProvider> (*orig_MLModel_predictionsFromBatch_options_error)(MLModel *self, SEL _cmd, id<MLBatchProvider> inputBatch, MLPredictionOptions *options, NSError * __autoreleasing *error);
static id<MLBatchProvider> hook_MLModel_predictionsFromBatch_options_error(MLModel *self, SEL _cmd, id<MLBatchProvider> inputBatch, MLPredictionOptions *options, NSError * __autoreleasing *error) {
    if (!g_in_prediction_log) {
        g_in_prediction_log = YES;
        log_coreml_inference(self);
        id<MLBatchProvider> res = orig_MLModel_predictionsFromBatch_options_error(self, _cmd, inputBatch, options, error);
        g_in_prediction_log = NO;
        return res;
    }
    return orig_MLModel_predictionsFromBatch_options_error(self, _cmd, inputBatch, options, error);
}

// -----------------------------------------------------------------------------
// Picture Click Detection & Capture Processing Hooks
// -----------------------------------------------------------------------------

static void (*orig_BNSMainController_captureZslShot_shotDelegate)(id self, SEL _cmd, id options, id delegate);
static void hook_BNSMainController_captureZslShot_shotDelegate(id self, SEL _cmd, id options, id delegate) {
    atomic_fetch_add(&g_active_capture_count, 1);
    LOG("📸 >>> SHUTTER CLICKED: -[BNSMainController captureZslShot:shotDelegate:] triggered! Initiating Zero-Shutter-Lag capture pipeline.");
    orig_BNSMainController_captureZslShot_shotDelegate(self, _cmd, options, delegate);

    // Safety timeout: reset active capture indicator if asynchronous pipeline finishes without delegate callback
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        atomic_store(&g_active_capture_count, 0);
    });
}

static void (*orig_AVCapturePhotoOutput_capturePhotoWithSettings_delegate)(AVCapturePhotoOutput *self, SEL _cmd, AVCapturePhotoSettings *settings, id delegate);
static void hook_AVCapturePhotoOutput_capturePhotoWithSettings_delegate(AVCapturePhotoOutput *self, SEL _cmd, AVCapturePhotoSettings *settings, id delegate) {
    atomic_fetch_add(&g_active_capture_count, 1);
    LOG("📸 >>> SHUTTER CLICKED: -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:] triggered! Unique ID: %lld",
        settings ? (long long)settings.uniqueID : 0LL);
    orig_AVCapturePhotoOutput_capturePhotoWithSettings_delegate(self, _cmd, settings, delegate);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        atomic_store(&g_active_capture_count, 0);
    });
}

static void (*orig_BurstCaptureDelegate_captureOutput_willCapture)(id self, SEL _cmd, AVCapturePhotoOutput *output, AVCaptureResolvedPhotoSettings *resolvedSettings);
static void hook_BurstCaptureDelegate_captureOutput_willCapture(id self, SEL _cmd, AVCapturePhotoOutput *output, AVCaptureResolvedPhotoSettings *resolvedSettings) {
    LOG("📸 >>> CAPTURE PIPELINE: Will capture photo for resolved settings (uniqueID: %lld, dimensions: %dx%d)",
        resolvedSettings ? (long long)resolvedSettings.uniqueID : 0LL,
        resolvedSettings ? (int)resolvedSettings.photoDimensions.width : 0,
        resolvedSettings ? (int)resolvedSettings.photoDimensions.height : 0);
    if (orig_BurstCaptureDelegate_captureOutput_willCapture) {
        orig_BurstCaptureDelegate_captureOutput_willCapture(self, _cmd, output, resolvedSettings);
    }
}

static void (*orig_BurstCaptureDelegate_captureOutput_didFinishProcessing)(id self, SEL _cmd, AVCapturePhotoOutput *output, AVCapturePhoto *photo, NSError *error);
static void hook_BurstCaptureDelegate_captureOutput_didFinishProcessing(id self, SEL _cmd, AVCapturePhotoOutput *output, AVCapturePhoto *photo, NSError *error) {
    int count = atomic_fetch_sub(&g_active_capture_count, 1);
    if (count <= 1) atomic_store(&g_active_capture_count, 0);
    LOG("✅ >>> CAPTURE PROCESSED: Photo processing complete! (error: %@)",
        error ? [error localizedDescription] : @"none");
    if (orig_BurstCaptureDelegate_captureOutput_didFinishProcessing) {
        orig_BurstCaptureDelegate_captureOutput_didFinishProcessing(self, _cmd, output, photo, error);
    }
}

// -----------------------------------------------------------------------------
// Swift ModelSpecificSettings VTable Patches (is17Series & Burst Pacing)
// -----------------------------------------------------------------------------

// Hook is17Series (Slot 26) -> Force false for iPhone 16 Pro to eliminate inverted bitmask
static bool hook_is17Series(void *self) {
    (void)self;
    LOG("ModelSpecificSettings.is17Series intercepted -> returning false");
    return false;
}

// Hook shutterButtonRateLimitDuration (Slot 27) -> Pace rapid bursts at 0.4s to prevent thermal queue explosion
static double hook_shutterButtonRateLimitDuration(void *self) {
    (void)self;
    LOG("ModelSpecificSettings.shutterButtonRateLimitDuration intercepted -> returning 0.4s");
    return 0.4;
}

static void patch_swift_model_settings(void) {
    // Symbol: _$s61helios_experimental_bonsai_camera_app_model_specific_settings21ModelSpecificSettingsCN
    const char *sym_name = "$s61helios_experimental_bonsai_camera_app_model_specific_settings21ModelSpecificSettingsCN";
    void *sym = dlsym(RTLD_DEFAULT, sym_name);
    if (!sym) {
        sym = dlsym(RTLD_DEFAULT, "_$s61helios_experimental_bonsai_camera_app_model_specific_settings21ModelSpecificSettingsCN");
    }
    if (!sym) {
        LOG("ModelSpecificSettings metadata symbol not resolved via dlsym.");
        return;
    }

    uintptr_t *vtable = (uintptr_t *)sym;
    LOG("Found ModelSpecificSettings metadata at 0x%lx", (unsigned long)(uintptr_t)vtable);

    // Slot 26 (+208 bytes): is17Series
    // Slot 27 (+216 bytes): shutterButtonRateLimitDuration
    long page_size_val = sysconf(_SC_PAGESIZE);
    size_t pageSize = (page_size_val > 0) ? (size_t)page_size_val : 16384;
    uintptr_t addr = (uintptr_t)&vtable[26];
    uintptr_t pageStart = addr & ~(pageSize - 1);
    mprotect((char *)pageStart, pageSize * 2, PROT_READ | PROT_WRITE);

    vtable[26] = (uintptr_t)hook_is17Series;
    LOG("Patched ModelSpecificSettings.is17Series (slot 26) -> 0x%lx", (unsigned long)(uintptr_t)hook_is17Series);

    vtable[27] = (uintptr_t)hook_shutterButtonRateLimitDuration;
    LOG("Patched ModelSpecificSettings.shutterButtonRateLimitDuration (slot 27) -> 0x%lx", (unsigned long)(uintptr_t)hook_shutterButtonRateLimitDuration);
}

// -----------------------------------------------------------------------------
// Method Swizzling Helper
// -----------------------------------------------------------------------------

static void safe_swizzle(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel || !newImp || !origImp) return;
    Method origMethod = class_getInstanceMethod(cls, sel);
    if (!origMethod) return;

    const char *types = method_getTypeEncoding(origMethod);
    if (!types) types = "v@:";

    if (class_addMethod(cls, sel, newImp, types)) {
        *origImp = method_getImplementation(origMethod);
    } else {
        *origImp = method_setImplementation(origMethod, newImp);
    }
}

// -----------------------------------------------------------------------------
// MTKView Method Hooks
// -----------------------------------------------------------------------------

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

// Hook -[MTKView initWithFrame:device:] (Returns MTKView * rather than C-invalid instancetype)
static MTKView *(*orig_MTKView_initWithFrame_device)(MTKView *self, SEL _cmd, CGRect frame, id<MTLDevice> device);
static MTKView *hook_MTKView_initWithFrame_device(MTKView *self, SEL _cmd, CGRect frame, id<MTLDevice> device) {
    MTKView *view = orig_MTKView_initWithFrame_device(self, _cmd, frame, device);
    if (view) {
        apply_viewfinder_fps_cap(view);
    }
    return view;
}

// Hook -[MTKView init] (Returns MTKView * rather than C-invalid instancetype)
static MTKView *(*orig_MTKView_init)(MTKView *self, SEL _cmd);
static MTKView *hook_MTKView_init(MTKView *self, SEL _cmd) {
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

// -----------------------------------------------------------------------------
// AVCaptureSession & AVCaptureVideoDataOutput Method Hooks
// -----------------------------------------------------------------------------

// Hook -[AVCaptureSession startRunning]
static void (*orig_AVCaptureSession_startRunning)(AVCaptureSession *self, SEL _cmd);
static void hook_AVCaptureSession_startRunning(AVCaptureSession *self, SEL _cmd) {
    apply_session_fps_cap(self);
    orig_AVCaptureSession_startRunning(self, _cmd);
    apply_session_fps_cap(self);
}

// Hook -[AVCaptureSession addInput:]
static void (*orig_AVCaptureSession_addInput)(AVCaptureSession *self, SEL _cmd, AVCaptureInput *input);
static void hook_AVCaptureSession_addInput(AVCaptureSession *self, SEL _cmd, AVCaptureInput *input) {
    orig_AVCaptureSession_addInput(self, _cmd, input);
    if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
        apply_device_fps_cap(((AVCaptureDeviceInput *)input).device, get_target_fps());
    }
}

// Hook -[AVCaptureSession addOutput:]
static void (*orig_AVCaptureSession_addOutput)(AVCaptureSession *self, SEL _cmd, AVCaptureOutput *output);
static void hook_AVCaptureSession_addOutput(AVCaptureSession *self, SEL _cmd, AVCaptureOutput *output) {
    orig_AVCaptureSession_addOutput(self, _cmd, output);
    if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        apply_video_output_settings((AVCaptureVideoDataOutput *)output);
    }
}

// Hook -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]
static void (*orig_AVCaptureVideoDataOutput_setSampleBufferDelegate_queue)(AVCaptureVideoDataOutput *self, SEL _cmd, id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate, dispatch_queue_t queue);
static void hook_AVCaptureVideoDataOutput_setSampleBufferDelegate_queue(AVCaptureVideoDataOutput *self, SEL _cmd, id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate, dispatch_queue_t queue) {
    orig_AVCaptureVideoDataOutput_setSampleBufferDelegate_queue(self, _cmd, delegate, queue);
    apply_video_output_settings(self);
}

// -----------------------------------------------------------------------------
// UIWindow & UIViewController Hooks for Performance Badge HUD
// -----------------------------------------------------------------------------

static void (*orig_UIWindow_makeKeyAndVisible)(UIWindow *self, SEL _cmd);
static void hook_UIWindow_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    orig_UIWindow_makeKeyAndVisible(self, _cmd);
    attach_badge_to_window(self);
}

static void (*orig_UIViewController_viewDidAppear)(UIViewController *self, SEL _cmd, BOOL animated);
static void hook_UIViewController_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_UIViewController_viewDidAppear(self, _cmd, animated);
    if (self.view && self.view.window) {
        attach_badge_to_window(self.view.window);
    }
}

// -----------------------------------------------------------------------------
// Metal Command Buffer Hook for GPU Usage Tracking
// -----------------------------------------------------------------------------

static void (*orig_MTLCommandBuffer_commit)(id self, SEL _cmd);
static void hook_MTLCommandBuffer_commit(id self, SEL _cmd) {
    if ([self respondsToSelector:@selector(addCompletedHandler:)]) {
        id<MTLCommandBuffer> cb = (id<MTLCommandBuffer>)self;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            CFTimeInterval start = buffer.GPUStartTime;
            CFTimeInterval end = buffer.GPUEndTime;
            if (end > start && start > 0.0) {
                record_gpu_duration(end - start);
            } else {
                CFTimeInterval kStart = buffer.kernelStartTime;
                CFTimeInterval kEnd = buffer.kernelEndTime;
                if (kEnd > kStart && kStart > 0.0) {
                    record_gpu_duration(kEnd - kStart);
                }
            }
        }];
    }
    orig_MTLCommandBuffer_commit(self, _cmd);
}

static Class get_command_buffer_class(void) {
    Class cls = objc_getClass("_MTLCommandBuffer");
    if (cls) return cls;

    // Dynamic resolution fallback via system Metal device
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev) {
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        if (queue) {
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            if (cb) {
                Class current = [cb class];
                while (current && current != [NSObject class]) {
                    if (class_getInstanceMethod(current, @selector(commit))) {
                        cls = current;
                    }
                    current = class_getSuperclass(current);
                }
            }
        }
    }
    return cls;
}

// -----------------------------------------------------------------------------
// Constructor Entry Point
// -----------------------------------------------------------------------------

__attribute__((constructor)) static void init_indigo_thermal_fix(void) {
    @autoreleasepool {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
        LOG("Initialized in process %d (%@)", pid, bundleId ? bundleId : @"unknown");

        // 1. Resolve & Hook MTKView
        Class mtkViewClass = objc_getClass("MTKView");
        if (!mtkViewClass) {
            [[NSBundle bundleWithPath:@"/System/Library/Frameworks/MetalKit.framework"] load];
            mtkViewClass = objc_getClass("MTKView");
        }

        // 2. Resolve & Hook AVCaptureSession and AVCaptureVideoDataOutput
        Class avSessionClass = objc_getClass("AVCaptureSession");
        if (!avSessionClass) {
            [[NSBundle bundleWithPath:@"/System/Library/Frameworks/AVFoundation.framework"] load];
            avSessionClass = objc_getClass("AVCaptureSession");
        }
        Class avVideoOutputClass = objc_getClass("AVCaptureVideoDataOutput");

        // 3. Resolve & Hook CoreML classes
        Class mlConfigClass = objc_getClass("MLModelConfiguration");
        Class mlModelClass = objc_getClass("MLModel");
        if (!mlConfigClass || !mlModelClass) {
            [[NSBundle bundleWithPath:@"/System/Library/Frameworks/CoreML.framework"] load];
            mlConfigClass = objc_getClass("MLModelConfiguration");
            mlModelClass = objc_getClass("MLModel");
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type"
        if (mtkViewClass) {
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
        } else {
            LOG("WARNING: MTKView class could not be resolved.");
        }

        if (avSessionClass) {
            safe_swizzle(avSessionClass, @selector(startRunning),
                         (IMP)hook_AVCaptureSession_startRunning,
                         (IMP *)&orig_AVCaptureSession_startRunning);

            safe_swizzle(avSessionClass, @selector(addInput:),
                         (IMP)hook_AVCaptureSession_addInput,
                         (IMP *)&orig_AVCaptureSession_addInput);

            safe_swizzle(avSessionClass, @selector(addOutput:),
                         (IMP)hook_AVCaptureSession_addOutput,
                         (IMP *)&orig_AVCaptureSession_addOutput);
        } else {
            LOG("WARNING: AVCaptureSession class could not be resolved.");
        }

        if (avVideoOutputClass) {
            safe_swizzle(avVideoOutputClass, @selector(setSampleBufferDelegate:queue:),
                         (IMP)hook_AVCaptureVideoDataOutput_setSampleBufferDelegate_queue,
                         (IMP *)&orig_AVCaptureVideoDataOutput_setSampleBufferDelegate_queue);
        } else {
            LOG("WARNING: AVCaptureVideoDataOutput class could not be resolved.");
        }

        // 4. Hook CoreML Model Loading, Configuration & Prediction
        if (mlConfigClass) {
            safe_swizzle(mlConfigClass, @selector(setComputeUnits:),
                         (IMP)hook_MLModelConfiguration_setComputeUnits,
                         (IMP *)&orig_MLModelConfiguration_setComputeUnits);
        } else {
            LOG("WARNING: MLModelConfiguration class could not be resolved.");
        }

        if (mlModelClass) {
            Class mlModelMetaClass = object_getClass((id)mlModelClass);
            if (mlModelMetaClass) {
                safe_swizzle(mlModelMetaClass, @selector(modelWithContentsOfURL:configuration:error:),
                             (IMP)hook_MLModel_modelWithContentsOfURL_configuration_error,
                             (IMP *)&orig_MLModel_modelWithContentsOfURL_configuration_error);
            }
            safe_swizzle(mlModelClass, @selector(initWithContentsOfURL:configuration:error:),
                         (IMP)hook_MLModel_initWithContentsOfURL_configuration_error,
                         (IMP *)&orig_MLModel_initWithContentsOfURL_configuration_error);

            safe_swizzle(mlModelClass, @selector(predictionFromFeatures:options:error:),
                         (IMP)hook_MLModel_predictionFromFeatures_options_error,
                         (IMP *)&orig_MLModel_predictionFromFeatures_options_error);

            safe_swizzle(mlModelClass, @selector(predictionsFromBatch:options:error:),
                         (IMP)hook_MLModel_predictionsFromBatch_options_error,
                         (IMP *)&orig_MLModel_predictionsFromBatch_options_error);
        } else {
            LOG("WARNING: MLModel class could not be resolved.");
        }

        // 5. Hook Metal Command Buffer for GPU Usage Tracking
        Class cbClass = get_command_buffer_class();
        if (cbClass) {
            safe_swizzle(cbClass, @selector(commit),
                         (IMP)hook_MTLCommandBuffer_commit,
                         (IMP *)&orig_MTLCommandBuffer_commit);
        } else {
            LOG("WARNING: Metal command buffer class could not be resolved.");
        }

        // 6. Hook UIWindow & UIViewController for Performance HUD Overlay
        Class uiWindowClass = objc_getClass("UIWindow");
        if (uiWindowClass) {
            safe_swizzle(uiWindowClass, @selector(makeKeyAndVisible),
                         (IMP)hook_UIWindow_makeKeyAndVisible,
                         (IMP *)&orig_UIWindow_makeKeyAndVisible);
        }

        Class uiViewControllerClass = objc_getClass("UIViewController");
        if (uiViewControllerClass) {
            safe_swizzle(uiViewControllerClass, @selector(viewDidAppear:),
                         (IMP)hook_UIViewController_viewDidAppear,
                         (IMP *)&orig_UIViewController_viewDidAppear);
        }

        // 7. Hook Shutter Button & Capture Delegates
        Class bnsMainControllerClass = objc_getClass("BNSMainController");
        if (bnsMainControllerClass) {
            safe_swizzle(bnsMainControllerClass, sel_registerName("captureZslShot:shotDelegate:"),
                         (IMP)hook_BNSMainController_captureZslShot_shotDelegate,
                         (IMP *)&orig_BNSMainController_captureZslShot_shotDelegate);
        }

        Class avPhotoOutputClass = objc_getClass("AVCapturePhotoOutput");
        if (avPhotoOutputClass) {
            safe_swizzle(avPhotoOutputClass, @selector(capturePhotoWithSettings:delegate:),
                         (IMP)hook_AVCapturePhotoOutput_capturePhotoWithSettings_delegate,
                         (IMP *)&orig_AVCapturePhotoOutput_capturePhotoWithSettings_delegate);
        }

        Class burstCaptureDelegateClass = objc_getClass("BurstCaptureDelegate");
        if (burstCaptureDelegateClass) {
            safe_swizzle(burstCaptureDelegateClass, sel_registerName("captureOutput:willCapturePhotoForResolvedSettings:"),
                         (IMP)hook_BurstCaptureDelegate_captureOutput_willCapture,
                         (IMP *)&orig_BurstCaptureDelegate_captureOutput_willCapture);

            safe_swizzle(burstCaptureDelegateClass, sel_registerName("captureOutput:didFinishProcessingPhoto:error:"),
                         (IMP)hook_BurstCaptureDelegate_captureOutput_didFinishProcessing,
                         (IMP *)&orig_BurstCaptureDelegate_captureOutput_didFinishProcessing);
        }

        Class repeatingCaptureDelegateClass = objc_getClass("RepeatingCaptureDelegate");
        if (repeatingCaptureDelegateClass) {
            safe_swizzle(repeatingCaptureDelegateClass, sel_registerName("captureOutput:willCapturePhotoForResolvedSettings:"),
                         (IMP)hook_BurstCaptureDelegate_captureOutput_willCapture,
                         (IMP *)&orig_BurstCaptureDelegate_captureOutput_willCapture);

            safe_swizzle(repeatingCaptureDelegateClass, sel_registerName("captureOutput:didFinishProcessingPhoto:error:"),
                         (IMP)hook_BurstCaptureDelegate_captureOutput_didFinishProcessing,
                         (IMP *)&orig_BurstCaptureDelegate_captureOutput_didFinishProcessing);
        }
#pragma clang diagnostic pop

        // 8. Patch Swift ModelSpecificSettings vtable (is17Series & Burst Pacing)
        patch_swift_model_settings();

        // 9. Attach HUD to current key window if already presented
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *keyWindow = nil;
            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        UIWindowScene *windowScene = (UIWindowScene *)scene;
                        for (UIWindow *w in windowScene.windows) {
                            if (w.isKeyWindow) {
                                keyWindow = w;
                                break;
                            }
                        }
                    }
                    if (keyWindow) break;
                }
            }
            if (!keyWindow) {
                keyWindow = [UIApplication sharedApplication].keyWindow;
            }
            if (keyWindow) {
                attach_badge_to_window(keyWindow);
            }
        });

        LOG("Successfully hooked camera pipeline, CoreML ANE acceleration, performance HUD, and viewfinder. Target FPS: %ld.",
            (long)get_target_fps());
    }
}

#pragma clang diagnostic pop
