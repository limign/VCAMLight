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
//   AVCaptureMetadataOutput     barcodes and faces the app recognises
//   AVCaptureStillImageOutput   legacy still capture
//   AVCapturePhotoOutput        modern photo capture, stills and Live Photos
//   AVCaptureMovieFileOutput    video, which the daemon writes for us
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
// Defined with the still helpers, called from the still paths below them.
static NSData *vcam_still_jpeg(CMSampleBufferRef *frameOut);
// Defined with the recording path, called from the photo delegate above it.
static void vcam_replace_live_movie(NSURL *url, void (^done)(BOOL replaced));

#pragma mark - Shared state

static NSFileManager *g_fm = nil;
static BOOL g_bufferReload = YES;       // restart the reader on the next frame
static NSTimeInterval g_reloadNotBefore = 0;  // backoff for failed load attempts
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static CALayer *g_maskLayer = nil;
static NSTimeInterval g_lastVideoDataOutputTime = 0;
static NSTimeInterval g_lastEnqueueOk = 0;   // last time the display layer took a frame
static BOOL g_cameraRunning = NO;
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait;

// Mirrors of prefs.plist, re-read at most once a second so that toggling the
// switch in the overlay takes effect in already-running apps without a respring.
static BOOL g_replOn = NO;
static BOOL g_loopOn = YES;
static NSTimeInterval g_lastPrefsCheck = 0;

// Ask for a reload, holding off the next attempt briefly: a broken or
// unreadable video would otherwise rebuild an AVAsset on every single frame.
static void vcam_reload_later(NSTimeInterval now) {
    g_bufferReload = YES;
    g_reloadNotBefore = now + 0.5;
}

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
// The work nextFrameForBuffer: serialises. Declared here only so it can be
// called before it is defined; callers outside this class want the wrapper.
+ (CMSampleBufferRef)vcam_frame:(CMSampleBufferRef)originSampleBuffer
                     forceRenew:(BOOL)forceRenew;
+ (UIWindow *)keyWindow;
// Path AVAssetReader is allowed to open, or nil when the master is unreadable.
+ (NSString *)playbackPath;
@end

// Reader state, kept between frames. One reader at a time: a reader is single
// use, so looping builds a new one over the asset already parsed rather than
// re-reading the file.
static AVAsset *g_frameAsset = nil;
static AVAssetTrack *g_frameTrack = nil;
static AVAssetReader *g_frameReader = nil;
static AVAssetReaderTrackOutput *g_frameOutput = nil;
static OSType g_frameSubType = 0;            // format the live reader produces
static NSTimeInterval g_frameInterval = 1.0 / 30.0;
static NSTimeInterval g_nextFrameDue = 0;    // media clock time the next preview frame is due

// Slack allowed when asking whether the next frame is due, in seconds — half a
// tick of a 60Hz display link. Display-link callbacks do not land on the exact
// millisecond, and without this the fraction of a millisecond a callback arrives
// early costs a whole extra tick: measured over 15 seconds, the preview ran at
// 23fps with gaps clustered at 33ms and 50ms rather than a steady 33ms.
#define VCAM_PACE_SLACK 0.008
static CMSampleBufferRef g_cachedFrame = NULL;
static NSTimeInterval g_lastPreviewFrame = 0;

@implementation VCAMFrameSource

// The media daemon behind AVAssetReader only opens paths this app's sandbox
// already covers, so the master under Media/.vcamlight cannot be decoded from in
// here (OSStatus -17507) even though its bytes read back fine. Stage a copy in
// /var/tmp, which is covered, and decode that. Cheap to re-run: a sidecar records
// which master revision the copy came from.
+ (NSString *)playbackPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *master = [fm attributesOfItemAtPath:VCAM_VIDEO_PATH error:nil];
    if (master == nil) return nil;

    NSString *stamp = [NSString stringWithFormat:@"%@ %@",
                       master[NSFileSize], master[NSFileModificationDate]];
    NSString *staged = [NSString stringWithContentsOfFile:VCAM_PLAYBACK_STAMP
                                                 encoding:NSUTF8StringEncoding error:nil];
    if ([stamp isEqualToString:staged] && [fm fileExistsAtPath:VCAM_PLAYBACK_PATH]) {
        return VCAM_PLAYBACK_PATH;
    }

    [fm createDirectoryAtPath:VCAM_PLAYBACK_DIR
  withIntermediateDirectories:YES attributes:nil error:nil];

    // Plain file IO, not the media daemon: this is the read that the sandbox does
    // allow on the master.
    NSData *bytes = [NSData dataWithContentsOfFile:VCAM_VIDEO_PATH];
    if (bytes == nil) return nil;

    [fm removeItemAtPath:VCAM_PLAYBACK_PATH error:nil];
    if (![bytes writeToFile:VCAM_PLAYBACK_PATH atomically:YES]) return nil;
    [stamp writeToFile:VCAM_PLAYBACK_STAMP
            atomically:YES encoding:NSUTF8StringEncoding error:nil];

    return VCAM_PLAYBACK_PATH;
}

// Opens a reader over the already-parsed asset, in the format the caller needs.
// A reader cannot be restarted, and the wanted format can change under us (the
// preview takes BGRA, a capture pipeline may hand us 420f), so this is both the
// open and the reopen.
+ (BOOL)openReaderForSubType:(OSType)subType {
    g_frameReader = nil;
    g_frameOutput = nil;
    if (g_frameAsset == nil || g_frameTrack == nil) return NO;

    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:g_frameAsset error:nil];
    if (reader == nil) return NO;

    AVAssetReaderTrackOutput *output =
        [[AVAssetReaderTrackOutput alloc] initWithTrack:g_frameTrack
                                         outputSettings:@{ (id)kCVPixelBufferPixelFormatTypeKey: @(subType) }];
    [reader addOutput:output];
    if (![reader startReading] && reader.status != AVAssetReaderStatusReading) return NO;

    g_frameReader = reader;
    g_frameOutput = output;
    g_frameSubType = subType;
    return YES;
}

// Parses the staged file. Returns NO when the asset or its track list is not
// readable yet, which the caller retries rather than treating as empty.
+ (BOOL)loadAsset {
    g_frameAsset = nil;
    g_frameTrack = nil;

    // Decode from the staged copy, never from the master: see +playbackPath for
    // why AVAssetReader cannot open the master from inside an app.
    NSString *playback = [self playbackPath];
    if (playback == nil) return NO;

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:playback]];
    // AVFoundation loads an asset's tracks asynchronously and this reads them
    // synchronously, so inside a sandboxed app the first calls routinely come
    // back empty for a perfectly good file (measured: the same path yields 1
    // track and then 0 on consecutive calls).
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (track == nil) return NO;

    g_frameAsset = asset;
    g_frameTrack = track;
    float rate = track.nominalFrameRate;
    g_frameInterval = (rate > 1.0f) ? (1.0 / rate) : (1.0 / 30.0);
    return YES;
}

// Re-wraps a decoded frame on the source buffer's timeline so a client doing its
// own timestamp bookkeeping keeps working, and carries the EXIF/TIFF
// attachments across.
//
// Only ever called with a source buffer. A frame handed to the display layer
// with no source keeps the clip's own presentation time — measured the hard way:
// stamping it with the wall clock instead puts a PTS of ~1.79e9 seconds on a
// layer whose clock is the host clock, the layer queues the frame for the year
// 2026, its queue fills, it stops accepting more, and the preview freezes on the
// first frame while every tick still reports itself as showing one.
+ (CMSampleBufferRef)rewrap:(CMSampleBufferRef)decoded
                     origin:(CMSampleBufferRef)originSampleBuffer {
    CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(decoded);
    if (pixels == NULL) return NULL;

    CMSampleTimingInfo timing = {
        .duration = CMSampleBufferGetDuration(originSampleBuffer),
        .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
        .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer),
    };
    CMVideoFormatDescriptionRef vfmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &vfmt);
    if (vfmt == NULL) return NULL;

    CMSampleBufferRef wrapped = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixels, true, NULL, NULL,
                                       vfmt, &timing, &wrapped);
    CFRelease(vfmt);
    if (wrapped == NULL) return NULL;

    // CMGetAttachment hands back a CFTypeRef; the attachment keys above are
    // always dictionaries in practice.
    CFDictionaryRef exif = (CFDictionaryRef)CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
    CFDictionaryRef tiff = (CFDictionaryRef)CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);
    if (exif) CMSetAttachment(wrapped, (CFStringRef)@"{Exif}", exif, kCMAttachmentMode_ShouldPropagate);
    if (tiff) CMSetAttachment(wrapped, (CFStringRef)@"{TIFF}", tiff, kCMAttachmentMode_ShouldPropagate);
    return wrapped;
}

+ (CMSampleBufferRef)nextFrameForBuffer:(CMSampleBufferRef)originSampleBuffer
                             forceRenew:(BOOL)forceRenew {
    // Three threads reach this engine on their own schedules: the preview's
    // display link on the main thread, the video-data-output delegate on the
    // queue the app gave it, and the still paths on whatever queue the capture
    // session used. There is one reader and one cached buffer between them, and
    // the cached buffer is released by the next call — so without this they
    // would hand each other freed memory. Take turns.
    @synchronized (self) {
        return [self vcam_frame:originSampleBuffer forceRenew:forceRenew];
    }
}

+ (CMSampleBufferRef)vcam_frame:(CMSampleBufferRef)originSampleBuffer
                     forceRenew:(BOOL)forceRenew {
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

    // Monotonic: this clock is what the display link is on, and it cannot be
    // walked backwards underneath a half-finished frame the way the wall clock
    // can.
    NSTimeInterval now = CACurrentMediaTime();

    if (g_bufferReload) {
        // A failed load leaves the flag set so a later frame retries. Throttle
        // only those retries — a reload after the video loops has to happen
        // immediately or every repeat of a short clip would stall.
        if (now < g_reloadNotBefore) return NULL;

        g_bufferReload = NO;
        @try {
            if (![self loadAsset]) { vcam_reload_later(now); return NULL; }
            if (![self openReaderForSubType:subType]) { vcam_reload_later(now); return NULL; }
            g_reloadNotBefore = 0;   // loaded cleanly
            g_nextFrameDue = 0;
        } @catch (NSException *e) {
            vcam_reload_later(now);
            return NULL;
        }
    } else if (g_frameReader == nil || g_frameSubType != subType) {
        if (![self openReaderForSubType:subType]) { vcam_reload_later(now); return NULL; }
        g_nextFrameDue = 0;
    }

    // A display link ticks far faster than the clip's own frame rate. Without
    // pacing we would hand over a frame per tick, which runs the video at screen
    // refresh rate and burns through the whole file in half the time. A caller
    // that passes a source buffer is already paced by the camera, and forceRenew
    // (the still path) wants a frame now regardless.
    if (originSampleBuffer == NULL && !forceRenew) {
        if (now + VCAM_PACE_SLACK < g_nextFrameDue) return NULL;
        g_nextFrameDue = (g_nextFrameDue < now ? now : g_nextFrameDue) + g_frameInterval;
    }

    CMSampleBufferRef decoded = [g_frameOutput copyNextSampleBuffer];

    if (decoded == NULL) {
        // End of the clip. Restart it here rather than waiting for the next tick
        // to notice, which would drop the overlay for a moment at every loop.
        if (!g_loopOn) { g_replOn = NO; return NULL; }
        // A reopen that fails leaves a dead reader behind, and nothing else
        // would ever rebuild it — ask for a full reload instead of returning
        // into a state that can only hand back NULL.
        if (![self openReaderForSubType:subType]) { g_bufferReload = YES; return NULL; }
        g_nextFrameDue = 0;
        decoded = [g_frameOutput copyNextSampleBuffer];
        if (decoded == NULL) return NULL;
    }

    CMSampleBufferRef result = decoded;
    if (originSampleBuffer != NULL) {
        // Preview frames are left exactly as the reader produced them. See
        // +rewrap: for why they must not be stamped with the wall clock.
        result = [self rewrap:decoded origin:originSampleBuffer];
        CFRelease(decoded);
        if (result == NULL) return NULL;
    }

    // Holds the frame we last handed out so it stays alive while the caller uses
    // it; replaced (and the old one released) on the following call.
    if (g_cachedFrame != NULL) CFRelease(g_cachedFrame);
    g_cachedFrame = result;
    return g_cachedFrame;
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

// Renders one decoded frame to JPEG at the frame's own size, honouring the
// orientation the capture connection reported.
static NSData *vcam_jpeg_from_frame(CMSampleBufferRef frame,
                                    AVCaptureVideoOrientation videoOrientation) {
    if (frame == NULL) return nil;
    CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(frame);
    if (pixels == NULL) return nil;

    // UIImageOrientation rather than CGImagePropertyOrientation so this stays a
    // UIKit-only conversion and needs no ImageIO import.
    UIImageOrientation orient = UIImageOrientationUp;
    switch (videoOrientation) {
        case AVCaptureVideoOrientationPortraitUpsideDown: orient = UIImageOrientationDown;  break;
        case AVCaptureVideoOrientationLandscapeRight:     orient = UIImageOrientationRight; break;
        case AVCaptureVideoOrientationLandscapeLeft:      orient = UIImageOrientationLeft;  break;
        default:                                          orient = UIImageOrientationUp;    break;
    }

    static CIContext *ctx = nil;
    if (ctx == nil) ctx = [CIContext contextWithOptions:nil];
    CIImage *ci = [CIImage imageWithCVImageBuffer:pixels];
    CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
    if (cg == NULL) return nil;

    // Drawn into a 1:1 context rather than handed to UIImageJPEGRepresentation
    // as a CIImage-backed UIImage: that path renders at the *screen* scale, 3x
    // on this device, so a 720x1280 frame was saved as a 2160x3840 blow-up —
    // measured as a 4.5 MB file for every photo the Camera app stored. Drawing
    // also bakes the rotation into the pixels instead of leaving it to a scale
    // nobody here controls.
    UIImage *raw = [UIImage imageWithCGImage:cg scale:1.0 orientation:orient];
    CGSize size = raw.size;   // already the oriented size: width and height swap
    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    [raw drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    CGImageRelease(cg);

    return UIImageJPEGRepresentation(img, 1.0);
}

// A fingerprint of one still, for the "already filed" list. Not a hash for
// security: it only has to tell two of our own JPEGs apart, and a still is close
// to a megabyte, so FNV-1a over the bytes is enough and needs no import.
static NSString *vcam_still_stamp(NSData *jpeg) {
    uint64_t hash = 1469598103934665603ULL;
    const uint8_t *bytes = (const uint8_t *)jpeg.bytes;
    for (NSUInteger i = 0; i < jpeg.length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx-%lu", hash, (unsigned long)jpeg.length];
}

static NSArray<NSString *> *vcam_still_seen_list(void) {
    NSString *seen = [NSString stringWithContentsOfFile:VCAM_STILL_SEEN_PATH
                                               encoding:NSUTF8StringEncoding error:nil];
    if (seen == nil) return @[];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [seen componentsSeparatedByString:@"\n"]) {
        if (line.length > 0) [lines addObject:line];
    }
    return lines;
}

static void vcam_still_remember(NSString *stamp) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:stamp];
    for (NSString *line in vcam_still_seen_list()) {
        if ([line isEqualToString:stamp]) continue;
        [lines addObject:line];
        if (lines.count >= (NSUInteger)VCAM_STILL_SEEN_KEEP) break;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:VCAM_PLAYBACK_DIR
  withIntermediateDirectories:YES attributes:nil error:nil];
    [[lines componentsJoinedByString:@"\n"] writeToFile:VCAM_STILL_SEEN_PATH
                                             atomically:YES
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
}

// Renders a still the library has not filed yet, and hands back the frame it
// came from. forceRenew: the still path runs off the capture queue, not the
// display link, so it must not be told "not due yet" and hand back nothing.
//
// Why the retry: the library matches a capture against the stills it already
// holds and files a repeat as a *duplicate*, and a duplicate of a Live Photo
// carries that asset's movie along with it — a real-scene movie from an earlier
// capture came back under our photo that way. Since only the picture matters,
// stepping the clip on to the next frame is enough to be a new photo. The list
// outlives the process because the still that collided had been captured before
// the app was last relaunched.
static NSData *vcam_still_jpeg(CMSampleBufferRef *frameOut) {
    NSArray<NSString *> *seen = vcam_still_seen_list();
    CMSampleBufferRef frame = NULL;
    NSData *jpeg = nil;
    NSString *stamp = nil;

    for (int attempt = 0; attempt < 6; attempt++) {
        frame = [VCAMFrameSource nextFrameForBuffer:NULL forceRenew:YES];
        if (frame == NULL) return nil;
        jpeg = vcam_jpeg_from_frame(frame, g_photoOrientation);
        if (jpeg == nil) return nil;

        stamp = vcam_still_stamp(jpeg);
        if (![seen containsObject:stamp]) break;
    }

    vcam_still_remember(stamp);
    if (frameOut != NULL) *frameOut = frame;
    return jpeg;
}

#pragma mark - Preview replacement

static char kVCAMLinkKey;   // association key for the per-layer CADisplayLink

// One clock for every elapsed-time comparison in this file. The wall clock and
// CACurrentMediaTime() sit about 1.79e12 ms apart, so a stamp written on one and
// read on the other turns any "has it been N ms yet" test into a constant: the
// difference goes hugely negative and the comparison is stuck on one arm for the
// life of the process. Which is exactly what a wall-clock stamp in startRunning
// did to the display link's guard in vcam_step:.
static NSTimeInterval vcam_now_ms(void) {
    return CACurrentMediaTime() * 1000.0;
}

// A display layer that is mid-failure refuses new buffers until it is flushed;
// flushing unconditionally on every frame would drop the frame being displayed
// and show a black flash instead.
static void vcam_enqueue_frame(AVSampleBufferDisplayLayer *layer, CMSampleBufferRef buf) {
    if (layer == nil || buf == NULL) return;
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [layer flush];
    }
    if (!layer.readyForMoreMediaData) {
        // Backed up. Normally that is just a slow tick and the next frame goes
        // through, but a layer can wedge — one bad presentation time and it will
        // sit on a queue it never drains, reporting itself as rendering while it
        // shows nothing. Left alone that is permanent, so after a second of
        // refusing everything, flush the backlog away and try again.
        NSTimeInterval now = vcam_now_ms();
        if (g_lastEnqueueOk == 0) g_lastEnqueueOk = now;
        if (now - g_lastEnqueueOk > 1000.0) {
            [layer flush];
            g_lastEnqueueOk = now;
        }
        return;
    }
    g_lastEnqueueOk = vcam_now_ms();
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

    // Cover the camera only while there is a replacement frame to cover it with.
    // The engine legitimately has nothing to hand over at times — no video chosen,
    // or a staged copy that has not landed yet — and a black mask over a working
    // preview is worse than no overlay at all, so an empty tick hides us.
    BOOL active = vcam_active() && g_cameraRunning;
    if (!active) {
        g_maskLayer.opacity = 0;
        g_previewLayer.opacity = 0;
        return;
    }

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
    // That path only stamps the time when it actually enqueued, so this also
    // means the layer is being drawn to right now. Milliseconds on the media
    // clock, matching what the delegate above stamps.
    NSTimeInterval now = vcam_now_ms();
    if (now - g_lastVideoDataOutputTime < 1000) {
        g_maskLayer.opacity = 1;
        g_previewLayer.opacity = 1;
        return;
    }

    CMSampleBufferRef frame = [VCAMFrameSource nextFrameForBuffer:NULL forceRenew:NO];
    if (frame == NULL) {
        // The engine paces itself, so a NULL here is the normal case on most
        // ticks rather than a failure — the clip runs at its own frame rate
        // while this link ticks at screen rate. Only give up on the overlay
        // when nothing has actually landed for a while.
        if (now - g_lastPreviewFrame > 1500) {
            g_maskLayer.opacity = 0;
            g_previewLayer.opacity = 0;
        }
        return;
    }
    g_lastPreviewFrame = now;
    g_maskLayer.opacity = 1;
    g_previewLayer.opacity = 1;
    vcam_enqueue_frame(g_previewLayer, frame);
}

%end

#pragma mark - Capture session / outputs

%hook AVCaptureSession

- (void)startRunning {
    g_cameraRunning = YES;
    g_bufferReload = YES;
    // Nothing has reached the display layer yet, so nothing should be suppressing
    // the display link. Zero means "never", on the media clock every other reader
    // of this stamp uses.
    g_lastVideoDataOutputTime = 0;
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
                g_photoOrientation = [connection videoOrientation];

                CMSampleBufferRef replacement =
                    [VCAMFrameSource nextFrameForBuffer:sampleBuffer forceRenew:NO];

                if (replacement != NULL && g_previewLayer != nil) {
                    vcam_enqueue_frame(g_previewLayer, replacement);
                    // Stamped only once a frame is really on its way to the layer:
                    // the display link reads this to know the layer is covered.
                    g_lastVideoDataOutputTime = vcam_now_ms();
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

#pragma mark - Metadata (QR codes, faces)

// Measured on the test device: the Camera app holds one AVCaptureMetadataOutput
// configured for {org.iso.QRCode, com.apple.AppClipCode, face}, and it is how
// the app recognises a QR code held up to the lens. The detection itself uses
// the real frames, which the substitution never touches — the preview is a layer
// drawn over the live one — so a QR code is still detected over the top of the
// clip. The delegate callback is the only place the app is told about it, so
// while a replacement is active the result array is emptied. An empty array
// rather than no call at all: clients that never hear back keep showing the last
// result.
//
// Two selectors, not one. The header documents
// `captureOutput:didOutputMetadataObjects:fromConnection:`, but the Camera app
// does not implement it at all — it answers the private four-argument variant
// with the tracked types appended, and AVFoundation dispatches to whichever
// shape the delegate responds to:
//
//   CAMCaptureEngine - captureOutput:didOutputMetadataObjects:forMetadataObjectTypes:fromConnection:
//        v48@0:8@16@24@32@40          ← what the app implements
//   CAMCaptureEngine - captureOutput:didOutputMetadataObjects:fromConnection:
//        absent                       ← what this hook used to install itself on
//
// Hooking only the public name therefore added an override on a selector no
// caller ever sends: a silent no-op, and the app kept getting the real QR
// results and raising its banner anyway. Both shapes are hooked now, so a client
// using either one is covered. Measured on 15.7.1.
static NSArray *vcam_metadata_objects(NSArray *objects) {
    return vcam_active() ? @[] : objects;
}

%hook AVCaptureMetadataOutput

- (void)setMetadataObjectsDelegate:(id<AVCaptureMetadataOutputObjectsDelegate>)objectsDelegate
                             queue:(dispatch_queue_t)objectsCallbackQueue {
    if (objectsDelegate == nil || objectsCallbackQueue == nil) {
        %orig;
        return;
    }

    // Lazy, once per class and selector, same as the video data output above.
    static NSMutableSet *hooked = nil;
    if (hooked == nil) hooked = [NSMutableSet new];

    Class cls = [objectsDelegate class];
    NSString *name = NSStringFromClass(cls);
    // Which shapes this delegate answers is a property of the class, so a class
    // that implements neither is left alone rather than given a hook that can
    // never run.
    SEL pair[2] = {
        @selector(captureOutput:didOutputMetadataObjects:fromConnection:),
        NSSelectorFromString(@"captureOutput:didOutputMetadataObjects:forMetadataObjectTypes:fromConnection:"),
    };

    for (int i = 0; i < 2; i++) {
        SEL sel = pair[i];
        NSString *key = [NSString stringWithFormat:@"%@|%d", name, i];
        if ([hooked containsObject:key]) continue;
        if (![cls instancesRespondToSelector:sel]) continue;
        [hooked addObject:key];

        if (i == 0) {
            __block void (*original)(id, SEL, AVCaptureOutput *, NSArray *,
                                     AVCaptureConnection *) = NULL;
            MSHookMessageEx(cls, sel,
                imp_implementationWithBlock(^(id dself, AVCaptureOutput *output,
                                              NSArray *objects,
                                              AVCaptureConnection *connection) {
                    if (original) {
                        original(dself, sel, output, vcam_metadata_objects(objects), connection);
                    }
                }), (IMP *)&original);
        } else {
            // The tracked-types set is passed through untouched: what the
            // delegate sees is then exactly what a frame with nothing in it
            // looks like, rather than a shape no real callback ever has.
            __block void (*original)(id, SEL, AVCaptureOutput *, NSArray *, NSSet *,
                                     AVCaptureConnection *) = NULL;
            MSHookMessageEx(cls, sel,
                imp_implementationWithBlock(^(id dself, AVCaptureOutput *output,
                                              NSArray *objects, NSSet *types,
                                              AVCaptureConnection *connection) {
                    if (original) {
                        original(dself, sel, output, vcam_metadata_objects(objects),
                                 types, connection);
                    }
                }), (IMP *)&original);
        }
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
    NSData *replaced = vcam_still_jpeg(NULL);
    return replaced ?: %orig;
}

%end

// AVCapturePhoto is opaque, so rather than swapping its buffers we intercept the
// representations the client pulls off it. The replacement frame is kept in a
// static and the swizzles are installed once per class.
//
// Two of them matter. -fileDataRepresentation is what gets stored, and
// -previewPixelBuffer is what the corner thumbnail is drawn from — measured on
// the device at a capture where the Camera app pulled that one accessor and
// nothing else off the photo. The framework fills the preview buffer from the
// real sensor, which is why the saved photo was the clip while the thumbnail
// beside it still showed the room the phone was pointed at.
static NSData *g_photoJPEG = nil;
static CMSampleBufferRef g_photoFrame = NULL;   // keeps the pixels below alive
static NSMutableArray *g_photoHookedClasses = nil;

// The preview buffer is handed over in the camera's own geometry, not in the
// upright one the file is stored in. Measured on the test device: the framework
// produced an 852x640 buffer for a preview request that named no dimensions, and
// for its own captures the Camera app asks for 2208x1242 — landscape both times,
// with the phone held in portrait. What turns it upright is the client, using
// the capture's orientation (EXIF 6 here, a quarter turn clockwise). So a buffer
// that arrives already upright leaves the app's own turn to do, and the corner
// thumbnail comes out on its side — which is what the substituted frame did.
// Turning the frame the other way ourselves lands the app's turn upright, and
// the buffer is built at the size the app asked for.
static CVPixelBufferRef g_photoPreview = NULL;
static size_t g_previewWidth = 0, g_previewHeight = 0;

static CVPixelBufferRef vcam_preview_buffer(CMSampleBufferRef frame) {
    CVImageBufferRef pixels = frame ? CMSampleBufferGetImageBuffer(frame) : NULL;
    if (pixels == NULL) return NULL;

    size_t srcW = CVPixelBufferGetWidth(pixels);
    size_t srcH = CVPixelBufferGetHeight(pixels);
    // The shape the app asked for when it named one, the frame's own turned on
    // its side otherwise. On this camera the two agree on aspect to within a
    // rounding, so neither path stretches the picture.
    size_t outW = g_previewWidth  ? g_previewWidth  : srcH;
    size_t outH = g_previewHeight ? g_previewHeight : srcW;
    if (outW == 0 || outH == 0) return NULL;

    CIImage *ci = [CIImage imageWithCVImageBuffer:pixels];
    if (ci == nil) return NULL;
    // Orientation 8, not the 6 the camera stamps into its own captures: what the
    // app does with the buffer is apply 6 to it, and 8 is 6's inverse. Applying
    // the same turn the app is about to apply would only put the picture right
    // way up again on the second pass, which measured as an upside-down
    // thumbnail. Measured semantics of -imageByApplyingOrientation: on this
    // build: the value's own turn is applied to the pixels, so 6 turns them a
    // quarter clockwise and 8 turns them a quarter counter-clockwise.
    if ([ci respondsToSelector:@selector(imageByApplyingOrientation:)]) {
        ci = [ci imageByApplyingOrientation:8];
    } else {
        ci = [ci imageByApplyingTransform:CGAffineTransformMake(0, 1, -1, 0, srcH, 0)];
    }

    // Scaled to the target shape here rather than left to the render call, so
    // the result is the same whether bounds is read as "scale this region into
    // the buffer" or "copy this region into the buffer".
    CGRect extent = ci.extent;
    if (extent.size.width <= 0 || extent.size.height <= 0) return NULL;
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(outW / extent.size.width,
                                                                outH / extent.size.height)];

    NSDictionary *attrs = @{ (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef dest = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, outW, outH, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &dest) != kCVReturnSuccess) {
        return NULL;
    }

    static CIContext *ctx = nil;
    if (ctx == nil) ctx = [CIContext contextWithOptions:nil];
    static CGColorSpaceRef space = NULL;
    if (space == NULL) space = CGColorSpaceCreateDeviceRGB();
    [ctx render:ci toCVPixelBuffer:dest bounds:CGRectMake(0, 0, outW, outH) colorSpace:space];
    return dest;
}

static void vcam_install_photo_overrides(id photo) {
    if (photo == nil) return;

    // One frame serves both the file and the thumbnail. Held rather than used
    // and dropped: the engine releases its cached frame on the next call, and
    // the client may still be rendering from this one.
    CMSampleBufferRef frame = NULL;
    NSData *jpeg = vcam_still_jpeg(&frame);
    if (frame == NULL || jpeg == nil) return;
    if (g_photoFrame != NULL) CFRelease(g_photoFrame);
    g_photoFrame = frame;
    CFRetain(g_photoFrame);

    // The previous capture's buffer is only released now: the thumbnail of the
    // one before it may still be on screen.
    if (g_photoPreview != NULL) {
        CVPixelBufferRelease(g_photoPreview);
        g_photoPreview = NULL;
    }
    g_photoPreview = vcam_preview_buffer(g_photoFrame);

    g_photoJPEG = jpeg;

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

    __block CVPixelBufferRef (*origPrev)(id, SEL) = NULL;
    MSHookMessageEx([photo class], @selector(previewPixelBuffer),
        imp_implementationWithBlock(^(id pself, SEL _cmd) {
            if (g_photoPreview != NULL) return g_photoPreview;
            return origPrev ? origPrev(pself, _cmd) : NULL;
        }), (IMP *)&origPrev);
}

%hook AVCapturePhotoOutput

+ (NSData *)JPEGPhotoDataRepresentationForJPEGSampleBuffer:(CMSampleBufferRef)JPEGSampleBuffer
                                    previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer {
    NSData *replaced = vcam_still_jpeg(NULL);
    return replaced ?: %orig;
}

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                        delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (settings != nil && delegate != nil) {
        // The shape the client wants its preview back in. Measured here: the
        // Camera app names one (2208x1242) while the framework picks a
        // display-sized one (852x640) when nothing is named.
        NSDictionary *previewFormat = settings.previewPhotoFormat;
        if (previewFormat != nil) {
            NSNumber *width = previewFormat[(id)kCVPixelBufferWidthKey];
            NSNumber *height = previewFormat[(id)kCVPixelBufferHeightKey];
            if (width != nil && height != nil) {
                g_previewWidth = width.unsignedIntegerValue;
                g_previewHeight = height.unsignedIntegerValue;
            }
        }

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

            // Live Photo movie. Same delegate, one callback later: the daemon has
            // just finished writing the real movie into the URL the app named, and
            // the app has not been told yet. Swapping the file here means the app
            // — and the library it hands the pair to — only ever sees the clip.
            // The callback is optional, so the class is asked before hooking it.
            SEL liveSel = @selector(captureOutput:didFinishProcessingLivePhotoToMovieFileAtURL:
                                    duration:photoDisplayTime:resolvedSettings:error:);
            if (class_getInstanceMethod([delegate class], liveSel) != NULL) {
                __block void (*origLive)(id, SEL, AVCapturePhotoOutput *, NSURL *,
                                         CMTime, CMTime, id, NSError *) = NULL;
                MSHookMessageEx([delegate class], liveSel,
                    imp_implementationWithBlock(^(id dself, AVCapturePhotoOutput *output,
                                                  NSURL *url, CMTime duration,
                                                  CMTime displayTime, id resolved,
                                                  NSError *error) {
                        if (url == nil || error != nil || !vcam_active()) {
                            if (origLive) {
                                origLive(dself, liveSel, output, url, duration,
                                         displayTime, resolved, error);
                            }
                            return;
                        }
                        vcam_replace_live_movie(url, ^(BOOL replaced) {
                            if (origLive) {
                                origLive(dself, liveSel, output, url, duration,
                                         displayTime, resolved, error);
                            }
                        });
                    }), (IMP *)&origLive);
            }
        }
    }
    %orig;
}

%end

#pragma mark - Recording

// Video has no frame delegate to intercept: AVCaptureMovieFileOutput hands the
// file to the media daemon, which writes the camera's own buffers into it, so
// nothing hooked in this process ever sees the frames. The only way in is to
// redirect the recording to a scratch file and put the chosen clip in place of
// the result once recording stops.

// Scratch URL we actually recorded to -> the URL the app asked for.
static NSMutableDictionary *g_recordingURLs = nil;
static NSUInteger g_recordingSeq = 0;

// Puts the chosen clip at `appURL`, cut to at most `length`, then reports on the
// main queue — where AVCaptureFileOutput delivers its delegate calls and where
// the app reads the file back.
static void vcam_export_clip(NSURL *appURL, CMTime length, void (^done)(BOOL replaced)) {
    NSString *source = [VCAMFrameSource playbackPath];
    if (source == nil) { done(NO); return; }

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtURL:appURL error:nil];

    AVURLAsset *sourceAsset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:source] options:nil];

    // Not named `export`: Theos compiles this file as Objective-C++, where that
    // is a keyword.
    AVAssetExportSession *writer =
        [AVAssetExportSession exportSessionWithAsset:sourceAsset
                                          presetName:AVAssetExportPresetPassthrough];
    if (writer == nil) {
        BOOL copied = [fm copyItemAtPath:source toPath:appURL.path error:nil];
        done(copied);
        return;
    }

    // Passthrough re-muxes rather than re-encodes, which matters on a phone this
    // old: a re-encode of a minute of 1080p is not something to sit through at
    // the end of a recording.
    writer.outputURL = appURL;
    writer.outputFileType = [appURL.pathExtension.lowercaseString isEqualToString:@"mp4"]
                                ? AVFileTypeMPEG4 : AVFileTypeQuickTimeMovie;
    if (CMTIME_IS_NUMERIC(length) && CMTimeCompare(length, kCMTimeZero) > 0) {
        writer.timeRange = CMTimeRangeMake(kCMTimeZero, length);
    }

    [writer exportAsynchronouslyWithCompletionHandler:^{
        BOOL ok = (writer.status == AVAssetExportSessionStatusCompleted);
        if (!ok) {
            // A container the passthrough would not carry still holds a playable
            // clip, so fall back to the bytes as they are.
            [fm removeItemAtURL:appURL error:nil];
            ok = [fm copyItemAtPath:source toPath:appURL.path error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    }];
}

// The recording: the clip stands in for what was recorded, cut to the length
// that was actually recorded.
static void vcam_replace_recording(NSURL *appURL, NSURL *recorded, void (^done)(BOOL replaced)) {
    NSString *source = [VCAMFrameSource playbackPath];
    if (source == nil) { done(NO); return; }

    AVURLAsset *recordedAsset = [AVURLAsset URLAssetWithURL:recorded options:nil];
    AVURLAsset *sourceAsset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:source] options:nil];
    CMTime sourceLength = sourceAsset.duration;
    CMTime recordedLength = recordedAsset.duration;

    // The clip should not outlast the recording. An unreadable or zero length
    // falls back to the whole clip rather than to a still.
    CMTime length = sourceLength;
    if (CMTIME_IS_NUMERIC(recordedLength) && CMTIME_IS_NUMERIC(sourceLength) &&
        CMTimeCompare(recordedLength, kCMTimeZero) > 0 &&
        CMTimeCompare(recordedLength, sourceLength) < 0) {
        length = recordedLength;
    }

    vcam_export_clip(appURL, length, done);
}

// AVMediaTypeMetadata, which the SDK in use does not declare. Measured on the
// device: a Live Photo's movie reports "meta" for each of its metadata tracks.
static NSString *const VCAMMediaTypeMeta = @"meta";

// The movie beside a Live Photo. It is written by the camera daemon, not by this
// process — the frames of a Live Photo movie never pass through an app — so it
// gets the same treatment as a recording: whatever landed where the app expects
// its movie is replaced by the clip, cut to the movie's own length so the Live
// Photo keeps its shape.
//
// A Live Photo's movie is not just any movie, though. Measured on the device: the
// one the daemon writes carries three metadata tracks beside its picture and its
// sound, and the library reads those to accept the movie as this photo's other
// half. A movie exported from the clip alone has none of them, and the pair is
// refused: the still is filed on its own and the movie is left behind in
// `DCIM/.MISC/Incoming`. So the metadata tracks and the top-level metadata — the
// identifier among them — are carried over from the movie the daemon just wrote.
//
// The result is then written back over that file in place rather than swapped in
// as a new one, so the file the library watched the daemon create is still there.
static void vcam_replace_live_movie(NSURL *url, void (^done)(BOOL replaced)) {
    NSString *source = [VCAMFrameSource playbackPath];
    if (url == nil || source == nil) { done(NO); return; }

    AVURLAsset *movie = [AVURLAsset URLAssetWithURL:url options:nil];
    AVURLAsset *clip = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:source] options:nil];

    CMTime clipLength = clip.duration;
    CMTime movieLength = movie.duration;
    CMTime length = clipLength;
    if (CMTIME_IS_NUMERIC(movieLength) && CMTIME_IS_NUMERIC(clipLength) &&
        CMTimeCompare(movieLength, kCMTimeZero) > 0 &&
        CMTimeCompare(movieLength, clipLength) < 0) {
        length = movieLength;
    }
    if (!CMTIME_IS_NUMERIC(length) || CMTimeCompare(length, kCMTimeZero) <= 0) {
        done(NO);
        return;
    }
    CMTimeRange range = CMTimeRangeMake(kCMTimeZero, length);

    AVMutableComposition *comp = [AVMutableComposition composition];
    NSError *error = nil;
    for (AVAssetTrack *track in clip.tracks) {
        if (![track.mediaType isEqualToString:AVMediaTypeVideo] &&
            ![track.mediaType isEqualToString:AVMediaTypeAudio]) {
            continue;
        }
        AVMutableCompositionTrack *added =
            [comp addMutableTrackWithMediaType:track.mediaType
                            preferredTrackID:kCMPersistentTrackID_Invalid];
        [added insertTimeRange:range ofTrack:track atTime:kCMTimeZero error:&error];
    }
    for (AVAssetTrack *track in movie.tracks) {
        if (![track.mediaType isEqualToString:VCAMMediaTypeMeta]) continue;
        AVMutableCompositionTrack *added =
            [comp addMutableTrackWithMediaType:track.mediaType
                            preferredTrackID:kCMPersistentTrackID_Invalid];
        CMTime trackLength = track.timeRange.duration;
        CMTime take = (CMTimeCompare(trackLength, length) < 0) ? trackLength : length;
        [added insertTimeRange:CMTimeRangeMake(kCMTimeZero, take)
                       ofTrack:track atTime:kCMTimeZero error:&error];
    }

    NSURL *temp = [NSURL fileURLWithPath:
                   [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_live_movie.mov"]];

    AVAssetExportSession *writer =
        [AVAssetExportSession exportSessionWithAsset:comp
                                          presetName:AVAssetExportPresetPassthrough];
    if (writer == nil) {
        // Nothing to carry the metadata with. A movie the library will not pair
        // with its photo still beats no movie at all.
        vcam_export_clip(url, length, done);
        return;
    }
    writer.outputURL = temp;
    writer.outputFileType = AVFileTypeQuickTimeMovie;
    writer.metadata = movie.metadata;
    writer.timeRange = CMTimeRangeMake(kCMTimeZero, length);

    [writer exportAsynchronouslyWithCompletionHandler:^{
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL ok = (writer.status == AVAssetExportSessionStatusCompleted);
        if (ok) {
            NSData *bytes = [NSData dataWithContentsOfURL:temp];
            ok = (bytes != nil) && [bytes writeToFile:url.path atomically:NO];
            if (!ok) {
                [fm removeItemAtURL:url error:nil];
                ok = [fm moveItemAtURL:temp toURL:url error:nil];
            }
        }
        [fm removeItemAtURL:temp error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
    }];
}

%hook AVCaptureMovieFileOutput

- (void)startRecordingToOutputFileURL:(NSURL *)outputFileURL
                    recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    if (outputFileURL == nil || delegate == nil || !vcam_active()) {
        %orig;
        return;
    }

    // Same directory as the app's own file, so the media daemon can open it —
    // it is the daemon that writes the recording. Only the name differs.
    NSString *ext = outputFileURL.pathExtension.length ? outputFileURL.pathExtension : @"mov";
    NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"vcam_recording_%lu.%@",
                          (unsigned long)++g_recordingSeq, ext]];

    if (g_recordingURLs == nil) g_recordingURLs = [NSMutableDictionary new];
    g_recordingURLs[scratch] = outputFileURL;

    // The app's delegate class is only known at runtime, so the finish callback
    // is hooked lazily on first sight, once per class.
    static NSMutableArray *hookedClasses = nil;
    if (hookedClasses == nil) hookedClasses = [NSMutableArray new];
    NSString *cls = NSStringFromClass([delegate class]);

    if (![hookedClasses containsObject:cls]) {
        [hookedClasses addObject:cls];
        __block void (*original)(id, SEL, AVCaptureFileOutput *,
                                 NSURL *, NSArray *, NSError *) = NULL;
        MSHookMessageEx(
            [delegate class],
            @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:),
            imp_implementationWithBlock(^(id dself, AVCaptureFileOutput *output,
                                          NSURL *url, NSArray *connections,
                                          NSError *error) {
                NSURL *appURL = g_recordingURLs[url.path];
                if (appURL == nil) {
                    if (original) {
                        original(dself, @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:),
                                 output, url, connections, error);
                    }
                    return;
                }
                // Deliberately kept. `outputFileURL` is asked for again after the
                // recording ends — that is when the app hands the file to the
                // library — and the answer has to stay the app's own URL for the
                // rest of the session, or the scratch path leaks back out.

                vcam_replace_recording(appURL, url, ^(BOOL replaced) {
                    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
                    // A failed replacement leaves the real recording, which is
                    // worse to watch but not broken: the app still gets a file.
                    if (original) {
                        original(dself, @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:),
                                 output, replaced ? appURL : url, connections, error);
                    }
                });
            }),
            (IMP *)&original);
    }

    %orig(scratch ? [NSURL fileURLWithPath:scratch] : outputFileURL, delegate);
}

// The app reads this back and hands the answer to Photos. Left alone it reports
// the scratch path, so the media library copies the real scene into DCIM as an
// asset of its own — and, because the scratch is deleted as soon as the clip is
// written, an unfinished one: no `moov`, so it never plays.
//
// Reporting the URL the app actually asked for sends that copy to the file the
// clip is written to instead. The scratch stays ours, and the only thing the
// library ever sees is the replacement.
- (NSURL *)outputFileURL {
    NSURL *url = %orig;
    if (url != nil && g_recordingURLs != nil) {
        NSURL *appURL = g_recordingURLs[url.path];
        if (appURL != nil) return appURL;
    }
    return url;
}

%end

#pragma mark - SpringBoard: volume buttons drive the overlay

static NSTimeInterval g_lastUp = 0;
static NSTimeInterval g_lastDown = 0;
static NSTimeInterval g_lastToggle = 0;

// How far apart the two presses may land and still count as one gesture. The
// first cut used 200ms, which is tight even when you are trying to hit it — a
// human pressing two buttons in sequence routinely lands nearer 300ms. Measured
// on the device while chasing the crash above: attempts landed 0.42s, 0.50s and
// 1.95s apart, so 0.45s rejected two of the three. A deliberate one-button
// fine-tune is not normally that fast; if this starts firing by accident, 0.45
// is the number to go back to.
#define VCAM_DP_WINDOW 0.8

static void vcam_volume_pressed(BOOL isUp) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (isUp) g_lastUp = now; else g_lastDown = now;

    if (g_lastUp == 0 || g_lastDown == 0) return;
    if (fabs(g_lastUp - g_lastDown) > VCAM_DP_WINDOW) return;
    if (now - g_lastToggle < 1.0) return;
    g_lastToggle = now;
    // Retire both stamps. Left standing, a single press a second from now would
    // pair with the stale one and toggle again on its own.
    g_lastUp = 0;
    g_lastDown = 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        [VCAMOverlay toggle];
    });
}

%group SpringBoard

// Volume presses are hooked at every layer that can carry one, because the
// layer that carries them depends on who is using the buttons. In the Camera
// app they are a shutter: the app takes the press through
// SBHardwareButtonService and SpringBoard never acts on it, so SBVolumeControl's
// increaseVolume/decreaseVolume — the obvious hook, and the only one the first
// cut had — is simply never called there. Measured on 15.7.1, SpringBoard's
// volume plumbing is:
//
//   SBVolumeHardwareButton         volumeIncreasePress: / volumeDecreasePress:
//   SBVolumeHardwareButtonActions  volumeIncreasePressDownWithModifiers:
//   SBHardwareButtonService        consumeVolumeIncreaseButtonSinglePressDown…
//   SBVolumeControl                increaseVolume / decreaseVolume
//
// The first two run for every physical press whatever happens to it later, so
// they are the ones that work in the Camera. The others are kept because they
// are right elsewhere (the volume HUD, and any press SpringBoard does act on).
// Overlap is harmless: a duplicated press sets the same stamp twice, and the
// stamps are retired once a gesture has fired.
%hook SBVolumeHardwareButton

- (void)volumeIncreasePress:(id)press {
    %orig;
    vcam_volume_pressed(YES);
}

- (void)volumeDecreasePress:(id)press {
    %orig;
    vcam_volume_pressed(NO);
}

%end

%hook SBVolumeHardwareButtonActions

- (void)volumeIncreasePressDownWithModifiers:(long long)modifiers {
    %orig;
    vcam_volume_pressed(YES);
}

- (void)volumeDecreasePressDownWithModifiers:(long long)modifiers {
    %orig;
    vcam_volume_pressed(NO);
}

%end

// Observing only — these answer "did a client take the press?", so returning
// %orig's answer untouched keeps the Camera's shutter working.
//
// The second argument is NOT an object, whatever the name suggests. Its type
// encoding is `o^@?` — an out-pointer to a block, i.e. the caller passes the
// address of a slot it expects to be filled in, and that slot is normally NULL.
// Declaring it `(id)` makes ARC retain it on entry, so the retain reads the
// slot's contents as an isa (0), then follows it to 0x20, and the process dies:
//
//   objc_retain + 16                              EXC_BAD_ACCESS, at 0x20
//   VCAMLight.dylib   + 42816
//   -[SBVolumeHardwareButtonActions _handleVolumeButtonDownForIncrease:modifiers:]
//   VCAMLight.dylib   + 42736
//   -[SBVolumeHardwareButton volumeIncreasePress:]
//   VCAMLight.dylib   + 42560
//
// Measured on 15.7.1 (SpringBoard crash of 2026-09-24 09:47). A pointer type is
// never retained, so `void **` both matches the ABI and stops ARC touching it.
%hook SBHardwareButtonService

- (BOOL)consumeVolumeIncreaseButtonSinglePressDownWithPriority:(long long)priority
                                                  continuation:(void **)continuation {
    BOOL taken = %orig;
    vcam_volume_pressed(YES);
    return taken;
}

- (BOOL)consumeVolumeDecreaseButtonSinglePressDownWithPriority:(long long)priority
                                                  continuation:(void **)continuation {
    BOOL taken = %orig;
    vcam_volume_pressed(NO);
    return taken;
}

%end

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
