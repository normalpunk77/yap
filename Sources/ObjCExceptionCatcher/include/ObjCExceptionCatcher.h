#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and converts any raised Objective-C `NSException` into an
/// `NSError` (domain `ObjCException`). Swift's `do/catch` cannot intercept an
/// `NSException` — it aborts the process — so any AppKit/AVFoundation call that
/// raises one (e.g. `-[AVAudioNode installTapOnBus:...]`) must be funnelled
/// through here to become a recoverable `throws` error.
///
/// Returns `YES` if `block` completed normally, `NO` if it raised; on `NO`,
/// `*error` (when non-NULL) describes the exception.
BOOL ocec_perform(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
