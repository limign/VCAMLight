// VCAMOverlay.mm
// VCAMLight — Exact replica of LordVCAM's aesthetics and user interface.
// Restores original mediaserverd hooks.

#import "VCAMOverlay.h"
#import <AVFoundation/AVFoundation.h>

// ── Forward declarations for PhotosUI ─────────────────────────────────────────
@interface PHPickerResult : NSObject
@property (nonatomic, strong, readonly) NSItemProvider *itemProvider;
@end

@interface PHPickerFilter : NSObject
+ (PHPickerFilter *)videosFilter;
@end

@interface PHPickerConfiguration : NSObject
@property (nonatomic, copy) PHPickerFilter *filter;
@property (nonatomic, assign) NSInteger selectionLimit;
- (instancetype)init;
@end

@interface PHPickerViewController : UIViewController
- (instancetype)initWithConfiguration:(PHPickerConfiguration *)configuration;
@property (nonatomic, weak) id delegate;
@end

@protocol PHPickerViewControllerDelegate <NSObject>
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results;
@end

// ── Colors from Screenshot ────────────────────────────────────────────────────
#define CLR_OVERLAY_BG   [UIColor colorWithWhite:0 alpha:0.4]
#define CLR_CARD         [UIColor colorWithRed:0.22 green:0.22 blue:0.24 alpha:0.95]
#define CLR_PURPLE       [UIColor colorWithRed:0.55 green:0.35 blue:1.0 alpha:1.0]
#define CLR_BTN_DARK     [UIColor colorWithRed:0.35 green:0.35 blue:0.38 alpha:1.0]
#define CLR_WALLET       [UIColor colorWithRed:0.25 green:0.60 blue:0.75 alpha:1.0]
#define CLR_RED          [UIColor colorWithRed:0.90 green:0.30 blue:0.25 alpha:1.0]
#define CLR_SUPPORT      [UIColor colorWithRed:0.20 green:0.60 blue:1.0 alpha:1.0]
#define CLR_GOLD         [UIColor colorWithRed:1.0 green:0.85 blue:0.0 alpha:1.0]

@interface VCAMOverlay () <PHPickerViewControllerDelegate>

@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) UIView   *mainCard;

@property (nonatomic, strong) UIButton *galleryBtn;
@property (nonatomic, strong) UIButton *disableBtn;
@property (nonatomic, strong) UISwitch *audioSwitch;
@property (nonatomic, strong) UISwitch *shortcutSwitch;

@property (nonatomic, strong) NSURL    *selectedVideoURL;

@end

@implementation VCAMOverlay

+ (instancetype)shared {
    static VCAMOverlay *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [VCAMOverlay new]; });
    return inst;
}

// Every entry point lands on the main thread before touching anything. performShow
// builds a UIWindow synchronously with the caller's thread, and doing that off the
// main thread aborts the process inside QuartzCore's implicit-transaction check —
// measured as a SpringBoard crash with CA::Transaction::push on the stack.
+ (void)toggle {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self toggle]; });
        return;
    }
    VCAMOverlay *ov = [self shared];
    if (ov.overlayWindow && !ov.overlayWindow.hidden) {
        [ov performHide];
    } else {
        [ov performShow];
    }
}

+ (void)show {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self show]; });
        return;
    }
    [[self shared] performShow];
}

+ (void)hide {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self hide]; });
        return;
    }
    [[self shared] performHide];
}

- (void)performShow {
    if (!self.overlayWindow) [self buildWindow];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.overlayWindow.hidden = NO;
        self.mainCard.transform = CGAffineTransformMakeScale(0.9, 0.9);
        self.mainCard.alpha = 0;
        
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.mainCard.transform = CGAffineTransformIdentity;
            self.mainCard.alpha = 1;
        } completion:nil];
    });
}

- (void)performHide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{
            self.mainCard.transform = CGAffineTransformMakeScale(0.9, 0.9);
            self.mainCard.alpha = 0;
        } completion:^(BOOL finished) {
            self.overlayWindow.hidden = YES;
            self.mainCard.transform = CGAffineTransformIdentity;
        }];
    });
}

// ── Window & UI Construction ──────────────────────────────────────────────────

- (void)buildWindow {
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s; break;
        }
    }
    if (scene) {
        self.overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        self.overlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    self.overlayWindow.backgroundColor = [UIColor clearColor];

    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = CLR_OVERLAY_BG;
    self.overlayWindow.rootViewController = root;

    // Full screen background tap to dismiss
    UIButton *backdropBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    backdropBtn.frame = [UIScreen mainScreen].bounds;
    backdropBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [backdropBtn addTarget:self action:@selector(performHide) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:backdropBtn];

    [self buildMainCard];
    [root.view addSubview:self.mainCard];
}

- (void)buildMainCard {
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat cardW = 320;
    CGFloat cardH = 430;
    CGFloat cardX = (sw - cardW) / 2;
    CGFloat cardY = ([UIScreen mainScreen].bounds.size.height - cardH) / 2;

    self.mainCard = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
    self.mainCard.backgroundColor = CLR_CARD;
    self.mainCard.layer.cornerRadius = 24;
    self.mainCard.layer.masksToBounds = YES;
    
    // Blur effect
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = self.mainCard.bounds;
    blurView.alpha = 0.9;
    [self.mainCard addSubview:blurView];

    // Header: LordVCAM 📷 👑
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, 200, 24)];
    title.text = @"LordVCAM 📷 👑";
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.textColor = CLR_GOLD;
    [self.mainCard addSubview:title];

    // Close Button (Red Circle with X)
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(cardW - 44, 16, 28, 28);
    closeBtn.backgroundColor = [CLR_RED colorWithAlphaComponent:0.3];
    closeBtn.layer.cornerRadius = 14;
    closeBtn.layer.borderWidth = 1;
    closeBtn.layer.borderColor = [CLR_RED CGColor];
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:CLR_RED forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [closeBtn addTarget:self action:@selector(performHide) forControlEvents:UIControlEventTouchUpInside];
    [self.mainCard addSubview:closeBtn];

    // Chevron up icon near close button
    UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(cardW - 74, 20, 20, 20)];
    chevron.text = @"⌃";
    chevron.textColor = [UIColor whiteColor];
    chevron.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [self.mainCard addSubview:chevron];

    // Subtitle Line (Remaining: 59m R$ 0.10 testee@gmail.com)
    UILabel *subTitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 50, cardW, 16)];
    subTitle.textAlignment = NSTextAlignmentCenter;
    subTitle.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    
    NSMutableAttributedString *str = [[NSMutableAttributedString alloc] initWithString:@"Remaining: 59m R$ 0.10 testee@gmail.com"];
    [str addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1] range:NSMakeRange(0, 14)];
    [str addAttribute:NSForegroundColorAttributeName value:CLR_RED range:NSMakeRange(15, 7)];
    [str addAttribute:NSForegroundColorAttributeName value:[UIColor lightGrayColor] range:NSMakeRange(23, 16)];
    subTitle.attributedText = str;
    [self.mainCard addSubview:subTitle];

    // ── Row 1 Buttons: Stream & Gallery ──
    CGFloat btnW = (cardW - 40) / 2;
    CGFloat row1Y = 80;
    
    UIButton *streamBtn = [self makeButton:@"⚡ Stream" frame:CGRectMake(16, row1Y, btnW, 44) color:CLR_BTN_DARK];
    [streamBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [self.mainCard addSubview:streamBtn];

    self.galleryBtn = [self makeButton:@"🖼 Gallery" frame:CGRectMake(16 + btnW + 8, row1Y, btnW, 44) color:CLR_PURPLE];
    [self.mainCard addSubview:self.galleryBtn];

    // ── Row 2 Buttons: Select & Disable ──
    CGFloat row2Y = row1Y + 44 + 8;
    
    UIButton *selectBtn = [self makeButton:@"🖼 Select" frame:CGRectMake(16, row2Y, btnW, 44) color:CLR_PURPLE];
    [selectBtn addTarget:self action:@selector(selectVideo) forControlEvents:UIControlEventTouchUpInside];
    [self.mainCard addSubview:selectBtn];

    self.disableBtn = [self makeButton:@"🚫 Disable" frame:CGRectMake(16 + btnW + 8, row2Y, btnW, 44) color:CLR_BTN_DARK];
    [self.disableBtn addTarget:self action:@selector(disableCamera) forControlEvents:UIControlEventTouchUpInside];
    [self.mainCard addSubview:self.disableBtn];

    // ── Switches ──
    CGFloat switchY = row2Y + 44 + 20;
    
    UILabel *audioLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, switchY, 200, 30)];
    audioLbl.text = @"Audio Source";
    audioLbl.textColor = [UIColor whiteColor];
    audioLbl.font = [UIFont systemFontOfSize:14];
    [self.mainCard addSubview:audioLbl];

    self.audioSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 70, switchY, 50, 30)];
    [self.mainCard addSubview:self.audioSwitch];

    CGFloat switch2Y = switchY + 40;
    UILabel *shortcutLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, switch2Y, 200, 30)];
    shortcutLbl.text = @"Shortcut Floating Window";
    shortcutLbl.textColor = [UIColor whiteColor];
    shortcutLbl.font = [UIFont systemFontOfSize:14];
    [self.mainCard addSubview:shortcutLbl];

    self.shortcutSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - 70, switch2Y, 50, 30)];
    self.shortcutSwitch.on = YES;
    self.shortcutSwitch.onTintColor = CLR_GOLD;
    [self.mainCard addSubview:self.shortcutSwitch];

    // ── Wallet Button ──
    CGFloat walletY = switch2Y + 40;
    UIButton *walletBtn = [self makeButton:@"📄 Wallet (R$ 0.10)" frame:CGRectMake(16, walletY, cardW - 32, 44) color:CLR_WALLET];
    [self.mainCard addSubview:walletBtn];

    // ── Bottom Row: Logout & Contact Support ──
    CGFloat bottomRowY = walletY + 44 + 12;
    UIButton *logoutBtn = [self makeButton:@"🚪 Logout" frame:CGRectMake(16, bottomRowY, btnW, 44) color:CLR_RED];
    [self.mainCard addSubview:logoutBtn];

    UIButton *supportBtn = [self makeButton:@"✈ Contact Support" frame:CGRectMake(16 + btnW + 8, bottomRowY, btnW, 44) color:CLR_SUPPORT];
    [self.mainCard addSubview:supportBtn];

    // ── Footer text ──
    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(0, cardH - 30, cardW, 20)];
    footer.text = @"v2.0.32 www.lordvcam.com";
    footer.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    footer.textColor = [UIColor lightGrayColor];
    footer.textAlignment = NSTextAlignmentCenter;
    [self.mainCard addSubview:footer];
}

- (UIButton *)makeButton:(NSString *)title frame:(CGRect)frame color:(UIColor *)color {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = color;
    btn.layer.cornerRadius = 14;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    
    // Setup press animation
    [btn addTarget:self action:@selector(btnDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [btn addTarget:self action:@selector(btnUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchCancel | UIControlEventTouchDragExit | UIControlEventTouchUpOutside];
    
    return btn;
}

- (void)btnDown:(UIButton *)b {
    [UIView animateWithDuration:0.1 animations:^{ b.transform = CGAffineTransformMakeScale(0.95, 0.95); b.alpha = 0.8; }];
}

- (void)btnUp:(UIButton *)b {
    [UIView animateWithDuration:0.2 animations:^{ b.transform = CGAffineTransformIdentity; b.alpha = 1.0; }];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)selectVideo {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter videosFilter];
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [self.overlayWindow.rootViewController presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    PHPickerResult *result = results.firstObject;
    NSString *typeId = [result.itemProvider hasItemConformingToTypeIdentifier:@"public.movie"] ? @"public.movie" : @"public.video";

    [result.itemProvider loadFileRepresentationForTypeIdentifier:typeId completionHandler:^(NSURL *url, NSError *err) {
        if (!url) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:VCAM_DIR withIntermediateDirectories:YES attributes:nil error:nil];

        // The picker hands back a URL in a temp directory that is torn down as
        // soon as this handler returns, so the copy has to happen here and now.
        NSError *copyErr = nil;
        [fm removeItemAtPath:VCAM_VIDEO_PATH error:nil];
        if (![fm copyItemAtPath:url.path toPath:VCAM_VIDEO_PATH error:&copyErr]) {
            NSLog(@"[VCAMLight] copy failed: %@", copyErr);
            return;
        }
        // Marker so readers that are already running notice the swap.
        [fm removeItemAtPath:VCAM_CHANGED_MARK error:nil];
        [fm createFileAtPath:VCAM_CHANGED_MARK contents:nil attributes:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self enableCamera];
        });
    }];
}

- (void)enableCamera {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:VCAM_PREFS_PATH] ?: [NSMutableDictionary new];
    prefs[@"replOn"]  = @YES;
    prefs[@"loopOn"]  = @YES;
    prefs[@"galName"] = VCAM_VIDEO_PATH;
    [prefs writeToFile:VCAM_PREFS_PATH atomically:YES];
    notify_post(VCAM_DARWIN_NOTE);

    // UI feedback
    self.galleryBtn.backgroundColor = [CLR_PURPLE colorWithAlphaComponent:0.7];
    [self.galleryBtn setTitle:@"🖼 Applied!" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.galleryBtn.backgroundColor = CLR_PURPLE;
        [self.galleryBtn setTitle:@"🖼 Gallery" forState:UIControlStateNormal];
    });
}

- (void)disableCamera {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:VCAM_PREFS_PATH] ?: [NSMutableDictionary new];
    prefs[@"replOn"] = @NO;
    [prefs writeToFile:VCAM_PREFS_PATH atomically:YES];
    notify_post(VCAM_DARWIN_NOTE);

    // UI feedback
    self.disableBtn.backgroundColor = [CLR_BTN_DARK colorWithAlphaComponent:0.5];
    [self.disableBtn setTitle:@"🚫 Disabled!" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.disableBtn.backgroundColor = CLR_BTN_DARK;
        [self.disableBtn setTitle:@"🚫 Disable" forState:UIControlStateNormal];
    });
}

@end
