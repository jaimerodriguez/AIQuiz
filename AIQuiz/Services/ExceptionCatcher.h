#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C `NSException` into a Swift-catchable `NSError`.
///
/// AVAudioEngine and other Core Audio APIs throw `NSException` on precondition
/// failures (e.g. `installTap` with a format whose channel count is zero).
/// Swift's `do/try/catch` cannot catch these — they crash the process. Wrapping
/// the call in `ExceptionCatcher.tryBlock` converts the exception into an
/// `NSError` that Swift can handle.
@interface ExceptionCatcher : NSObject

+ (BOOL)tryBlock:(__attribute__((noescape)) void (^)(void))block
           error:(NSError * _Nullable * _Nullable)error
NS_SWIFT_NAME(try(_:));

@end

NS_ASSUME_NONNULL_END
