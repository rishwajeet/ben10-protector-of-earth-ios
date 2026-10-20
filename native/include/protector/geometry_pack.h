#ifndef PROTECTOR_GEOMETRY_PACK_H
#define PROTECTOR_GEOMETRY_PACK_H

#include "protector/cpu.h"
#ifdef __cplusplus
#include <array>
#include <string>
#include <vector>

struct ProtectorGeometryWeight { u32 source; double weight; };
struct ProtectorGeometryVertex {
    std::array<u32, 2> attributes;
    std::vector<ProtectorGeometryWeight> positions;
};
struct ProtectorGeometryProfile {
    std::string identity;
    std::string primitiveSHA256;
    std::string uvSHA256;
    std::string sourceAnchorSHA256;
    u32 sourceVertexCount = 0;
    u32 primitiveBytes = 0;
    u32 uvBytes = 0;
    u32 sourceAnchorPrefixBytes = 0;
    // Rigid source arrays are immutable, unlike CPU-posed character arrays.
    // Their exact locations/strides must remain inside the hashed anchor.
    bool rigidSourceArrays = false;
    u32 rigidPositionBytes = 0;
    u32 rigidMiddleBytes = 0;
    bool hasNormals = false;
    std::array<u32, 3> indexWidths{};
    std::vector<ProtectorGeometryVertex> addedVertices;
    std::vector<u32> indices;
};
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/* Local source-bound render geometry only. Does not modify guest RAM, assets,
 * skeletons, saves, simulation, collision, timing, or original draw snapshots. */
@interface ProtectorGeometryPack : NSObject
@property(nonatomic, readonly) NSString* packID;
@property(nonatomic, readonly) NSString* manifestSHA256;
@property(nonatomic, readonly) NSUInteger entryCount;
- (nullable instancetype)initWithManifest:(NSURL*)manifest error:(NSError**)error;
#ifdef __cplusplus
- (nullable const ProtectorGeometryProfile*)profileForPrimitive:(const u8*)bytes
                                                        length:(NSUInteger)length;
// Topology-sharing rigid profiles require exact source-array disambiguation.
// The single-profile method above returns null for an ambiguous primitive.
- (std::vector<const ProtectorGeometryProfile*>)profilesForPrimitive:(const u8*)bytes
                                                             length:(NSUInteger)length;
- (BOOL)matchesUVs:(const u8*)bytes length:(NSUInteger)length
           profile:(const ProtectorGeometryProfile*)profile;
- (BOOL)matchesSourceAnchor:(const u8* _Nullable)bytes length:(NSUInteger)length
                    profile:(const ProtectorGeometryProfile*)profile;
#endif
@end
NS_ASSUME_NONNULL_END
#endif
#endif
