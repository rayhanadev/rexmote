#import <Foundation/Foundation.h>
#import <stdint.h>
NS_ASSUME_NONNULL_BEGIN
/// Isolates the unsupported CoreGraphics display-creation API behind runtime checks.
@interface RXTDisplay : NSObject
@property (nonatomic, readonly) uint32_t displayID;
+ (nullable instancetype)createWithWidth:(uint32_t)width height:(uint32_t)height retina:(BOOL)retina error:(NSError **)error;
- (BOOL)resizeToWidth:(uint32_t)width height:(uint32_t)height retina:(BOOL)retina error:(NSError **)error;
- (void)close;
@end
NS_ASSUME_NONNULL_END
