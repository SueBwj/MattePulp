#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#import "NativeBridge.h"

// The session login list is the main-app mechanism before SMAppService.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSArray *matchingItems(LSSharedFileListRef list, NSURL *bundle) {
    NSArray *snapshot = CFBridgingRelease(LSSharedFileListCopySnapshot(list, NULL));
    if (!snapshot) return nil;

    NSString *path = bundle.URLByResolvingSymlinksInPath.path;
    NSMutableArray *matches = [NSMutableArray array];
    for (id entry in snapshot) {
        NSURL *url = CFBridgingRelease(LSSharedFileListItemCopyResolvedURL(
            (__bridge LSSharedFileListItemRef)entry,
            kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes, NULL));
        if ([path isEqualToString:url.URLByResolvingSymlinksInPath.path]) {
            [matches addObject:entry];
        }
    }
    return matches;
}

int32_t matte_login_item_status(CFURLRef bundle) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) return -1;

    NSArray *matches = matchingItems(list, (__bridge NSURL *)bundle);
    CFRelease(list);
    return matches ? (matches.count > 0 ? 1 : 0) : -1;
}

bool matte_login_item_set_enabled(CFURLRef bundle, bool enabled) {
    LSSharedFileListRef list = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) return false;

    NSArray *matches = matchingItems(list, (__bridge NSURL *)bundle);
    bool success = matches != nil;
    if (matches && enabled && matches.count == 0) {
        LSSharedFileListItemRef item =
            LSSharedFileListInsertItemURL(list, kLSSharedFileListItemLast, NULL, NULL, bundle, NULL, NULL);
        success = item != NULL;
        if (item) CFRelease(item);
    } else if (!enabled) {
        for (id entry in matches) {
            if (LSSharedFileListItemRemove(list, (__bridge LSSharedFileListItemRef)entry) != noErr) {
                success = false;
            }
        }
    }
    CFRelease(list);
    return success;
}

#pragma clang diagnostic pop
