#import "protector/geometry_pack.h"
#import <CommonCrypto/CommonDigest.h>
#include <cmath>
#include <cstring>
#include <set>

static NSError* GeometryPackError(NSString* message) {
    return [NSError errorWithDomain:@"ProtectorGeometryPack" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

// Lowercase hex SHA-256; false for input the digest API cannot take.
static bool GeometryHashHex(const void* bytes, NSUInteger length, char (&text)[2 * CC_SHA256_DIGEST_LENGTH]) {
    if (!bytes || length > UINT32_MAX) return false;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, hash);
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        text[2 * i] = digits[hash[i] >> 4];
        text[2 * i + 1] = digits[hash[i] & 15];
    }
    return true;
}

static NSString* GeometryHash(const void* bytes, NSUInteger length) {
    char text[2 * CC_SHA256_DIGEST_LENGTH];
    if (!GeometryHashHex(bytes, length, text)) return nil;
    return [[NSString alloc] initWithBytes:text length:sizeof(text) encoding:NSASCIIStringEncoding];
}

// Per-frame profile lookups compare digests without Objective-C strings.
static bool GeometryHashMatches(const void* bytes, NSUInteger length, const std::string& expected) {
    char text[2 * CC_SHA256_DIGEST_LENGTH];
    return GeometryHashHex(bytes, length, text) &&
        expected.size() == sizeof(text) && !memcmp(expected.data(), text, sizeof(text));
}

static bool GeometryHashValid(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return false;
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static bool GeometryNumber(id value, double minimum, double maximum, bool integer = false) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
    const double number = [value doubleValue];
    return std::isfinite(number) && number >= minimum && number <= maximum && (!integer || std::floor(number) == number);
}

static bool GeometryArray(id value, NSUInteger minimum, NSUInteger maximum) {
    return [value isKindOfClass:NSArray.class] && [value count] >= minimum && [value count] <= maximum;
}

@interface ProtectorGeometryPack ()
@property(nonatomic, readwrite) NSString* packID;
@property(nonatomic, readwrite) NSString* manifestSHA256;
@property(nonatomic, readwrite) NSUInteger entryCount;
@property(nonatomic) void* profiles;
@end

@implementation ProtectorGeometryPack
- (nullable instancetype)initWithManifest:(NSURL*)manifest error:(NSError**)error {
    self = [super init];
    if (!self) return nil;
    if (!manifest.isFileURL) {
        if (error) *error = GeometryPackError(@"Geometry packs must be local files.");
        return nil;
    }
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:manifest.path error:error];
    if (!attributes) return nil;
    if ([attributes[NSFileSize] unsignedLongLongValue] > 24u * 1024u * 1024u) {
        if (error) *error = GeometryPackError(@"Geometry manifest exceeds the 24 MiB authoring budget.");
        return nil;
    }
    NSData* data = [NSData dataWithContentsOfURL:manifest options:0 error:error];
    if (!data) return nil;
    if (data.length > 24u * 1024u * 1024u) {
        if (error) *error = GeometryPackError(@"Geometry manifest grew beyond its budget.");
        return nil;
    }
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!root) return nil;
    if (![root isKindOfClass:NSDictionary.class] ||
        ![root[@"schema"] isEqual:@"protector-native.geometry-pack/v1"] ||
        ![root[@"title_dol_sha256"] isEqual:@"03d2d8238fbd62c611c259ebeac3b2d87c3744bbaf3fb31ffd2c28d6664ac566"] ||
        ![root[@"pack_id"] isKindOfClass:NSString.class] || ![root[@"pack_id"] length] ||
        !GeometryArray(root[@"entries"], 1, 256)) {
        if (error) *error = GeometryPackError(@"Geometry manifest identity or entry count is invalid.");
        return nil;
    }
    _profiles = new std::vector<ProtectorGeometryProfile>();
    auto& profiles = *static_cast<std::vector<ProtectorGeometryProfile>*>(_profiles);
    std::set<std::string> identities;
    for (id entry in root[@"entries"]) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"id"] isKindOfClass:NSString.class] ||
            ![entry[@"id"] length] || !GeometryHashValid(entry[@"source_display_list_sha256"]) ||
            !GeometryHashValid(entry[@"source_uvs_sha256"]) ||
            !GeometryNumber(entry[@"source_vertex_count"], 3, 65535, true) ||
            !GeometryNumber(entry[@"source_display_list_bytes"], 12, 393213, true) ||
            !GeometryNumber(entry[@"source_uv_bytes"], 4, 262144, true) ||
            !GeometryArray(entry[@"index_widths"], 3, 3) ||
            !GeometryArray(entry[@"added_vertices"], 1, 131070) ||
            !GeometryArray(entry[@"indices"], 12, 786420) ||
            (![entry[@"middle_attribute"] isEqual:@"normal"] && ![entry[@"middle_attribute"] isEqual:@"color0"])) {
            if (error) *error = GeometryPackError(@"Geometry entry has invalid source bounds or attributes.");
            return nil;
        }
        ProtectorGeometryProfile profile;
        profile.identity = [entry[@"id"] UTF8String];
        profile.primitiveSHA256 = [entry[@"source_display_list_sha256"] UTF8String];
        profile.uvSHA256 = [entry[@"source_uvs_sha256"] UTF8String];
        profile.sourceVertexCount = [entry[@"source_vertex_count"] unsignedIntValue];
        profile.primitiveBytes = [entry[@"source_display_list_bytes"] unsignedIntValue];
        profile.uvBytes = [entry[@"source_uv_bytes"] unsignedIntValue];
        profile.hasNormals = [entry[@"middle_attribute"] isEqual:@"normal"];
        // Older unambiguous candidates have no anchor. New candidates pin the
        // immutable weights/bind positions/middle data immediately before UVs,
        // including the UV bytes, to distinguish topology-sharing variants.
        if (entry[@"source_anchor_prefix_bytes"] || entry[@"source_anchor_sha256"]) {
            if (!GeometryNumber(entry[@"source_anchor_prefix_bytes"], 4, 2u * 1024u * 1024u, true) ||
                !GeometryHashValid(entry[@"source_anchor_sha256"]) ||
                [entry[@"source_anchor_prefix_bytes"] unsignedIntValue] % 4) {
                if (error) *error = GeometryPackError(@"Geometry source bind anchor is invalid or unbounded.");
                return nil;
            }
            profile.sourceAnchorPrefixBytes = [entry[@"source_anchor_prefix_bytes"] unsignedIntValue];
            profile.sourceAnchorSHA256 = [entry[@"source_anchor_sha256"] UTF8String];
        }
        if (entry[@"source_rigid_arrays"]) {
            id arrays = entry[@"source_rigid_arrays"];
            if (![arrays isKindOfClass:NSDictionary.class] || [arrays count] != 2 ||
                !GeometryNumber(arrays[@"position_bytes"], 12, 65535u * 12u, true) ||
                !GeometryNumber(arrays[@"middle_bytes"], 3, 65535u * 4u, true)) {
                if (error) *error = GeometryPackError(@"Rigid geometry array bounds are invalid.");
                return nil;
            }
            profile.rigidPositionBytes = [arrays[@"position_bytes"] unsignedIntValue];
            profile.rigidMiddleBytes = [arrays[@"middle_bytes"] unsignedIntValue];
            const u32 middleStride = profile.hasNormals ? 3u : 4u;
            if (!profile.sourceAnchorPrefixBytes || profile.rigidPositionBytes % 12 ||
                profile.rigidMiddleBytes % middleStride || profile.rigidMiddleBytes / middleStride > 65535u ||
                profile.sourceAnchorPrefixBytes != profile.rigidPositionBytes + ((profile.rigidMiddleBytes + 3u) & ~3u)) {
                if (error) *error = GeometryPackError(@"Rigid geometry arrays do not exactly bound their source anchor.");
                return nil;
            }
            profile.rigidSourceArrays = true;
        }
        bool overlapping = false;
        for (const auto& old : profiles) {
            if (old.primitiveSHA256 != profile.primitiveSHA256) continue;
            // Only immutable rigid arrays may share topology. Same-length
            // spans with different hashes cannot both match one UV pointer.
            if (!old.rigidSourceArrays || !profile.rigidSourceArrays ||
                old.sourceAnchorPrefixBytes != profile.sourceAnchorPrefixBytes ||
                old.uvBytes != profile.uvBytes || old.sourceAnchorSHA256 == profile.sourceAnchorSHA256)
                overlapping = true;
        }
        if (!identities.insert(profile.identity).second || overlapping || profile.uvBytes % 4) {
            if (error) *error = GeometryPackError(@"Duplicate or misaligned geometry source identity.");
            return nil;
        }
        u32 stride = 0;
        for (NSUInteger index = 0; index < 3; ++index) {
            id width = entry[@"index_widths"][index];
            if (!GeometryNumber(width, 1, 2, true)) {
                if (error) *error = GeometryPackError(@"Geometry index width is not INDEX8/INDEX16.");
                return nil;
            }
            profile.indexWidths[index] = [width unsignedIntValue];
            stride += profile.indexWidths[index];
        }
        if (profile.primitiveBytes != 3 + profile.sourceVertexCount * stride) {
            if (error) *error = GeometryPackError(@"Geometry primitive byte count disagrees with its descriptors.");
            return nil;
        }
        for (id added in entry[@"added_vertices"]) {
            if (![added isKindOfClass:NSDictionary.class] || !GeometryArray(added[@"attributes"], 2, 2) ||
                !GeometryArray(added[@"position_stencil"], 2, 12)) {
                if (error) *error = GeometryPackError(@"Geometry midpoint stencil is invalid.");
                return nil;
            }
            ProtectorGeometryVertex vertex;
            for (NSUInteger axis = 0; axis < 2; ++axis) {
                if (!GeometryNumber(added[@"attributes"][axis], 0, profile.sourceVertexCount - 1, true)) {
                    if (error) *error = GeometryPackError(@"Geometry attribute interpolation exceeds the source vertices.");
                    return nil;
                }
                vertex.attributes[axis] = [added[@"attributes"][axis] unsignedIntValue];
            }
            double sum = 0, absolute = 0;
            std::set<u32> sources;
            for (id weight in added[@"position_stencil"]) {
                if (!GeometryArray(weight, 2, 2) || !GeometryNumber(weight[0], 0, profile.sourceVertexCount - 1, true) ||
                    !GeometryNumber(weight[1], -1, 1)) {
                    if (error) *error = GeometryPackError(@"Geometry position stencil exceeds its numeric or source bounds.");
                    return nil;
                }
                const u32 source = [weight[0] unsignedIntValue];
                const double value = [weight[1] doubleValue];
                if (!sources.insert(source).second) {
                    if (error) *error = GeometryPackError(@"Geometry position stencil repeats a source vertex.");
                    return nil;
                }
                sum += value;
                absolute += std::abs(value);
                vertex.positions.push_back({source, value});
            }
            if (std::abs(sum - 1) > 1e-8 || absolute > 2.50000001) {
                if (error) *error = GeometryPackError(@"Geometry stencil is not a bounded affine combination.");
                return nil;
            }
            profile.addedVertices.push_back(std::move(vertex));
        }
        const u32 count = profile.sourceVertexCount + (u32)profile.addedVertices.size();
        if ([entry[@"indices"] count] % 3) {
            if (error) *error = GeometryPackError(@"Geometry indices do not form complete triangles.");
            return nil;
        }
        for (id index in entry[@"indices"]) {
            if (!GeometryNumber(index, 0, count - 1, true)) {
                if (error) *error = GeometryPackError(@"Geometry triangle index exceeds the refined vertices.");
                return nil;
            }
            profile.indices.push_back([index unsignedIntValue]);
        }
        profiles.push_back(std::move(profile));
    }
    _packID = root[@"pack_id"];
    _manifestSHA256 = GeometryHash(data.bytes, data.length);
    _entryCount = profiles.size();
    return self;
}

- (void)dealloc { delete static_cast<std::vector<ProtectorGeometryProfile>*>(_profiles); }

- (nullable const ProtectorGeometryProfile*)profileForPrimitive:(const u8*)bytes length:(NSUInteger)length {
    const auto matches = [self profilesForPrimitive:bytes length:length];
    return matches.size() == 1 ? matches[0] : nullptr;
}

- (std::vector<const ProtectorGeometryProfile*>)profilesForPrimitive:(const u8*)bytes length:(NSUInteger)length {
    const auto& profiles = *static_cast<std::vector<ProtectorGeometryProfile>*>(_profiles);
    std::vector<const ProtectorGeometryProfile*> matches;
    char hash[2 * CC_SHA256_DIGEST_LENGTH];
    bool hashed = false, hashable = true;
    for (const auto& profile : profiles) {
        if (profile.primitiveBytes != length || !hashable) continue;
        if (!hashed) { hashable = GeometryHashHex(bytes, length, hash); hashed = true; }
        if (hashable && profile.primitiveSHA256.size() == sizeof(hash) &&
            !memcmp(profile.primitiveSHA256.data(), hash, sizeof(hash))) matches.push_back(&profile);
    }
    return matches;
}

- (BOOL)matchesUVs:(const u8*)bytes length:(NSUInteger)length profile:(const ProtectorGeometryProfile*)profile {
    if (!profile || profile->uvBytes != length) return NO;
    return GeometryHashMatches(bytes, length, profile->uvSHA256);
}

- (BOOL)matchesSourceAnchor:(const u8* _Nullable)bytes length:(NSUInteger)length profile:(const ProtectorGeometryProfile*)profile {
    if (!profile || !profile->sourceAnchorPrefixBytes ||
        length != (NSUInteger)profile->sourceAnchorPrefixBytes + profile->uvBytes) return NO;
    return GeometryHashMatches(bytes, length, profile->sourceAnchorSHA256);
}
@end
