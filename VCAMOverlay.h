// VCAMOverlay.h
#import <UIKit/UIKit.h>
#import <notify.h>

// ── Shared on-device paths ────────────────────────────────────────────────────
// The overlay runs in SpringBoard and the frame engine runs inside every app
// that opens the camera, so both sides must agree on these.
//
// These live under /var/mobile/Media, and it has to be there. The reader is a
// sandboxed app, and on a RootHide jailbreak the app sandbox is left intact, so
// nothing under /var/mobile/Library is reachable — measured from the Camera app:
//
//   /var/mobile/Library/Caches/...              not readable
//   /var/mobile/Library/Preferences/...         not readable
//   /var/mobile/Library/Application Support/... not readable
//   /var/mobile/Media/...                       readable
//
// Media is the one shared tree apps get read access to (the photo library
// grant). Only SpringBoard writes here, which it can; apps only ever read.
#define VCAM_DIR        @"/var/mobile/Media/.vcamlight"
#define VCAM_VIDEO_PATH @"/var/mobile/Media/.vcamlight/selected.mov"
#define VCAM_PREFS_PATH @"/var/mobile/Media/.vcamlight/prefs.plist"
// Touched whenever the selected video changes, so readers pick up the new file.
#define VCAM_CHANGED_MARK @"/var/mobile/Media/.vcamlight/selected.mov.new"
#define VCAM_DARWIN_NOTE "com.vcamlight.videochanged"

@interface VCAMOverlay : NSObject
+ (instancetype)shared;
+ (void)toggle;
+ (void)show;
+ (void)hide;
@end
