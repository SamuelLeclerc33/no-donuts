#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside @try/@catch. Returns YES on success; on an ObjC
/// exception returns NO and (if non-null) sets *error to an NSError carrying
/// the exception name/reason. Lets Swift survive AVFoundation setters that
/// throw NSException (e.g. AVCaptureDALDevice frame-duration).
BOOL nd_runCatchingObjCException(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
