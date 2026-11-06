// Tidy: a cleaner home screen. Hides icon labels, the page dots and the dock's background.
// Hooks Apple's SpringBoardHome classes (SBIconView, SBIconListPageControl, SBDockView) with
// plain Objective-C runtime swizzling, so it needs no hooking library beyond the injector.
// Settings: /var/mobile/Library/Preferences/dev.cellblock.tidy.plist in the rootfs (TweakSettings
// writes it), found next to this dylib, so it works rootless, roothide and in Cellblock alike.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kDomain = @"dev.cellblock.tidy";
static NSString *const kChanged = @"dev.cellblock.tidy/changed";

static BOOL gEnabled = YES, gHideLabels = YES, gHideDots = YES, gHideDock = YES;

/// the rootfs this dylib lives in: <rootfs>/Library/MobileSubstrate/DynamicLibraries/Tidy.dylib
static NSString *TidyRootfs(void) {
    Dl_info info;
    if (dladdr((const void *)&TidyRootfs, &info) == 0 || info.dli_fname == NULL) return @"/";
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    NSRange r = [path rangeOfString:@"/Library/MobileSubstrate/DynamicLibraries/"];
    if (r.location == NSNotFound) r = [path rangeOfString:@"/usr/lib/TweakInject/"];
    return r.location == NSNotFound ? @"/" : [path substringToIndex:r.location];
}

static void TidyLoadPrefs(void) {
    NSString *file = [TidyRootfs() stringByAppendingPathComponent:@"var/mobile/Library/Preferences/dev.cellblock.tidy.plist"];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:file];
    if (prefs == nil) {
        // the app writing them may keep them in its own CFPreferences
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        prefs = CFBridgingRelease(CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)kDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    }
    id (^get)(NSString *) = ^id(NSString *key) { return prefs[key]; };
    gEnabled = get(@"enabled") ? [get(@"enabled") boolValue] : YES;
    gHideLabels = gEnabled && (get(@"hideLabels") ? [get(@"hideLabels") boolValue] : YES);
    gHideDots = gEnabled && (get(@"hideDots") ? [get(@"hideDots") boolValue] : YES);
    gHideDock = gEnabled && (get(@"hideDock") ? [get(@"hideDock") boolValue] : YES);
}

/// replaces -[cls sel] with block (which gets self first); returns the original IMP
static IMP TidySwap(Class cls, SEL sel, id block) {
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (m == NULL) return NULL;
    IMP replacement = imp_implementationWithBlock(block);
    // only this class: a method inherited from a superclass gets its own copy first
    if (class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) return method_getImplementation(m);
    return method_setImplementation(m, replacement);
}

static void (*orig_setLabelHidden)(id, SEL, BOOL);
static void (*orig_iconDidMoveToWindow)(id, SEL);
static void (*orig_dotsSetHidden)(id, SEL, BOOL);
static void (*orig_dotsDidMoveToWindow)(id, SEL);
static void (*orig_setBackgroundAlpha)(id, SEL, CGFloat);
static void (*orig_dockLayoutSubviews)(id, SEL);

static void TidyApplyIcon(id iconView) {
    if (orig_setLabelHidden) orig_setLabelHidden(iconView, @selector(setLabelHidden:), gHideLabels);
}

static void TidyApplyDots(UIView *dots) {
    if (orig_dotsSetHidden) orig_dotsSetHidden(dots, @selector(setHidden:), gHideDots);
}

static void TidyApplyDock(id dock) {
    if (orig_setBackgroundAlpha) orig_setBackgroundAlpha(dock, @selector(setBackgroundAlpha:), gHideDock ? 0.0 : 1.0);
}

/// after a settings change: every icon, dot row and dock on screen again
static void TidyRefreshView(UIView *view) {
    Class icon = objc_getClass("SBIconView"), dots = objc_getClass("SBIconListPageControl"), dock = objc_getClass("SBDockView");
    if (icon && [view isKindOfClass:icon]) TidyApplyIcon(view);
    if (dots && [view isKindOfClass:dots]) TidyApplyDots(view);
    if (dock && [view isKindOfClass:dock]) TidyApplyDock(view);
    for (UIView *sub in view.subviews) TidyRefreshView(sub);
}

/// every window of the app (UIApplication.windows is deprecated: go through the scenes)
static NSArray<UIWindow *> *AllWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    return windows;
}

static void TidyPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    TidyLoadPrefs();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in AllWindows()) TidyRefreshView(window);
    });
}

__attribute__((constructor)) static void TidyInit(void) {
    @autoreleasepool {
        TidyLoadPrefs();

        Class icon = objc_getClass("SBIconView");
        orig_setLabelHidden = (void *)TidySwap(icon, @selector(setLabelHidden:), ^(id self, BOOL hidden) {
            orig_setLabelHidden(self, @selector(setLabelHidden:), gHideLabels ? YES : hidden);
        });
        orig_iconDidMoveToWindow = (void *)TidySwap(icon, @selector(didMoveToWindow), ^(id self) {
            orig_iconDidMoveToWindow(self, @selector(didMoveToWindow));
            if (gHideLabels) TidyApplyIcon(self);
        });

        Class dots = objc_getClass("SBIconListPageControl");
        orig_dotsSetHidden = (void *)TidySwap(dots, @selector(setHidden:), ^(id self, BOOL hidden) {
            orig_dotsSetHidden(self, @selector(setHidden:), gHideDots ? YES : hidden);
        });
        orig_dotsDidMoveToWindow = (void *)TidySwap(dots, @selector(didMoveToWindow), ^(id self) {
            orig_dotsDidMoveToWindow(self, @selector(didMoveToWindow));
            if (gHideDots) TidyApplyDots(self);
        });

        Class dock = objc_getClass("SBDockView");
        orig_setBackgroundAlpha = (void *)TidySwap(dock, @selector(setBackgroundAlpha:), ^(id self, CGFloat alpha) {
            orig_setBackgroundAlpha(self, @selector(setBackgroundAlpha:), gHideDock ? 0.0 : alpha);
        });
        orig_dockLayoutSubviews = (void *)TidySwap(dock, @selector(layoutSubviews), ^(id self) {
            orig_dockLayoutSubviews(self, @selector(layoutSubviews));
            if (gHideDock) TidyApplyDock(self);
        });

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TidyPrefsChanged,
                                        (__bridge CFStringRef)kChanged, NULL, CFNotificationSuspensionBehaviorCoalesce);
        NSLog(@"[Tidy] loaded: labels %d dots %d dock %d (SBIconView %p, SBIconListPageControl %p, SBDockView %p)",
              gHideLabels, gHideDots, gHideDock, icon, dots, dock);
    }
}
