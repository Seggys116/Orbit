// Holds a virtual display so a real window-server session exists that is not any of the user's screens.
// Scripts/interaction-smoothness compiles and runs this, waits for the "ready" line, and ends it when the run ends.
// The display is placed past the right edge of the existing arrangement so no real screen moves while it exists.
#import <Cocoa/Cocoa.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) unsigned int vendorID, productID, serialNum;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property (nonatomic, strong) dispatch_queue_t queue;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic, copy) NSArray *modes;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) unsigned int displayID;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *name = argc > 1 ? @(argv[1]) : @"Orbit Probe Display";
        [NSApplication sharedApplication];

        CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
        descriptor.name = name;
        descriptor.vendorID = 0x4F52;
        descriptor.productID = 0x4254;
        descriptor.serialNum = 1;
        descriptor.maxPixelsWide = 1920;
        descriptor.maxPixelsHigh = 1080;
        descriptor.sizeInMillimeters = CGSizeMake(527, 296);
        descriptor.queue = dispatch_get_main_queue();

        CGDirectDisplayID existing[32];
        uint32_t existingCount = 0;
        CGGetActiveDisplayList(32, existing, &existingCount);
        CGFloat rightEdge = 0;
        for (uint32_t index = 0; index < existingCount; index++) {
            CGRect bounds = CGDisplayBounds(existing[index]);
            rightEdge = MAX(rightEdge, CGRectGetMaxX(bounds));
        }

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
        settings.hiDPI = getenv("ORBIT_VIRTUAL_DISPLAY_LODPI") ? 0 : 1;
        settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:1920 height:1080 refreshRate:60]];
        if (display == nil || ![display applySettings:settings]) {
            fprintf(stderr, "virtual display could not be created\n");
            return 2;
        }

        CGDisplayConfigRef configuration = NULL;
        if (CGBeginDisplayConfiguration(&configuration) == kCGErrorSuccess) {
            CGConfigureDisplayOrigin(configuration, display.displayID, (int32_t)rightEdge, 0);
            CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
        }

        printf("ready %u %s\n", display.displayID, name.UTF8String);
        fflush(stdout);
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
