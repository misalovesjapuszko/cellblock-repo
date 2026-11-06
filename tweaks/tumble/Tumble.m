// Tumble: shake your phone and the home screen icons get gravity. They fall the way the phone
// is tilted, bounce off each other and the screen edges, and can still be tapped. Shake again
// and they glide back into place. ("Always On" skips the shaking.)
//
// Icons stay where SpringBoardHome lays them out: each one gets a stand-in physics body
// (TumbleBody) and only the icon's transform follows it, so layout, tapping, folders and
// jiggle mode keep working. Gravity comes from CoreMotion's gravity vector.
#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kDomain = @"dev.cellblock.tumble";
static NSString *const kChanged = @"dev.cellblock.tumble/changed";

static BOOL gEnabled = YES, gSpin = YES, gAlways = NO;
/// shaken loose: the icons are falling until the next shake
static BOOL gDropped = NO;
static CGFloat gBounce = 0.45, gStrength = 1.0;

static NSString *TumbleRootfs(void) {
    Dl_info info;
    if (dladdr((const void *)&TumbleRootfs, &info) == 0 || info.dli_fname == NULL) return @"/";
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    NSRange r = [path rangeOfString:@"/Library/MobileSubstrate/DynamicLibraries/"];
    if (r.location == NSNotFound) r = [path rangeOfString:@"/usr/lib/TweakInject/"];
    return r.location == NSNotFound ? @"/" : [path substringToIndex:r.location];
}

static void TumbleLoadPrefs(void) {
    NSString *file = [TumbleRootfs() stringByAppendingPathComponent:@"var/mobile/Library/Preferences/dev.cellblock.tumble.plist"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:file];
    if (prefs == nil) {
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        prefs = CFBridgingRelease(CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)kDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    }
    gEnabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
    gSpin = prefs[@"spin"] ? [prefs[@"spin"] boolValue] : YES;
    gAlways = prefs[@"always"] ? [prefs[@"always"] boolValue] : NO;
    gBounce = prefs[@"bounce"] ? MAX(0, MIN(1, [prefs[@"bounce"] doubleValue])) : 0.45;
    gStrength = prefs[@"strength"] ? MAX(0.2, MIN(3, [prefs[@"strength"] doubleValue])) : 1.0;
}

/// the physics stand-in for one icon: UIDynamics moves this, the icon follows
@interface TumbleBody : NSObject <UIDynamicItem>
@property (nonatomic) CGPoint center;
@property (nonatomic) CGAffineTransform transform;
@property (nonatomic, readonly) CGRect bounds;
@property (nonatomic, weak) UIView *icon;
@property (nonatomic) CGPoint home;   // where the layout put the icon
@end

@implementation TumbleBody
- (instancetype)initWithIcon:(UIView *)icon {
    if ((self = [super init])) {
        _icon = icon;
        _home = icon.center;
        _center = icon.center;
        _transform = CGAffineTransformIdentity;
        // a little smaller than the icon view: the label area doesn't collide
        CGFloat side = MIN(icon.bounds.size.width, icon.bounds.size.height) * 0.82;
        _bounds = CGRectMake(0, 0, side, side);
    }
    return self;
}
- (UIDynamicItemCollisionBoundsType)collisionBoundsType { return UIDynamicItemCollisionBoundsTypeEllipse; }
- (void)apply {
    UIView *icon = self.icon;
    if (icon == nil) return;
    // the layout may have moved the icon (rotation, edit mode): follow it
    CGPoint offset = CGPointMake(self.center.x - self.home.x, self.center.y - self.home.y);
    CGAffineTransform t = CGAffineTransformMakeTranslation(offset.x, offset.y);
    if (gSpin) t = CGAffineTransformConcat(self.transform, t);
    icon.transform = t;
}
@end

/// one page of icons (an SBIconListView) with its own animator
@interface TumblePage : NSObject <UICollisionBehaviorDelegate>
@property (nonatomic, weak) UIView *listView;
@property (nonatomic, strong) UIDynamicAnimator *animator;
@property (nonatomic, strong) UIGravityBehavior *gravity;
@property (nonatomic, strong) NSArray<TumbleBody *> *bodies;
@end

static NSMapTable<UIView *, TumblePage *> *gPages;
static CMMotionManager *gMotion;
static CGVector gGravity = {0, 1};
static NSTimer *gScanTimer;

static BOOL TumbleIsIcon(UIView *view) {
    Class icon = objc_getClass("SBIconView");
    return icon && [view isKindOfClass:icon] && !view.hidden && view.alpha > 0.01;
}

@implementation TumblePage
- (instancetype)initWithListView:(UIView *)listView {
    if ((self = [super init])) {
        _listView = listView;
        NSMutableArray *bodies = [NSMutableArray array];
        for (UIView *sub in listView.subviews) {
            if (TumbleIsIcon(sub)) [bodies addObject:[[TumbleBody alloc] initWithIcon:sub]];
        }
        _bodies = bodies;
        _animator = [[UIDynamicAnimator alloc] initWithReferenceView:listView];
        _gravity = [[UIGravityBehavior alloc] initWithItems:bodies];
        _gravity.gravityDirection = CGVectorMake(gGravity.dx * gStrength, gGravity.dy * gStrength);
        UICollisionBehavior *walls = [[UICollisionBehavior alloc] initWithItems:bodies];
        // the whole screen is the box, not just the icon grid
        UIWindow *window = listView.window;
        CGRect box = window ? [window convertRect:window.bounds toView:listView] : listView.bounds;
        UIEdgeInsets safe = window.safeAreaInsets;
        box = UIEdgeInsetsInsetRect(box, UIEdgeInsetsMake(safe.top, 4, MAX(safe.bottom, 8), 4));
        [walls addBoundaryWithIdentifier:@"box" forPath:[UIBezierPath bezierPathWithRect:box]];
        UIDynamicItemBehavior *material = [[UIDynamicItemBehavior alloc] initWithItems:bodies];
        material.elasticity = gBounce;
        material.friction = 0.25;
        material.resistance = 0.15;
        material.angularResistance = 0.6;
        material.allowsRotation = gSpin;
        __weak TumblePage *weakSelf = self;
        material.action = ^{
            for (TumbleBody *body in weakSelf.bodies) [body apply];
        };
        [_animator addBehavior:_gravity];
        [_animator addBehavior:walls];
        [_animator addBehavior:material];
    }
    return self;
}
- (void)updateGravity {
    self.gravity.gravityDirection = CGVectorMake(gGravity.dx * gStrength, gGravity.dy * gStrength);
}
- (void)stopAnimated:(BOOL)animated {
    [self.animator removeAllBehaviors];
    NSArray *icons = [self.bodies valueForKey:@"icon"];
    void (^reset)(void) = ^{
        for (id icon in icons) if (icon != NSNull.null) ((UIView *)icon).transform = CGAffineTransformIdentity;
    };
    if (animated) {
        [UIView animateWithDuration:0.6 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction animations:reset completion:nil];
    } else {
        reset();
    }
}
@end

static void TumbleStopAll(BOOL animated) {
    for (TumblePage *page in gPages.objectEnumerator.allObjects) [page stopAnimated:animated];
    [gPages removeAllObjects];
}

/// in edit mode icons jiggle and get dragged: physics would fight it
static BOOL TumbleIsEditing(UIView *listView) {
    for (UIView *sub in listView.subviews) {
        if (TumbleIsIcon(sub) && [sub respondsToSelector:@selector(isEditing)] && [(id)sub isEditing]) return YES;
    }
    return NO;
}

static void TumbleCollectListViews(UIView *view, NSMutableArray *found) {
    Class list = objc_getClass("SBIconListView");
    if (list && [view isKindOfClass:list]) { [found addObject:view]; return; }
    for (UIView *sub in view.subviews) TumbleCollectListViews(sub, found);
}

/// every window of the app (UIApplication.windows is deprecated: go through the scenes)
static NSArray<UIWindow *> *AllWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    return windows;
}

/// pages on screen get physics, pages that left the screen (or edit mode) get their icons back
static void TumbleScan(void) {
    if (!gEnabled || !(gDropped || gAlways)) { TumbleStopAll(YES); return; }
    NSMutableArray *lists = [NSMutableArray array];
    for (UIWindow *window in AllWindows()) {
        if (!window.hidden) TumbleCollectListViews(window, lists);
    }
    NSMutableSet *visible = [NSMutableSet set];
    for (UIView *list in lists) {
        UIWindow *window = list.window;
        if (window == nil || list.hidden || list.alpha < 0.01) continue;
        CGRect onScreen = [list convertRect:list.bounds toView:window];
        if (!CGRectIntersectsRect(CGRectInset(window.bounds, 40, 40), onScreen)) continue;
        if (TumbleIsEditing(list)) continue;
        [visible addObject:list];
    }
    for (UIView *list in gPages.keyEnumerator.allObjects) {
        TumblePage *page = [gPages objectForKey:list];
        BOOL iconsChanged = NO;
        for (TumbleBody *body in page.bodies) if (body.icon.superview != list) { iconsChanged = YES; break; }
        if (![visible containsObject:list] || iconsChanged) {
            [page stopAnimated:!iconsChanged];
            [gPages removeObjectForKey:list];
        }
    }
    for (UIView *list in visible) {
        if ([gPages objectForKey:list] == nil) {
            TumblePage *page = [[TumblePage alloc] initWithListView:list];
            if (page.bodies.count > 0) [gPages setObject:page forKey:list];
        }
    }
}

/// a shake: a few hard jolts (> 1.8 g without gravity) within half a second; then a second of
/// rest so one shake doesn't count twice
static void TumbleCheckShake(CMDeviceMotion *motion) {
    static NSTimeInterval firstJolt = 0, quietUntil = 0;
    static int jolts = 0;
    if (gAlways) return;
    NSTimeInterval now = motion.timestamp;
    CMAcceleration a = motion.userAcceleration;
    double g = sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    if (now < quietUntil || g < 1.8) return;
    if (now - firstJolt > 0.5) { firstJolt = now; jolts = 0; }
    if (++jolts < 3) return;
    jolts = 0;
    quietUntil = now + 1.0;
    gDropped = !gDropped;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:gDropped ? UIImpactFeedbackStyleHeavy : UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
    TumbleScan();
}

static void TumbleStart(void) {
    if (gScanTimer == nil) {
        gScanTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { TumbleScan(); }];
    }
    if (gMotion == nil) gMotion = [[CMMotionManager alloc] init];
    if (gMotion.isDeviceMotionAvailable && !gMotion.isDeviceMotionActive) {
        gMotion.deviceMotionUpdateInterval = 1.0 / 40.0;
        [gMotion startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *motion, NSError *error) {
            if (motion == nil) return;
            // CoreMotion's y points up the screen, UIKit's down
            gGravity = CGVectorMake(motion.gravity.x, -motion.gravity.y);
            for (TumblePage *page in gPages.objectEnumerator.allObjects) [page updateGravity];
            TumbleCheckShake(motion);
        }];
    }
    TumbleScan();
}

static void TumbleStop(void) {
    [gScanTimer invalidate];
    gScanTimer = nil;
    [gMotion stopDeviceMotionUpdates];
    TumbleStopAll(YES);
}

static void TumblePrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        TumbleLoadPrefs();
        // new bounce / spin: rebuild the pages
        TumbleStopAll(NO);
        if (!gEnabled) gDropped = NO;
        if (gEnabled) TumbleStart(); else TumbleStop();
    });
}

__attribute__((constructor)) static void TumbleInit(void) {
    @autoreleasepool {
        TumbleLoadPrefs();
        gPages = [NSMapTable weakToStrongObjectsMapTable];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TumblePrefsChanged,
                                        (__bridge CFStringRef)kChanged, NULL, CFNotificationSuspensionBehaviorCoalesce);
        // the home screen is built after the tweak loads: start once the app is up
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            if (gEnabled) TumbleStart();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (gEnabled) TumbleStart();
        });
        NSLog(@"[Tumble] loaded (enabled %d, SBIconListView %p)", gEnabled, objc_getClass("SBIconListView"));
    }
}
