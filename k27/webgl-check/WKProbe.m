#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>

static void note(NSString *line) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DroidVM-WebKit-Probe.log"];
    NSString *message = [line stringByAppendingString:@"\n"];
    NSData *bytes = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) {
        [bytes writeToFile:path atomically:YES];
    } else {
        [file seekToEndOfFile];
        [file writeData:bytes];
        [file closeFile];
    }
}

@interface Probe : NSObject <WKNavigationDelegate>
@property (strong) NSWindow *window;
@end

@implementation Probe
- (void)webView:(WKWebView *)view didStartProvisionalNavigation:(WKNavigation *)n { note(@"started"); }
- (void)webView:(WKWebView *)view didCommitNavigation:(WKNavigation *)n { note(@"committed"); }
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)n {
    note([@"finished " stringByAppendingString:view.URL.description ?: @""]);
    [view evaluateJavaScript:@"JSON.stringify({title:document.title,text:document.body.textContent.slice(0,160),webgl:!!document.createElement('canvas').getContext('webgl')})"
          completionHandler:^(id value, NSError *err) {
        note([NSString stringWithFormat:@"js=%@ error=%@", value, err]);
        self.window.title = view.title ?: @"DroidVM WebKit probe";
    }];
}
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)error { note(error.description); }
- (void)webView:(WKWebView *)view didFailNavigation:(WKNavigation *)n withError:(NSError *)error { note(error.description); }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)view { note(@"WebContent terminated"); }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect rect = NSMakeRect(0, 0, 980, 630);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
             backing:NSBackingStoreBuffered defer:NO];
        w.title = @"DroidVM WebKit probe";
        Probe *probe = [Probe new];
        probe.window = w;
        WKWebViewConfiguration *conf = [WKWebViewConfiguration new];
        if ([conf.preferences respondsToSelector:NSSelectorFromString(@"_setExtensibleSSOEnabled:")])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(conf.preferences, NSSelectorFromString(@"_setExtensibleSSOEnabled:"), NO);
        conf.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
        WKWebView *view = [[WKWebView alloc] initWithFrame:rect configuration:conf];
        view.navigationDelegate = probe;
        w.contentView = view;
        [w center];
        [w makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        note(@"probe started");
        if (argc > 1) {
            NSString *argument = [NSString stringWithUTF8String:argv[1]];
            if ([argument hasPrefix:@"https://"] || [argument hasPrefix:@"http://"]) {
                [view loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:argument]]];
            } else {
                NSString *html = [NSString stringWithContentsOfFile:argument encoding:NSUTF8StringEncoding error:nil];
                [view loadHTMLString:html ?: @"<h1>Could not read probe file</h1>" baseURL:nil];
            }
        } else {
            [view loadHTMLString:@"<!doctype html><title>Plain HTML works</title><body style='background:#203450;color:white'><h1>Plain HTML works</h1></body>" baseURL:nil];
        }
        [app run];
        view.navigationDelegate = nil;
    }
}
