#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "protector/metal_renderer.h"

static BOOL WriteJSON(NSDictionary* value, NSURL* destination, NSError** error) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:value
                                                   options:NSJSONWritingPrettyPrinted |
                                                           NSJSONWritingSortedKeys
                                                     error:error];
    if (!data) {
        return NO;
    }
    NSMutableData* terminated = [data mutableCopy];
    const uint8_t newline = '\n';
    [terminated appendBytes:&newline length:1];
    return [terminated writeToURL:destination options:NSDataWritingAtomic error:error];
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(
                stderr,
                "usage: protector_metal_harness SCENE_PACK FRAME.png STATE.json\n"
            );
            return 2;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "no Metal device\n");
            return 3;
        }
        NSError* error = nil;
        NSURL* sceneURL = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        ProtectorMetalRenderer* renderer =
            [[ProtectorMetalRenderer alloc] initWithDevice:device
                                              scenePackURL:sceneURL
                                                     error:&error];
        if (!renderer) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 4;
        }

        NSURL* frameURL = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:argv[2]]];
        for (NSUInteger frame = 0; frame < 3; ++frame) {
            double time = (double)frame /
                (double)renderer.preferredFramesPerSecond;
            NSURL* output = frame == 0
                ? frameURL
                : [frameURL.URLByDeletingPathExtension
                    URLByAppendingPathExtension:
                        [NSString stringWithFormat:@"%lu.png",
                            (unsigned long)frame]];
            if (![renderer renderFrameAtTime:time toURL:output error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
                return 5;
            }
        }
        NSMutableDictionary* capture = [renderer.stateCapture mutableCopy];
        capture[@"presentation"] = @{
            @"width" : @(renderer.width),
            @"height" : @(renderer.height),
            @"frame_rate" : @(renderer.preferredFramesPerSecond),
            @"frame_times_seconds" : @[@0.0, @(1.0 / 30.0), @(2.0 / 30.0)],
            @"frame_period_microseconds" : @33333,
            @"frame_count" : @3,
        };
        NSURL* stateURL = [NSURL fileURLWithPath:
            [NSString stringWithUTF8String:argv[3]]];
        if (!WriteJSON(capture, stateURL, &error)) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            return 6;
        }
        printf(
            "metal_device=%s width=%lu height=%lu fps=%lu draws=%s\n",
            device.name.UTF8String,
            (unsigned long)renderer.width,
            (unsigned long)renderer.height,
            (unsigned long)renderer.preferredFramesPerSecond,
            [renderer.stateCapture[@"metal"][@"draw_count"] stringValue].UTF8String
        );
        return 0;
    }
}
