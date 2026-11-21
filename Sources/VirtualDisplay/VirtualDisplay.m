#import "VirtualDisplay.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

// Runtime contracts, not SDK declarations. API shape independently checked against
// Chromium's macOS virtual-display test utility (blob 37e96927d1a2f68d2ee57797710520a790193c82).
// https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
@protocol RXTDisplayAPI
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
@end
@protocol RXTModeAPI
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@implementation RXTDisplay {
    id<RXTDisplayAPI> _display;
}
static BOOL fail(NSError **error, NSString *message) {
    if (error)
        *error = [NSError errorWithDomain:@"dev.rexmote.virtual-display"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey : message}];
    return NO;
}
static BOOL validSize(uint32_t width, uint32_t height, BOOL retina) {
    if (retina && (width > 2048 || height > 2048 || width * height > 3840 * 2160 / 4)) return NO;
    return width >= 800 && height >= 600 && width <= 4096 && height <= 4096 && width * height <= 3840 * 2160;
}
+ (instancetype)createWithWidth:(uint32_t)width height:(uint32_t)height retina:(BOOL)retina error:(NSError **)error {
    if (!validSize(width, height, retina)) {
        fail(error, @"Unsupported virtual desktop dimensions.");
        return nil;
    }
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || ![displayClass instancesRespondToSelector:@selector(initWithDescriptor:)] ||
        ![displayClass instancesRespondToSelector:@selector(applySettings:)]) {
        fail(error, @"This macOS version does not expose the virtual-display API.");
        return nil;
    }
    @try {
        NSObject *descriptor = [[descriptorClass alloc] init];
        [descriptor setValue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0) forKey:@"queue"];
        [descriptor setValue:@"rexmote" forKey:@"name"];
        [descriptor setValue:@4096 forKey:@"maxPixelsWide"];
        [descriptor setValue:@4096 forKey:@"maxPixelsHigh"];
        [descriptor setValue:[NSValue valueWithSize:NSMakeSize(600, 340)] forKey:@"sizeInMillimeters"];
        [descriptor setValue:@0x5258 forKey:@"vendorID"];
        [descriptor setValue:@1 forKey:@"productID"];
        NSNumber *serial = @(arc4random_uniform(UINT32_MAX - 1) + 1);
        [descriptor setValue:serial forKey:@"serialNum"];
        [descriptor setValue:serial forKey:@"serialNumber"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.64, 0.33)] forKey:@"redPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.30, 0.60)] forKey:@"greenPrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.15, 0.06)] forKey:@"bluePrimary"];
        [descriptor setValue:[NSValue valueWithPoint:NSMakePoint(0.3127, 0.3290)] forKey:@"whitePoint"];
        RXTDisplay *owner = [[self alloc] init];
        owner->_display = [(id<RXTDisplayAPI>)[displayClass alloc] initWithDescriptor:descriptor];
        if (!owner->_display) {
            fail(error, @"macOS declined to create a virtual display in this session.");
            return nil;
        }
        if (![owner resizeToWidth:width height:height retina:retina error:error]) {
            [owner close];
            return nil;
        }
        return owner;
    } @catch (NSException *exception) {
        fail(error, [NSString stringWithFormat:@"Virtual-display API failed: %@", exception.reason]);
        return nil;
    }
}
- (uint32_t)displayID {
    return [_display displayID];
}
- (BOOL)resizeToWidth:(uint32_t)width height:(uint32_t)height retina:(BOOL)retina error:(NSError **)error {
    if (!_display || !validSize(width, height, retina))
        return fail(error, @"Unsupported virtual desktop dimensions.");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings"),
          modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!settingsClass || ![modeClass instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)])
        return fail(error, @"Virtual-display modes are unavailable.");
    @try {
        NSObject *settings = [[settingsClass alloc] init];
        id mode = [(id<RXTModeAPI>)[modeClass alloc] initWithWidth:width height:height refreshRate:60.0];
        if (!mode)
            return fail(error, @"macOS declined the virtual-display mode.");
        [settings setValue:@[ mode ] forKey:@"modes"];
        [settings setValue:@(retina) forKey:@"hiDPI"];
        [settings setValue:@0 forKey:@"rotation"];
        return [_display applySettings:settings] || fail(error, @"macOS declined the virtual-display settings.");
    } @catch (NSException *exception) {
        return fail(error, exception.reason ?: @"Virtual-display resize failed.");
    }
}
- (void)close {
    _display = nil;
}
@end
