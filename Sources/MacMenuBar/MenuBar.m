#import <AppKit/AppKit.h>

// Loaded in-process by Catalyst. HomeKit and authorization stay in the host app.
@interface HKWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, weak) id original;
@property(nonatomic, copy) void (^hide)(void);
@end
@implementation HKWindowDelegate
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self.original respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.original; }
- (BOOL)windowShouldClose:(NSWindow *)window { self.hide(); return NO; }
@end

@interface HKMenuBar : NSObject <NSMenuDelegate>
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSMenuItem *status;
@property(nonatomic, strong) NSMenuItem *disconnect;
@property(nonatomic, strong) NSMenuItem *quit;
@property(nonatomic, strong) NSMapTable *delegates;
@property(nonatomic, copy) NSDictionary *(^state)(void);
@property(nonatomic, copy) BOOL (^action)(NSString *);
@property(nonatomic) BOOL hidden;
@end
@implementation HKMenuBar
- (void)configure:(NSDictionary *(^)(void))state action:(BOOL (^)(NSString *))action {
    self.state = state;
    self.action = action;
    self.delegates = [NSMapTable weakToStrongObjectsMapTable];
    self.hidden = [state()[@"connected"] boolValue];
    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:28];
    self.item.autosaveName = @"HomeKitten";
    self.item.visible = YES;
    NSURL *iconURL = [[NSBundle bundleForClass:self.class] URLForResource:@"HomeKittenMenuBar" withExtension:@"png"];
    NSImage *icon = [[NSImage alloc] initWithContentsOfURL:iconURL];
    icon.size = NSMakeSize(22, 22);
    icon.template = NO;
    self.item.button.image = icon;
    if (!icon) self.item.button.title = @"HK";
    self.item.button.accessibilityLabel = @"HomeKitten";
    self.item.button.toolTip = @"HomeKitten Agent Access";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"HomeKitten"];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    self.status = [menu addItemWithTitle:@"HomeKitten" action:nil keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    for (NSString *title in @[@"Open HomeKitten", @"Hide HomeKitten", @"Disconnect Agent", @"Quit HomeKitten"]) {
        NSMenuItem *item = [menu addItemWithTitle:title action:@selector(selected:) keyEquivalent:@""];
        item.target = self;
        if ([title hasPrefix:@"Disconnect"]) self.disconnect = item;
        if ([title hasPrefix:@"Quit"]) self.quit = item;
    }
    self.item.menu = menu;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowShown:) name:NSWindowDidBecomeKeyNotification object:nil];
    if (self.hidden) [self hideWindows];
}
- (void)windowShown:(NSNotification *)note {
    [self trackWindow:note.object];
}
- (void)trackWindow:(NSWindow *)window {
    if (!(window.styleMask & NSWindowStyleMaskClosable) || [window isKindOfClass:NSPanel.class]) return;
    HKWindowDelegate *existing = [self.delegates objectForKey:window];
    if (!existing || window.delegate != existing) {
        HKWindowDelegate *proxy = [HKWindowDelegate new];
        proxy.original = window.delegate;
        __weak HKMenuBar *weakSelf = self;
        proxy.hide = ^{ [weakSelf hideWindows]; };
        [self.delegates setObject:proxy forKey:window];
        window.delegate = proxy;
    }
    if (self.hidden) [window orderOut:nil];
}
- (NSDictionary *)runtimeState {
    NSUInteger visible = 0;
    for (NSWindow *window in NSApp.windows) {
        [self trackWindow:window];
        if (window.isVisible && (window.styleMask & NSWindowStyleMaskClosable) && ![window isKindOfClass:NSPanel.class]) visible++;
    }
    if (self.hidden && NSApp.activationPolicy != NSApplicationActivationPolicyAccessory)
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    return @{@"menuBarInstalled": @(self.item != nil), @"menuBarVisible": @(self.item.button.window.isVisible),
             @"statusItemVisible": @(self.item.isVisible),
             @"statusWindowFrame": NSStringFromRect(self.item.button.window.frame),
             @"statusButtonFrame": NSStringFromRect(self.item.button.frame),
             @"statusImageAvailable": @(self.item.button.image != nil),
             @"statusWindowAlpha": @(self.item.button.window.alphaValue), @"applicationHidden": @(NSApp.hidden), @"hidden": @(self.hidden),
             @"visibleWindows": @(visible), @"dockVisible": @(NSApp.activationPolicy == NSApplicationActivationPolicyRegular)};
}
- (void)hideWindows {
    self.hidden = YES;
    // NSApp.windows also contains the status item's window. Hiding it removes
    // the only way back into this accessory app, so hide tracked app windows only.
    for (NSWindow *window in NSApp.windows) {
        if ((window.styleMask & NSWindowStyleMaskClosable) && ![window isKindOfClass:NSPanel.class]) {
            [self trackWindow:window];
            [window orderOut:nil];
        }
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}
- (void)menuWillOpen:(NSMenu *)menu {
    NSDictionary *state = self.state();
    self.status.title = state[@"status"];
    self.disconnect.enabled = [state[@"running"] boolValue] && ![state[@"busy"] boolValue];
    self.quit.enabled = ![state[@"busy"] boolValue];
}
- (void)selected:(NSMenuItem *)sender {
    if ([sender.title hasPrefix:@"Open"]) {
        self.hidden = NO;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        for (NSWindow *window in self.delegates.keyEnumerator) [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    } else if ([sender.title hasPrefix:@"Hide"]) {
        [self hideWindows];
    } else if ([sender.title hasPrefix:@"Disconnect"]) {
        self.action(@"disconnect");
    } else if (self.action(@"quit")) {
        [NSApp terminate:nil];
    }
}
@end
