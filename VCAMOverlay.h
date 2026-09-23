// VCAMOverlay.h
#import <UIKit/UIKit.h>
#import <notify.h>

// ── Shared on-device paths ────────────────────────────────────────────────────
// The overlay runs in SpringBoard and the frame engine runs inside every app
// that opens the camera, so both sides must agree on these.
//
// The master copy lives under /var/mobile/Media, and it has to be there. The
// reader is a sandboxed app, and on a RootHide jailbreak the app sandbox is left
// intact, so nothing under /var/mobile/Library is reachable — measured from the
// Camera app:
//
//   /var/mobile/Library/Caches/...              not readable
//   /var/mobile/Library/Preferences/...         not readable
//   /var/mobile/Library/Application Support/... not readable
//   /var/mobile/Media/...                       readable
//
// Only SpringBoard writes the master, which it can; apps only ever read it.
#define VCAM_DIR        @"/var/mobile/Media/.vcamlight"
#define VCAM_VIDEO_PATH @"/var/mobile/Media/.vcamlight/selected.mov"
#define VCAM_PREFS_PATH @"/var/mobile/Media/.vcamlight/prefs.plist"
// Touched whenever the selected video changes, so readers pick up the new file.
#define VCAM_CHANGED_MARK @"/var/mobile/Media/.vcamlight/selected.mov.new"
#define VCAM_DARWIN_NOTE "com.vcamlight.videochanged"

// ── Playback copy ─────────────────────────────────────────────────────────────
// Reading the master's bytes from an app is allowed, but *decoding* it is not:
// AVAssetReader hands the URL to the media daemon, and the daemon will only open
// paths the app's sandbox already covers. Measured from inside com.apple.camera,
// same file, same app:
//
//   /var/mobile/Media/.vcamlight/selected.mov   reader nil (OSStatus -17507)
//   /var/mobile/Media/VCAMLight/selected.mov    reader nil (dir we created)
//   /var/mobile/Media/DCIM/…                    reader ok
//   /var/tmp/…                                  reader ok
//
// So the app stages its own copy under /var/tmp and decodes that. /var/tmp is
// world-writable and the system clears it, hence the stamp file: it records which
// master revision the copy came from, so a swapped video re-copies and an
// ordinary reload does not push megabytes through the filesystem on every loop.
#define VCAM_PLAYBACK_DIR   @"/var/tmp/vcamlight"
#define VCAM_PLAYBACK_PATH  @"/var/tmp/vcamlight/selected.mov"
#define VCAM_PLAYBACK_STAMP @"/var/tmp/vcamlight/stamp"

@interface VCAMOverlay : NSObject
+ (instancetype)shared;
+ (void)toggle;
+ (void)show;
+ (void)hide;
@end
