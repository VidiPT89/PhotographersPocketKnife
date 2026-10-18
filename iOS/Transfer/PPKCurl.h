#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface PPKCurl : NSObject
@property(atomic) BOOL cancelled;
- (BOOL)performURL:(NSString *)url file:(nullable NSString *)file username:(NSString *)username password:(NSString *)password tls:(BOOL)tls signature:(nullable NSString *)signature method:(nullable NSString *)method caBundle:(NSString *)caBundle progress:(void (^)(double))progress error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
