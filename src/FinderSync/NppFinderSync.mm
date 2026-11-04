// Finder Sync extension: adds "Edit with Nextpad++" to Finder's context menu for
// selected files, like Windows Notepad++'s "Edit with Notepad++" shell entry.
// Folders are left to the "Open with Nextpad++" Service (Info.plist NSServices).
// The extension is sandboxed; it only reads Finder's selection and asks
// LaunchServices to open the files in the app that contains it.

#import <Cocoa/Cocoa.h>
#import <FinderSync/FinderSync.h>

@interface NppFinderSync : FIFinderSync
@end

@implementation NppFinderSync

- (instancetype)init {
    self = [super init];
    if (self) {
        [self _watchVolumes];
        NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
        [nc addObserver:self selector:@selector(_watchVolumes)
                   name:NSWorkspaceDidMountNotification object:nil];
        [nc addObserver:self selector:@selector(_watchVolumes)
                   name:NSWorkspaceDidUnmountNotification object:nil];
    }
    return self;
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

- (IBAction)editWithNextpad:(id)sender {
    NSArray<NSURL *> *files = self._selectedFiles;
    NSURL *app = self._appURL;
    if (files.count == 0 || !app) return;
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = YES;
    [NSWorkspace.sharedWorkspace openURLs:files
                     withApplicationAtURL:app
                            configuration:config
                        completionHandler:^(NSRunningApplication *running, NSError *error) {
        if (error) NSLog(@"[NppFinderSync] Could not open %lu file(s) in %@: %@",
                         (unsigned long)files.count, app.path, error);
    }];
}

@end
