// VCAMOverlay.h
#import <UIKit/UIKit.h>
#import <notify.h>

// ── Shared on-device paths ────────────────────────────────────────────────────
// The overlay runs in SpringBoard and the frame engine runs inside every app
// that opens the camera, so both sides must agree on these.
//
// This lives under /var/mobile/Library/Caches rather than /var/tmp because the
// reading side (AVAssetReader inside a sandboxed app) has to be able to open
// the video; /var/tmp is not reachable from an app sandbox.
#define VCAM_DIR        @"/var/mobile/Library/Caches/vcamlight"
#define VCAM_VIDEO_PATH @"/var/mobile/Library/Caches/vcamlight/selected.mov"
#define VCAM_PREFS_PATH @"/var/mobile/Library/Caches/vcamlight/prefs.plist"
// Touched whenever the selected video changes, so readers pick up the new file.
#define VCAM_CHANGED_MARK @"/var/mobile/Library/Caches/vcamlight/selected.mov.new"
#define VCAM_DARWIN_NOTE "com.vcamlight.videochanged"

@interface VCAMOverlay : NSObject
+ (instancetype)shared;
+ (void)toggle;
+ (void)show;
+ (void)hide;
@end
