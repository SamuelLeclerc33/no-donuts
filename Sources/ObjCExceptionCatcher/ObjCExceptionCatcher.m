#import "ObjCExceptionCatcher.h"

BOOL nd_runCatchingObjCException(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            *error = [NSError errorWithDomain:@"NoDonuts.ObjCException"
                                         code:0
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""]}];
        }
        return NO;
    }
}
