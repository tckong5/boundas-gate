#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
static BOOL standardCheck = NO;

// Disposable test host only. Automatically select download, but never install.
static void reject(NSError *error) {
    printf("REJECTED %s %ld\n", error.domain.UTF8String, (long)error.code);
    fprintf(stderr, "%s\n", error.description.UTF8String);
    fflush(stdout);
    exit(0);
}
@interface SmokeDriver : SPUStandardUserDriver
@end
@implementation SmokeDriver
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement { reject(error); }
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { exit(2); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {}
@end
@interface SmokeDelegate : NSObject <SPUUpdaterDelegate>
@end
@implementation SmokeDelegate
- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error { reject(error); }
- (void)updater:(SPUUpdater *)updater didFinishLoadingAppcast:(SUAppcast *)appcast {
    if (standardCheck) { printf("STANDARD CHECK LOADED FEED\n"); fflush(stdout); exit(0); }
}
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        SmokeDelegate *delegate = [SmokeDelegate new];
        SmokeDriver *driver = [[SmokeDriver alloc] initWithHostBundle:NSBundle.mainBundle delegate:nil];
        SPUStandardUpdaterController *controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:delegate userDriverDelegate:nil];
        BOOL standard = argc > 1 && strcmp(argv[1], "standard") == 0;
        standardCheck = standard;
        SPUUpdater *updater = standard ? controller.updater : [[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle applicationBundle:NSBundle.mainBundle userDriver:driver delegate:delegate];
        NSError *error = nil;
        if (![updater startUpdater:&error]) { reject(error); }
        printf("INITIALIZED\n"); fflush(stdout);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(1); });
        dispatch_async(dispatch_get_main_queue(), ^{
            if (standard) { [controller checkForUpdates:nil]; }
            else { [updater checkForUpdates]; }
        });
        [app run];
    }
}
