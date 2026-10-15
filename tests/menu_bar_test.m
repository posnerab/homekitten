#import "../Sources/MacMenuBar/MenuBar.m"

@interface OriginalDelegate : NSObject <NSWindowDelegate>
@end
@implementation OriginalDelegate
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)size { return NSMakeSize(600, 400); }
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 400)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        OriginalDelegate *original = [OriginalDelegate new];
        window.delegate = original;
        __block BOOL busy = NO;
        __block NSUInteger actions = 0;
        HKMenuBar *menu = [HKMenuBar new];
        [menu configure:^NSDictionary *{ return @{@"connected": @YES, @"running": @YES,
            @"busy": @(busy), @"status": @"Connected"}; }
            action:^BOOL(NSString *action) { actions++; return !busy; }];
        [menu runtimeState];
        NSCAssert(window.delegate != original, @"Window close must be intercepted");
        NSSize size = [window.delegate windowWillResize:window toSize:NSMakeSize(1, 1)];
        NSCAssert(size.width == 600, @"Unrelated delegate methods must be forwarded");
        NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Open HomeKitten" action:nil keyEquivalent:@""];
        [menu selected:open];
        NSCAssert(window.isVisible && !menu.hidden, @"Open must restore the retained window");
        [window performClose:nil];
        NSCAssert(!window.isVisible && menu.hidden, @"Close must hide, preserving the window");
        [menu selected:open];
        NSCAssert(window.isVisible, @"Reopen after close must work");
        busy = YES;
        [menu menuWillOpen:menu.item.menu];
        NSCAssert(!menu.quit.enabled && !menu.disconnect.enabled, @"Busy requests must block menu disconnect/quit");
        busy = NO;
        [menu menuWillOpen:menu.item.menu];
        NSCAssert(menu.quit.enabled && menu.disconnect.enabled, @"Idle connection must allow controls");
        [menu selected:menu.disconnect];
        NSCAssert(actions == 1, @"Disconnect must use the host authorization callback");
        [menu hideWindows];
        NSLog(@"Menu bar lifecycle tests passed");
    }
    return 0;
}
