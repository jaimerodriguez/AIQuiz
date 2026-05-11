#import "ExceptionCatcher.h"

@implementation ExceptionCatcher

+ (BOOL)tryBlock:(__attribute__((noescape)) void (^)(void))block
           error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    }
    @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name ?: @"Objective-C exception";
            info[@"NSExceptionName"] = exception.name ?: @"";
            if (exception.userInfo) info[@"NSExceptionUserInfo"] = exception.userInfo;
            *error = [NSError errorWithDomain:@"NSExceptionDomain" code:0 userInfo:info];
        }
        return NO;
    }
}

@end
