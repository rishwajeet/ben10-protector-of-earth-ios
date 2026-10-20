#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Only use before a game session starts. Live save snapshots/restores are not
// supported: the guest may keep in-memory state or an open save-directory fd.
@interface ProtectorSaveBackup : NSObject
@property(nonatomic, readonly) NSDate* createdAt;
@property(nonatomic, readonly) NSUInteger totalBytes;
- (instancetype)init NS_UNAVAILABLE;
+ (nullable instancetype)readFromURL:(NSURL*)url error:(NSError**)error;
+ (BOOL)exportDirectory:(NSURL*)directory toURL:(NSURL*)url error:(NSError**)error;
// Success includes any recovery URL and a storage-durability warning. A nil
// result means no directory replacement happened. Old directories are retained.
- (nullable NSDictionary*)restoreToDirectory:(NSURL*)directory
                           recoveryDirectory:(NSURL*)recoveryDirectory
                                       error:(NSError**)error;
@end

NS_ASSUME_NONNULL_END
