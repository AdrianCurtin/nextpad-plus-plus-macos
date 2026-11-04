// Finder Sync extension: adds "Edit with Nextpad++" to Finder's context menu for
// selected files, like Windows Notepad++'s "Edit with Notepad++" shell entry.
// Folders are left to the "Open with Nextpad++" Service (Info.plist NSServices).
//
// The extension is sandboxed and opens nothing itself: LaunchServices refuses to
// hand a file to another app on behalf of a sandboxed caller (permErr, -54), and
// drops launch arguments from one. It sends the selected paths to the app that
// contains it, which is not sandboxed and opens them (AppDelegate.mm):
// - App running: post kEditNotification, then ask LaunchServices to activate it.
// - App not running: launch it, wait for its kReadyNotification, then post
//   kEditNotification. The app queues files that arrive while it is launching
//   and opens them after its session is restored.
// Sandboxed processes may not attach userInfo to distributed notifications, so
// the request is a JSON string in the notification's object:
//   {"app": "<path of the target Nextpad++.app>", "files": ["<absolute path>", ...]}
// "app" lets the right copy answer when several copies of Nextpad++ (same bundle
// id) are running.

#import <Cocoa/Cocoa.h>
#import <FinderSync/FinderSync.h>

// Must match kNppFinderSyncEditNotification / kNppFinderSyncReadyNotification in
// src/AppDelegate.mm. The extension does not link app code, so they are repeated.
static NSString *const kEditNotification  = @"org.nextpadplusplus.mac.FinderSync.edit";
static NSString *const kReadyNotification = @"org.nextpadplusplus.mac.FinderSync.ready";

/// Files waiting for a launching app are dropped if it has not announced itself
/// within this time (a failed or very slow launch).
static const NSTimeInterval kLaunchWaitTimeout = 60;

/// Symlinks resolved (so /tmp and /private/tmp compare equal), for comparing app paths.
static NSString *NppCanonicalPath(NSString *path) {
    if (path.length == 0) return @"";
    return [NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.path ?: path;
}

@interface NppFinderSync : FIFinderSync
@end

@implementation NppFinderSync {
    // Files selected while the app was not running, sent once it is ready.
    // Main thread only.
    NSMutableArray<NSString *> *_waitingFiles;
    NSString *_waitingAppPath;
    NSDate *_waitingSince;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _waitingFiles = [NSMutableArray array];
        [self _watchVolumes];
        NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
        [nc addObserver:self selector:@selector(_watchVolumes)
                   name:NSWorkspaceDidMountNotification object:nil];
        [nc addObserver:self selector:@selector(_watchVolumes)
                   name:NSWorkspaceDidUnmountNotification object:nil];
        [NSDistributedNotificationCenter.defaultCenter
            addObserver:self selector:@selector(_appIsReady:)
                   name:kReadyNotification object:nil
            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    }
    return self;
}

- (void)dealloc {
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

/// Finder only asks the extension for menus inside its directory URLs, so cover
/// the startup volume and every mounted volume.
- (void)_watchVolumes {
    NSMutableSet<NSURL *> *urls = [NSMutableSet setWithObject:[NSURL fileURLWithPath:@"/" isDirectory:YES]];
    NSArray<NSURL *> *volumes = [NSFileManager.defaultManager
        mountedVolumeURLsIncludingResourceValuesForKeys:nil
                                                options:NSVolumeEnumerationSkipHiddenVolumes];
    if (volumes) [urls addObjectsFromArray:volumes];
    FIFinderSyncController.defaultController.directoryURLs = urls;
}

/// The selected files. Finder gives folders (and packages such as .app) as
/// directory URLs, so no file system access is needed to leave them out.
- (NSArray<NSURL *> *)_selectedFiles {
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSURL *url in FIFinderSyncController.defaultController.selectedItemURLs) {
        if (url.isFileURL && !url.hasDirectoryPath) [files addObject:url];
    }
    return files;
}

- (NSMenu *)menuForMenuKind:(FIMenuKind)menuKind {
    if (menuKind != FIMenuKindContextualMenuForItems) return nil;
    if (self._selectedFiles.count == 0) return nil;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    // English only: the app's localizer (NppLocalizer) is not available in the
    // sandboxed extension.
    NSMenuItem *item = [menu addItemWithTitle:@"Edit with Nextpad++"
                                       action:@selector(editWithNextpad:)
                                keyEquivalent:@""];
    NSImage *icon = [[NSBundle bundleForClass:self.class] imageForResource:@"npp"];
    icon.size = NSMakeSize(16, 16);
    item.image = icon;
    return menu;
}

/// Nextpad++.app/Contents/PlugIns/<this>.appex, so three levels up. Falls back
/// to the registered app if the extension was moved out of its bundle.
- (NSURL *)_appURL {
    NSURL *app = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent
                     .URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    if ([app.pathExtension isEqualToString:@"app"]) return app;
    return [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"org.nextpadplusplus.mac"];
}

/// Whether this copy of Nextpad++ (matched by bundle path, not bundle id, since
/// the installed app and dev builds share the id) is running.
- (BOOL)_isAppRunning:(NSString *)appPath {
    for (NSRunningApplication *running in NSWorkspace.sharedWorkspace.runningApplications) {
        if (running.terminated || !running.bundleURL) continue;
        if ([NppCanonicalPath(running.bundleURL.path) isEqualToString:appPath]) return YES;
    }
    return NO;
}

- (void)_postFiles:(NSArray<NSString *> *)files toApp:(NSString *)appPath {
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"app": appPath, @"files": files}
                                                   options:0 error:nil];
    NSString *request = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    if (!request) return;
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:kEditNotification
                                                                 object:request
                                                               userInfo:nil
                                                     deliverImmediately:YES];
}

- (IBAction)editWithNextpad:(id)sender {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSURL *url in self._selectedFiles) {
        if (url.path.length) [files addObject:url.path];
    }
    NSURL *app = self._appURL;
    if (files.count == 0 || !app) return;
    NSString *appPath = NppCanonicalPath(app.path);

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self _isAppRunning:appPath]) {
            [self _postFiles:files toApp:appPath];
        } else {
            // Keep earlier files still waiting for the same launch.
            BOOL stale = !_waitingSince || -_waitingSince.timeIntervalSinceNow > kLaunchWaitTimeout;
            if (stale || ![_waitingAppPath isEqualToString:appPath]) [_waitingFiles removeAllObjects];
            [_waitingFiles addObjectsFromArray:files];
            _waitingAppPath = appPath;
            _waitingSince = [NSDate date];
        }
        // Launches the app, or brings a running one forward; the app's own
        // activation from a notification handler is often refused on recent macOS.
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = YES;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:app
                                            configuration:config
                                        completionHandler:^(NSRunningApplication *running, NSError *error) {
            if (error) NSLog(@"[NppFinderSync] Could not open %@: %@", app.path, error);
        }];
    });
}

/// The app posts kReadyNotification (object: its bundle path) once it can take
/// requests; send it any files that were waiting for it to launch.
- (void)_appIsReady:(NSNotification *)note {
    if (![note.object isKindOfClass:NSString.class]) return;
    NSString *appPath = NppCanonicalPath(note.object);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_waitingFiles.count == 0 || ![appPath isEqualToString:_waitingAppPath]) return;
        NSArray<NSString *> *files = [_waitingFiles copy];
        BOOL stale = -_waitingSince.timeIntervalSinceNow > kLaunchWaitTimeout;
        [_waitingFiles removeAllObjects];
        _waitingAppPath = nil;
        _waitingSince = nil;
        if (!stale) [self _postFiles:files toApp:appPath];
    });
}

@end
