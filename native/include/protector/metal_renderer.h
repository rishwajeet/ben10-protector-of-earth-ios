#ifndef PROTECTOR_METAL_RENDERER_H
#define PROTECTOR_METAL_RENDERER_H

#include <stddef.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

@protocol CAMetalDrawable;

NS_ASSUME_NONNULL_BEGIN

@interface ProtectorMetalRenderer : NSObject

@property(nonatomic, readonly) NSUInteger width;
@property(nonatomic, readonly) NSUInteger height;
@property(nonatomic, readonly) NSUInteger preferredFramesPerSecond;
@property(nonatomic, readonly) NSDictionary<NSString*, id>* stateCapture;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                           scenePackURL:(NSURL*)scenePackURL
                                  error:(NSError**)error;

- (BOOL)encodeFrameAtTime:(double)time
                  texture:(id<MTLTexture>)texture
             commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    error:(NSError**)error;

- (BOOL)renderFrameAtTime:(double)time
                    toURL:(NSURL*)destination
                    error:(NSError**)error;

- (BOOL)presentFrameAtTime:(double)time
                  drawable:(id<CAMetalDrawable>)drawable
                     error:(NSError**)error;

- (void)setGameplayCameraEye:(simd_float3)eye
                      target:(simd_float3)target;

- (void)setGameplayVerticalFovDegrees:(float)degrees;

- (void)setGameplayActors:(NSArray<NSDictionary*>*)actors;

@end

NS_ASSUME_NONNULL_END
#endif

#endif
