// Tweak.xm — VCAMLight
//
// Replaces the camera feed with a video, for every app that opens the camera.
//
// The replacement happens client-side, inside each app's own AVFoundation
// session, not in mediaserverd. The earlier mediaserverd approach hooked
// -[AVCaptureOutput _AVOutputContext_notifyObserversOfNewSampleBuffer:forConnection:],
// a method that does not exist anywhere in the iOS 15.7 dyld shared cache, so
// it could never fire. What actually has to be covered, per app:
//
//   AVCaptureVideoPreviewLayer  the live preview the user sees
//   AVCaptureSession            start/stop, so we know a camera is live
//   AVCaptureVideoDataOutput    frames handed to the app (QR scan, analysis…)
//   AVCaptureStillImageOutput   legacy still capture
//   AVCapturePhotoOutput        modern photo capture
//
// The tweak is injected into every UIKit process; the volume-button hook at the
// bottom only takes effect in SpringBoard, where SBVolumeControl exists.

#import "VCAMOverlay.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <notify.h>
#import <objc/runtime.h>
#import <substrate.h>

// Theos compiles with -Werror, and hooking the legacy still-capture path means
// naming AVCaptureStillImageOutput, which Apple deprecated in iOS 10 but still
// ships and which apps on iOS 15 still use. That warning is expected here.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#pragma mark - Forward declarations

static BOOL vcam_active(void);
static NSData *vcam_jpeg_from_current_frame(void);

#pragma mark - Shared state

static NSFileManager *g_fm = nil;
static BOOL g_bufferReload = YES;       // restart the reader on the next frame
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static CALayer *g_maskLayer = nil;
static NSTimeInterval g_lastVideoDataOutputTime = 0;
static BOOL g_cameraRunning = NO;
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait;

// Mirrors of prefs.plist, re-read at most once a second so that toggling the
// switch in the overlay takes effect in already-running apps without a respring.
static BOOL g_replOn = NO;
static BOOL g_loopOn = YES;
static NSTimeInterval g_lastPrefsCheck = 0;

static void vcam_reload_prefs(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - g_lastPrefsCheck < 1.0) return;
    g_lastPrefsCheck = now;

    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:VCAM_PREFS_PATH];
    g_replOn = [p[@"replOn"] boolValue];
    g_loopOn = p[@"loopOn"] ? [p[@"loopOn"] boolValue] : YES;

    // Re-read the video when the overlay swaps the file underneath us, so a new
    // selection takes effect without the app being relaunched.
    static NSDate *seenMarker = nil;
    if (!g_fm) g_fm = [NSFileManager defaultManager];
    NSDate *marker = [g_fm attributesOfItemAtPath:VCAM_CHANGED_MARK error:nil][NSFileModificationDate];
    if (marker != nil && ![marker isEqualToDate:seenMarker]) {
        seenMarker = marker;
        g_bufferReload = YES;
    }
}

// True when a replacement video is selected and the user has not disabled it.
static BOOL vcam_active(void) {
    vcam_reload_prefs();
    if (!g_replOn) return NO;
    if (!g_fm) g_fm = [NSFileManager defaultManager];
    return [g_fm fileExistsAtPath:VCAM_VIDEO_PATH];
}

#pragma mark - Frame engine

@interface VCAMFrameSource : NSObject
// originSampleBuffer carries the format/timing we must match; pass nil when the
// caller has no source buffer (preview tick, photo conversion).
+ (CMSampleBufferRef)nextFrameForBuffer:(CMSampleBufferRef)originSampleBuffer
                             forceRenew:(BOOL)forceRenew;
+ (UIWindow *)keyWindow;
@end

@implementation VCAMFrameSource

+ (CMSampleBufferRef)nextFrameForBuffer:(CMSampleBufferRef)originSampleBuffer
                             forceRenew:(BOOL)forceRenew {
    static AVAssetReader *reader = nil;
    static AVAssetReaderTrackOutput *out32BGRA = nil;
    static AVAssetReaderTrackOutput *out420v = nil;
    static AVAssetReaderTrackOutput *out420f = nil;
    // Holds the frame we last handed out so it stays alive while the caller uses
    // it; replaced (and the old one released) on the following call.
    static CMSampleBufferRef cached = NULL;

    // What format is the real camera handing us? We must decode the video in
    // that same format, otherwise the client sees a mismatched image buffer and
    // will stretch, mis-colour or crash.
    OSType subType = kCVPixelFormatType_32BGRA;
    if (originSampleBuffer != NULL) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(originSampleBuffer);
        if (fmt == NULL) return NULL;
        if (CMFormatDescriptionGetMediaType(fmt) != kCMMediaType_Video) {
            return originSampleBuffer; // audio etc. — pass through untouched
        }
        subType = CMFormatDescriptionGetMediaSubType(fmt);
    }

    if (!vcam_active()) return NULL;

    if (g_bufferReload) {
        g_bufferReload = NO;
        @try {
            reader = nil; out32BGRA = nil; out420v = nil; out420f = nil;

            AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:VCAM_VIDEO_PATH]];
            AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (track == nil) return NULL;

            reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
            if (reader == nil) return NULL;

            out32BGRA = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) }];
            out420v = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) }];
            out420f = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) }];

            [reader addOutput:out32BGRA];
            [reader addOutput:out420v];
            [reader addOutput:out420f];
            [reader startReading];
        } @catch (NSException *e) {
            return NULL;
        }
    }

    CMSampleBufferRef b32 = [out32BGRA copyNextSampleBuffer];
    CMSampleBufferRef b420v = [out420v copyNextSampleBuffer];
    CMSampleBufferRef b420f = [out420f copyNextSampleBuffer];

    CMSampleBufferRef decoded = NULL;
    switch (subType) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            if (b420v) CMSampleBufferCreateCopy(kCFAllocatorDefault, b420v, &decoded);
            break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            if (b420f) CMSampleBufferCreateCopy(kCFAllocatorDefault, b420f, &decoded);
            break;
        default:
            if (b32) CMSampleBufferCreateCopy(kCFAllocatorDefault, b32, &decoded);
            break;
    }
    if (b32) CFRelease(b32);
    if (b420v) CFRelease(b420v);
    if (b420f) CFRelease(b420f);

    if (decoded == NULL) {
        // End of video. Loop if asked, otherwise fall back to the real camera.
        if (g_loopOn) g_bufferReload = YES;
        else g_replOn = NO;
        return NULL;
    }

    CMSampleBufferRef result = decoded;

    if (originSampleBuffer != NULL) {
        // Re-wrap the decoded pixels with the *source* buffer's timing so the
        // client's own timestamp bookkeeping keeps working.
        CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(decoded);
        if (pixels == NULL) { CFRelease(decoded); return NULL; }

        CMSampleTimingInfo timing = {
            .duration = CMSampleBufferGetDuration(originSampleBuffer),
            .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
            .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer),
        };
        CMVideoFormatDescriptionRef vfmt = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &vfmt);
        if (vfmt == NULL) { CFRelease(decoded); return NULL; }

        CMSampleBufferRef wrapped = NULL;
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixels, true, NULL, NULL,
                                           vfmt, &timing, &wrapped);
        CFRelease(vfmt);
        CFRelease(decoded);
        if (wrapped == NULL) return NULL;

        // Carry the EXIF/TIFF attachments across; some clients read them.
        // CMGetAttachment hands back a CFTypeRef; the attachment keys above are
        // always dictionaries in practice.
        CFDictionaryRef exif = (CFDictionaryRef)CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
        CFDictionaryRef tiff = (CFDictionaryRef)CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);
        if (exif) CMSetAttachment(wrapped, (CFStringRef)@"{Exif}", exif, kCMAttachmentMode_ShouldPropagate);
        if (tiff) CMSetAttachment(wrapped, (CFStringRef)@"{TIFF}", tiff, kCMAttachmentMode_ShouldPropagate);
        result = wrapped;
    }

    if (cached != NULL) CFRelease(cached);
    cached = result;
    return cached;
}

+ (UIWindow *)keyWindow {
    // Not -[UIApplication windows]: deprecated since iOS 15, and theos builds
    // with -Werror.
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

@end

// Renders the current replacement frame to JPEG, honouring orientation.
static NSData *vcam_jpeg_from_current_frame(void) {
    CMSampleBufferRef frame = [VCAMFrameSource nextFrameForBuffer:NULL forceRenew:NO];
    if (frame == NULL) return nil;
    CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(frame);
    if (pixels == NULL) return nil;

    // UIImageOrientation rather than CGImagePropertyOrientation so this stays a
    // UIKit-only conversion and needs no ImageIO import.
    UIImageOrientation orient = UIImageOrientationUp;
    switch (g_photoOrientation) {
        case AVCaptureVideoOrientationPortraitUpsideDown: orient = UIImageOrientationDown;  break;
        case AVCaptureVideoOrientationLandscapeRight:     orient = UIImageOrientationRight; break;
        case AVCaptureVideoOrientationLandscapeLeft:      orient = UIImageOrientationLeft;  break;
        default:                                          orient = UIImageOrientationUp;    break;
    }

    CIImage *ci = [CIImage imageWithCVImageBuffer:pixels];
    UIImage *img = [UIImage imageWithCIImage:ci scale:1.0 orientation:orient];
    return UIImageJPEGRepresentation(img, 1.0);
}

#pragma mark - Preview replacement

static char kVCAMLinkKey;   // association key for the per-layer CADisplayLink

// A display layer that is mid-failure refuses new buffers until it is flushed;
// flushing unconditionally on every frame would drop the frame being displayed
// and show a black flash instead.
static void vcam_enqueue_frame(AVSampleBufferDisplayLayer *layer, CMSampleBufferRef buf) {
    if (layer == nil || buf == NULL) return;
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [layer flush];
    }
    if (!layer.readyForMoreMediaData) return;
    [layer enqueueSampleBuffer:buf];
}

// AVCaptureVideoPreviewLayer renders the camera straight into its own layer, so
// no data output is involved. We drop an AVSampleBufferDisplayLayer on top and
// feed it decoded frames from a CADisplayLink.
%hook AVCaptureVideoPreviewLayer

- (void)addSublayer:(CALayer *)layer {
    %orig;

    // insertSublayer:above: calls back into addSublayer:, so without this guard
    // our own insertions below would re-enter here and recurse forever.
    static BOOL installing = NO;
    if (installing || layer == nil) return;

    // A CADisplayLink retains its target, so a single shared link would pin the
    // first preview layer it ever saw. One link per layer, held by association.
    if (objc_getAssociatedObject(self, &kVCAMLinkKey) == nil) {
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self
                                                          selector:@selector(vcam_step:)];
        [link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(self, &kVCAMLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    BOOL created = (g_previewLayer == nil);
    if (created) {
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];
        g_maskLayer = [CALayer layer];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        // Invisible until the first tick decides whether we are active.
        g_previewLayer.opacity = 0;
        g_maskLayer.opacity = 0;
    }

    // insertSublayer: re-parents a layer that already has a superlayer, so this
    // both brings ours back to the front and keeps them off any preview layer
    // that came before — there is only ever one showing replacements.
    installing = YES;
    [self insertSublayer:g_maskLayer above:layer];
    [self insertSublayer:g_previewLayer above:g_maskLayer];
    installing = NO;

    if (!created) return;

    // Geometry is only final once the layer is in a window, so size on the next
    // main-queue turn rather than here.
    CALayer *previewRef = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect b = [VCAMFrameSource keyWindow].bounds;
        if (CGRectIsEmpty(b)) b = previewRef.bounds;
        g_previewLayer.frame = b;
        g_maskLayer.frame = b;
    });
}

%new
- (void)vcam_step:(CADisplayLink *)sender {
    if (g_previewLayer == nil || g_maskLayer == nil) return;
    // Another preview layer owns the shared display layer right now.
    if (g_previewLayer.superlayer != self) return;

    BOOL active = vcam_active();
    g_maskLayer.opacity = active ? 1 : 0;
    g_previewLayer.opacity = active ? 1 : 0;
    if (!active || !g_cameraRunning) return;

    g_previewLayer.frame = self.bounds;
    switch (g_photoOrientation) {
        case AVCaptureVideoOrientationLandscapeRight:
            g_previewLayer.transform = CATransform3DMakeRotation(M_PI / 2, 0, 0, 1); break;
        case AVCaptureVideoOrientationLandscapeLeft:
            g_previewLayer.transform = CATransform3DMakeRotation(-M_PI / 2, 0, 0, 1); break;
        case AVCaptureVideoOrientationPortraitUpsideDown:
            g_previewLayer.transform = CATransform3DMakeRotation(M_PI, 0, 0, 1); break;
        default:
            g_previewLayer.transform = CATransform3DIdentity;
    }

    // An app with a VideoDataOutput already feeds the layer; don't fight it.
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970] * 1000.0;
    if (now - g_lastVideoDataOutputTime < 1000) return;

    CMSampleBufferRef frame = [VCAMFrameSource nextFrameForBuffer:NULL forceRenew:NO];
    if (frame == NULL) return;
    vcam_enqueue_frame(g_previewLayer, frame);
}

%end

#pragma mark - Capture session / outputs

%hook AVCaptureSession

- (void)startRunning {
    g_cameraRunning = YES;
    g_bufferReload = YES;
    g_lastVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000.0;
    %orig;
}

- (void)stopRunning {
    g_cameraRunning = NO;
    %orig;
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) {
        %orig;
        return;
    }

    // The app's delegate class is only known at runtime, so the callback is
    // hooked lazily on first sight, once per class.
    static NSMutableArray *hookedClasses = nil;
    if (hookedClasses == nil) hookedClasses = [NSMutableArray new];
    NSString *cls = NSStringFromClass([sampleBufferDelegate class]);

    if (![hookedClasses containsObject:cls]) {
        [hookedClasses addObject:cls];
        __block void (*original)(id, SEL, AVCaptureOutput *,
                                 CMSampleBufferRef, AVCaptureConnection *) = NULL;
        MSHookMessageEx(
            [sampleBufferDelegate class],
            @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            imp_implementationWithBlock(^(id dself, AVCaptureOutput *output,
                                          CMSampleBufferRef sampleBuffer,
                                          AVCaptureConnection *connection) {
                g_lastVideoDataOutputTime = [[NSDate date] timeIntervalSince1970] * 1000.0;
                g_photoOrientation = [connection videoOrientation];

                CMSampleBufferRef replacement =
                    [VCAMFrameSource nextFrameForBuffer:sampleBuffer forceRenew:NO];

                if (replacement != NULL && g_previewLayer != nil) {
                    vcam_enqueue_frame(g_previewLayer, replacement);
                }
                if (original) {
                    original(dself, @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                             output, replacement ?: sampleBuffer, connection);
                }
            }),
            (IMP *)&original);
    }
    %orig;
}

%end

#pragma mark - Stills

%hook AVCaptureStillImageOutput

- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection
                                    completionHandler:(void (^)(CMSampleBufferRef, NSError *))handler {
    // The frame engine recycles its buffer on the next call, and the preview
    // keeps ticking, so hold a reference of our own for as long as the client
    // may still be working with this one.
    static CMSampleBufferRef held = NULL;

    void (^wrapped)(CMSampleBufferRef, NSError *) = ^(CMSampleBufferRef buf, NSError *err) {
        CMSampleBufferRef replacement = [VCAMFrameSource nextFrameForBuffer:buf forceRenew:YES];
        if (held != NULL) { CFRelease(held); held = NULL; }
        if (replacement != NULL && replacement != buf) {
            held = replacement;
            CFRetain(held);
        }
        handler(replacement ?: buf, err);
    };
    %orig(connection, [wrapped copy]);
}

+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer {
    NSData *replaced = vcam_jpeg_from_current_frame();
    return replaced ?: %orig;
}

%end

// AVCapturePhoto is opaque, so rather than swapping its buffer we intercept the
// representations the client pulls off it. The current replacement frame is kept
// in a static and the swizzles are installed once per class.
static NSData *g_photoJPEG = nil;
static NSMutableArray *g_photoHookedClasses = nil;

static void vcam_install_photo_overrides(id photo) {
    g_photoJPEG = vcam_jpeg_from_current_frame();
    if (g_photoJPEG == nil || photo == nil) return;

    if (g_photoHookedClasses == nil) g_photoHookedClasses = [NSMutableArray new];
    NSString *cls = NSStringFromClass([photo class]);
    if ([g_photoHookedClasses containsObject:cls]) return;
    [g_photoHookedClasses addObject:cls];

    __block NSData *(*origRep)(id, SEL) = NULL;
    MSHookMessageEx([photo class], @selector(fileDataRepresentation),
        imp_implementationWithBlock(^(id pself, SEL _cmd) {
            if (g_photoJPEG != nil) return g_photoJPEG;
            return origRep ? origRep(pself, _cmd) : nil;
        }), (IMP *)&origRep);
}

%hook AVCapturePhotoOutput

+ (NSData *)JPEGPhotoDataRepresentationForJPEGSampleBuffer:(CMSampleBufferRef)JPEGSampleBuffer
                                    previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer {
    NSData *replaced = vcam_jpeg_from_current_frame();
    return replaced ?: %orig;
}

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (settings != nil && delegate != nil) {
        static NSMutableArray *hookedClasses = nil;
        if (hookedClasses == nil) hookedClasses = [NSMutableArray new];
        NSString *cls = NSStringFromClass([delegate class]);

        if (![hookedClasses containsObject:cls]) {
            [hookedClasses addObject:cls];
            __block void (*origFinish)(id, SEL, AVCapturePhotoOutput *,
                                       AVCapturePhoto *, NSError *) = NULL;
            MSHookMessageEx(
                [delegate class], @selector(captureOutput:didFinishProcessingPhoto:error:),
                imp_implementationWithBlock(^(id dself, AVCapturePhotoOutput *output,
                                              AVCapturePhoto *photo, NSError *err) {
                    vcam_install_photo_overrides(photo);
                    if (origFinish) {
                        origFinish(dself, @selector(captureOutput:didFinishProcessingPhoto:error:),
                                   output, photo, err);
                    }
                }),
                (IMP *)&origFinish);
        }
    }
    %orig;
}

%end

#pragma mark - SpringBoard: volume buttons drive the overlay

static NSTimeInterval g_lastUp = 0;
static NSTimeInterval g_lastDown = 0;
static NSTimeInterval g_lastToggle = 0;

static void vcam_volume_pressed(BOOL isUp) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (isUp) g_lastUp = now; else g_lastDown = now;

    // Both buttons within 200ms, and not more often than once a second.
    if (g_lastUp == 0 || g_lastDown == 0) return;
    if (fabs(g_lastUp - g_lastDown) > 0.2) return;
    if (now - g_lastToggle < 1.0) return;
    g_lastToggle = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        [VCAMOverlay toggle];
    });
}

%group SpringBoard

%hook SBVolumeControl

- (void)increaseVolume {
    %orig;
    vcam_volume_pressed(YES);
}

- (void)decreaseVolume {
    %orig;
    vcam_volume_pressed(NO);
}

%end

%end // SpringBoard

#pragma mark - Init

%ctor {
    g_fm = [NSFileManager defaultManager];
    [g_fm createDirectoryAtPath:VCAM_DIR
    withIntermediateDirectories:YES attributes:nil error:nil];

    // Breadcrumb so we can see over SSH which processes actually got injected.
    NSString *proc = [[NSProcessInfo processInfo] processName];
    [[NSString stringWithFormat:@"%@ %@", proc, [NSDate date]]
        writeToFile:[NSString stringWithFormat:@"%@/loaded_%@", VCAM_DIR, proc]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Declaring a %group puts everything outside one into the implicit
    // _ungrouped group, which then has to be initialised by hand — without this
    // Logos refuses to compile the file and nothing hooks at all.
    %init;

    // SBVolumeControl only exists in SpringBoard, so this group stays inert in
    // every other process.
    if (NSClassFromString(@"SBVolumeControl") != nil) {
        %init(SpringBoard);
    }
}
