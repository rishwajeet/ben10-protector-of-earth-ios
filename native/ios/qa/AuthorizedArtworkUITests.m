#import <XCTest/XCTest.h>

// The human-approved disposable saves are staged and byte-exactly restored by
// the external runner. This observer never edits save data or source rules.
@interface ProtectorExtrasViewersSourceUITests : XCTestCase
@property(nonatomic) XCUIApplication* game;
@property(nonatomic) NSString* container;
@property(nonatomic) NSString* commandPath;
- (NSString*)hash:(NSData*)data;
- (NSDictionary*)json:(NSString*)path;
- (void)settle;
- (void)waitForLabel:(NSString*)label timeout:(NSTimeInterval)timeout;
- (void)controller:(NSString*)command;
- (void)pulse:(NSString*)command;
- (void)waitForContext:(NSString*)context;
- (void)waitForKey:(NSString*)key;
- (void)attach:(NSDictionary*)data name:(NSString*)name;
@end

@implementation ProtectorExtrasViewersSourceUITests (AuthorizedArtwork)
- (void)testAuthorizedCodeArtworkWithoutSubmission {
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_WORLD_CODE_ARTWORK"],@"source-code-artwork-v1");
    NSArray* keys=[env[@"PROTECTOR_AUTHORIZED_ARTWORK_INSPECTION_KEYS"] componentsSeparatedByString:@","];
    XCTAssertEqual(keys.count,6u);
    NSString* save=[self beginAuthorizedArtwork:YES];
    NSString* before=[self hash:[NSData dataWithContentsOfFile:save]];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self pulse:@"down"];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:30];[self pulse:@"a"];
    [self waitForKey:@"Panel-ExtrasScreen-1"];[self settle];
    for(NSUInteger i=0;i<6;i++)[self pulse:@"down"];
    [self pulse:@"a"];[self waitForKey:@"Panel-UnlockableScreen-15"];[self settle];
    // Only change the first displayed symbol. Never Confirm or submit a code.
    [self artworkCapture:@"world-code-entry" expectedSources:[NSSet set]];
    [self releaseArtworkInspection];
    for(NSUInteger i=0;i<5;i++) {
        [self pulse:@"up"];[self settle];
        [self artworkCapture:[NSString stringWithFormat:@"world-code-symbol-%lu",(unsigned long)i]
            expectedSources:[NSSet set]];
    }
    for(NSUInteger i=0;i<keys.count;i++)[self waitForArtworkInspection:i key:keys[i]];
    [self pulse:@"b"];[self settle];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self artworkCapture:@"world-code-return" expectedSources:[NSSet set]];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],before);
    [self attach:@{@"keys":keys,@"symbol_changes":@5,@"code_submissions":@0,
        @"scope":@"One existing Code menu artwork route, unchanged game rules and save. Not whole-pack, campaign or QTE acceptance."}
        name:@"world-code-artwork-observation"];
    [self.game.buttons[@"native-pause"] tap];
}
- (NSString*)authorizedPhotoFixtureHash {
    NSString* variant=NSProcessInfo.processInfo.environment[@"PROTECTOR_AUTHORIZED_ARTWORK_MAP_FIXTURE"];
    if(variant) {
        XCTAssertEqualObjects(variant,@"source-bound-map-v1");
        return @"822dc43989daf5f0fabfbfe9647e33f346691ca440b916401c2a02c11fd59a8b";
    }
    return @"a799620a2818865cda9d192125ab0caf5c88f8ef06b6dd1394daf850cb5c837f";
}
- (void)artworkCapture:(NSString*)name expectedSources:(NSSet*)expected {
    NSString* path=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"];
    NSDate* after=NSDate.date;
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:12];
    BOOL fresh=NO;
    while(deadline.timeIntervalSinceNow>0) {
        NSDate* modified=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if(modified && [modified compare:after]==NSOrderedDescending) { fresh=YES;break; }
        [NSThread sleepForTimeInterval:.1];
    }
    XCTAssertTrue(fresh);
    NSDictionary* state=[self json:path];
    XCTAssertEqualObjects(state[@"audio_output"],@"disabled");
    XCTAssertEqualObjects(state[@"runtime_error"],NSNull.null);
    NSDictionary* environment=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(state[@"texture_pack_id"],environment[@"PROTECTOR_AUTHORIZED_ARTWORK_PACK_ID"]);
    XCTAssertEqual([state[@"texture_pack_entries"] unsignedIntegerValue],
        [environment[@"PROTECTOR_AUTHORIZED_ARTWORK_PACK_ENTRIES"] integerValue]);
    XCTAssertLessThanOrEqual([state[@"texture_pack_frame_bytes"] unsignedLongLongValue],
        [state[@"texture_pack_allocation_budget_bytes"] unsignedLongLongValue]);
    XCTAssertLessThanOrEqual([state[@"texture_pack_frame_encoded_bytes"] unsignedLongLongValue],
        [state[@"texture_pack_encoded_budget_bytes"] unsignedLongLongValue]);
    XCTAssertEqualObjects(state[@"texture_pack_manifest_sha256"],
        NSProcessInfo.processInfo.environment[@"PROTECTOR_AUTHORIZED_ARTWORK_PACK_SHA256"]);
    XCTAssertTrue([expected isSubsetOfSet:[NSSet setWithArray:state[@"texture_pack_frame_sources"] ?: @[]]],
        @"Exact family textures must be submitted through the translated native renderer");
    XCTAttachment* picture=[XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    picture.name=name;picture.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:picture];
    [self attach:state name:[name stringByAppendingString:@"-renderer"]];
    [self attach:[self json:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/native-controls.json"]]
        name:[name stringByAppendingString:@"-controls"]];
    XCTAttachment* tree=[XCTAttachment attachmentWithString:self.game.debugDescription];
    tree.name=[name stringByAppendingString:@"-hierarchy"];
    tree.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:tree];
}
- (NSString*)beginAuthorizedArtwork:(BOOL)photos {
    self.continueAfterFailure=NO;self.executionTimeAllowance=360;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_AUTHORIZED_ARTWORK_VERSION"],@"photo-thumbnail-artwork-v1");
    self.container=env[@"PROTECTOR_AUTHORIZED_ARTWORK_CONTAINER"];
    XCTAssertTrue(self.container.isAbsolutePath);
    NSString* identity=photos ? @"house.machine.ProtectorNative.MaterialArtworkQA" : @"house.machine.ProtectorNative.ExtrasUnlockedQA";
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"]][@"MCMMetadataIdentifier"],identity);
    NSString* bundle=env[@"PROTECTOR_AUTHORIZED_ARTWORK_BUNDLE"];
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"],identity);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Game/files/CDGame.txt"]]],
        @"97b1fdc2f30f68d4a4f2727d31bb38057a41e5885f8cc9ebe3a8d726aca84919");
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"RestoredArt/pack.json"]]],
        env[@"PROTECTOR_AUTHORIZED_ARTWORK_PACK_SHA256"]);
    NSString* save=[self.container stringByAppendingPathComponent:@"Library/Application Support/Original/UpgradedSaves-RBNEG9-v1/SavedGames"];
    NSString* expected=photos ? [self authorizedPhotoFixtureHash] :
        @"02c4c462a1308cf28281ec7f7ec45543eafb95b04dc3fcdb581a71f9584b72fe";
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],expected);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"]]);
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:trace]);
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationLandscapeLeft;
    self.game=[[XCUIApplication alloc] initWithBundleIdentifier:identity];
    self.commandPath=[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"authorized-artwork-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.game.launchArguments=@[@"-touch.hideWithController.v1",@"NO",@"-touch.scale.v1",@"1",
        @"-touch.swapped.v1",@"NO",@"-touch.labels.v1",@"NO"];
    NSMutableDictionary* launch=[@{@"PROTECTOR_UI_TEXT_LOG":trace,@"PROTECTOR_CONTROLLER_QA":@"1",
        @"PROTECTOR_CONTROLLER_QA_PATH":self.commandPath,@"PROTECTOR_CONTROLLER_QA_READBACK":@"1",
        @"PROTECTOR_MATERIAL_AUDIT_KEYS":env[@"PROTECTOR_AUTHORIZED_ARTWORK_INSPECTION_KEYS"],
        @"PROTECTOR_MATERIAL_AUDIT_ISOLATE":@"1",
        @"PROTECTOR_MATERIAL_AUDIT_READY_PATH":[self.commandPath stringByAppendingString:@".ready"]} mutableCopy];
    if(env[@"PROTECTOR_AUTHORIZED_ARTWORK_NO_WRITE_PROOF"]) {
        XCTAssertEqualObjects(env[@"PROTECTOR_AUTHORIZED_ARTWORK_NO_WRITE_PROOF"],@"1");
        launch[@"PROTECTOR_MATERIAL_NO_WRITE_PROOF"]=@"1";
    }
    if([env[@"PROTECTOR_AUTHORIZED_MAP_SOURCE_BATCH"] isEqual:@"1"])
        launch[@"PROTECTOR_INTERFACE_AUDIT_FRAME"]=@"1";
    self.game.launchEnvironment=launch;
    [self.game launch];[self waitForLabel:@"Game title. Use Confirm to begin." timeout:100];
    [self controller:@"neutral"];[self pulse:@"a"];[self settle];
    [self pulse:@"down"];[self pulse:@"a"];[self settle];[self pulse:@"a"];
    [self waitForLabel:@"Game map. Move to choose a location. Use Confirm or Back." timeout:45];
    [self settle];
    return save;
}
- (void)releaseArtworkInspection {
    XCTAssertTrue([[@"ready\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:
        [self.commandPath stringByAppendingString:@".ready"] options:NSDataWritingWithoutOverwriting error:nil]);
}
- (void)waitForArtworkInspection:(NSUInteger)ordinal key:(NSString*)key {
    NSString* path=[self.container stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Documents/Diagnostics/material-source-%02lu/inspection.json",(unsigned long)ordinal]];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:25];
    while(![NSFileManager.defaultManager fileExistsAtPath:path] && deadline.timeIntervalSinceNow>0)
        [NSThread sleepForTimeInterval:.1];
    NSDictionary* report=[self json:path];
    XCTAssertEqualObjects(report[@"source_key"],key);
    XCTAssertEqualObjects(report[@"source_vertices_immutable"],@YES);
    XCTAssertEqualObjects(report[@"guest_updates_during_inspection"],@0);
    XCTAssertEqualObjects(report[@"readiness_gate_released"],@YES);
    XCTAssertEqualObjects(report[@"isolation_enabled"],@YES);
    if(NSProcessInfo.processInfo.environment[@"PROTECTOR_AUTHORIZED_ARTWORK_NO_WRITE_PROOF"]) {
        NSArray* proof=report[@"no_write_proof_samples"];
        XCTAssertEqual(proof.count,3u);
        NSData* first=nil;
        for(NSUInteger index=0;index<proof.count;++index) {
            NSDictionary* sample=proof[index];
            NSData* pixels=[NSData dataWithContentsOfFile:[[path stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:sample[@"image"]]];
            XCTAssertGreaterThan(pixels.length,0u);
            if(!first)first=pixels;else XCTAssertEqualObjects(pixels,first);
            XCTAssertEqualObjects(sample[@"state"][@"no_write_culling_enabled"],@(index!=1));
            XCTAssertEqualObjects(sample[@"state"][@"restored_artwork_enabled"],@NO);
        }
        XCTAssertGreaterThan([proof[0][@"state"][@"no_write_culled_draws"] unsignedIntegerValue],0u);
        XCTAssertEqual([proof[1][@"state"][@"no_write_culled_draws"] unsignedIntegerValue],0u);
    }
    XCTAssertEqual([report[@"isolation_samples"] count],3u);
    [self attach:report name:[NSString stringWithFormat:@"artwork-isolation-%02lu",(unsigned long)ordinal]];
}
- (void)waitForFreshArtworkHeading:(NSString*)key afterOffset:(NSUInteger)offset {
    NSString* trace=[self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:12];
    while(deadline.timeIntervalSinceNow>0) {
        NSData* bytes=[NSData dataWithContentsOfFile:trace];
        if(bytes.length>offset) {
            NSString* tail=[[NSString alloc] initWithData:[bytes subdataWithRange:NSMakeRange(offset,bytes.length-offset)]
                encoding:NSUTF8StringEncoding];
            for(NSString* line in [tail componentsSeparatedByString:@"\n"]) {
                NSDictionary* row=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                    options:0 error:nil];
                if([row[@"key"] isEqual:key]) { [self attach:row name:@"fresh-artwork-category-heading"];return; }
            }
        }
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"Expected newly emitted category heading %@, not a historical root-menu label",key);
}
- (void)testAuthorizedStoryPhotographArtwork {
    NSString* save=[self beginAuthorizedArtwork:YES];
    NSString* key=NSProcessInfo.processInfo.environment[@"PROTECTOR_AUTHORIZED_ARTWORK_INSPECTION_KEYS"];
    NSSet* expected=[NSSet setWithObject:key];
    [self artworkCapture:@"story-photo-overview" expectedSources:expected];
    [self.game.buttons[@"game-action-2048"] tap];[self settle];
    [self releaseArtworkInspection];[self waitForArtworkInspection:0 key:key];
    [self artworkCapture:@"story-photo-zoom" expectedSources:expected];
    [self.game.buttons[@"game-back"] tap];[self settle];
    [self artworkCapture:@"story-photo-return" expectedSources:expected];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],
        @"a799620a2818865cda9d192125ab0caf5c88f8ef06b6dd1394daf850cb5c837f");
    [self.game.buttons[@"native-pause"] tap];
}
- (void)testAuthorizedCharacterThumbnailArtwork {
    NSString* save=[self beginAuthorizedArtwork:NO];
    [self.game.buttons[@"native-pause"] tap];
    XCTAssertTrue([self.game.tables[@"native-game-settings"] waitForExistenceWithTimeout:8]);
    [self.game.cells[@"open-game-menu"] tap];
    [self waitForLabel:@"Game menu. Use the menu controls to choose and confirm." timeout:12];
    [self pulse:@"down"];[self pulse:@"down"];[self pulse:@"a"];
    [self waitForLabel:@"Game ready. Use Confirm to continue." timeout:30];[self pulse:@"a"];
    [self waitForContext:@"extras-root"];[self settle];
    // Root starts at Concept Art, then Movies, then Hero. This skips both
    // earlier categories without opening or replaying them.
    [self pulse:@"down"];[self pulse:@"down"];
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    NSString* selectionPath=env[@"PROTECTOR_AUTHORIZED_ARTWORK_SELECTION"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:selectionPath]],env[@"PROTECTOR_AUTHORIZED_ARTWORK_SELECTION_SHA256"]);
    NSDictionary* selection=[self json:selectionPath];
    NSArray* families=@[@"hero",@"enemy",@"boss"];
    NSArray* headings=@[@"Panel-ExtrasScreen-7",@"Panel-ExtrasScreen-8",@"Panel-ExtrasScreen-4"];
    NSArray* inspectionKeys=[env[@"PROTECTOR_AUTHORIZED_ARTWORK_INSPECTION_KEYS"] componentsSeparatedByString:@","];
    XCTAssertEqual(inspectionKeys.count,3u);
    for(NSUInteger i=0;i<families.count;i++) {
        if(i) [self pulse:@"down"];
        NSUInteger traceOffset=[NSData dataWithContentsOfFile:[self.container stringByAppendingPathComponent:
            @"Documents/extras-ui-text.jsonl"]].length;
        [self pulse:@"a"];[self waitForContext:@"extras-browser"];
        [self waitForFreshArtworkHeading:headings[i] afterOffset:traceOffset];[self settle];
        NSMutableSet* expected=[NSMutableSet set];
        for(NSDictionary* array in selection[@"arrays"]) if([array[@"family"] isEqual:families[i]])
            for(NSDictionary* row in array[@"source_array"]) [expected addObject:row[@"source_key"]];
        XCTAssertEqual(expected.count, i==0 ? 20u : i==1 ? 30u : 11u);
        if(i==0) [self releaseArtworkInspection];
        [self waitForArtworkInspection:i key:inspectionKeys[i]];
        [self artworkCapture:[NSString stringWithFormat:@"thumbnail-%@-grid",families[i]] expectedSources:expected];
        [self.game.buttons[@"game-action-2"] tap];[self settle];
        [self artworkCapture:[NSString stringWithFormat:@"thumbnail-%@-selection",families[i]] expectedSources:expected];
        [self.game.buttons[@"game-back"] tap];[self waitForContext:@"extras-root"];[self settle];
    }
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],
        @"02c4c462a1308cf28281ec7f7ec45543eafb95b04dc3fcdb581a71f9584b72fe");
    [self.game.buttons[@"native-pause"] tap];
}
- (void)testAuthorizedStoryPhotographNavigation {
    // Reachability observation only. The runner stages the exact authorized
    // photo-only or source-bound location fixture; this observer edits neither.
    NSString* save=[self beginAuthorizedArtwork:YES];
    NSArray* directions=@[@"right",@"up",@"left",@"down"];
    BOOL stick=[NSProcessInfo.processInfo.environment[@"PROTECTOR_AUTHORIZED_ARTWORK_NAV_INPUT"] isEqual:@"stick"];
    for(NSString* direction in directions) {
        NSString* command=stick ? [@"stick" stringByAppendingString:direction] : direction;
        [self controller:command];
        [self attach:[self json:[self.commandPath stringByAppendingString:@".receipt.json"]]
            name:[@"story-navigation-input-" stringByAppendingString:direction]];
        [self controller:@"neutral"];[self settle];
        [self artworkCapture:[@"story-navigation-" stringByAppendingString:direction]
            expectedSources:[NSSet set]];
    }
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],
        [self authorizedPhotoFixtureHash]);
    [self.game.buttons[@"native-pause"] tap];
}
- (void)testAuthorizedStoryPhotographWesternRoute {
    // Visit distinct photographs through ordinary source-owned map controls.
    // Never Confirm from the photograph detail: that would enter a level.
    NSString* save=[self beginAuthorizedArtwork:YES];
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_AUTHORIZED_ARTWORK_MAP_FIXTURE"],@"source-bound-map-v1");
    NSString* bindingPath=env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_BINDING"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:bindingPath]],
        env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_BINDING_SHA256"]);
    NSArray* panels=[self json:bindingPath][@"original_panels"];
    XCTAssertEqual(panels.count,24u);
    NSArray* routes=@[@"",@"stickup",@"stickleft",@"stickleft",@"stickdown"];
    NSArray* ordinals=@[@0,@1,@2,@4,@3];
    for(NSUInteger step=0;step<routes.count;step++) {
        NSUInteger ordinal=[ordinals[step] unsignedIntegerValue];
        if(step) {
            NSUInteger offset=[NSData dataWithContentsOfFile:[self.container stringByAppendingPathComponent:
                @"Documents/extras-ui-text.jsonl"]].length;
            [self controller:routes[step]];
            [self attach:[self json:[self.commandPath stringByAppendingString:@".receipt.json"]]
                name:[NSString stringWithFormat:@"western-photo-%02lu-input",(unsigned long)ordinal]];
            [self controller:@"neutral"];[self settle];
            [self waitForFreshArtworkHeading:[NSString stringWithFormat:@"Panel-HubScreenNames-%lu",(unsigned long)ordinal]
                afterOffset:offset];
        }
        NSDictionary* panel=panels[ordinal];
        XCTAssertEqualObjects(panel[@"ordinal"],@(ordinal));
        NSSet* expected=[NSSet setWithArray:panel[@"source_keys"]];
        NSString* name=[NSString stringWithFormat:@"western-photo-%02lu",(unsigned long)ordinal];
        [self artworkCapture:[name stringByAppendingString:@"-overview"] expectedSources:expected];
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self artworkCapture:[name stringByAppendingString:@"-detail"] expectedSources:expected];
        [self.game.buttons[@"game-back"] tap];[self settle];
        [self artworkCapture:[name stringByAppendingString:@"-return"] expectedSources:expected];
    }
    [self.game.buttons[@"game-back"] tap];[self settle];
    [self artworkCapture:@"western-photo-region-exit" expectedSources:[NSSet set]];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],[self authorizedPhotoFixtureHash]);
    [self.game.buttons[@"native-pause"] tap];
}
- (NSUInteger)artworkTraceOffset {
    return [NSData dataWithContentsOfFile:[self.container stringByAppendingPathComponent:
        @"Documents/extras-ui-text.jsonl"]].length;
}
- (void)setMapSourceMotion:(BOOL)enabled {
    [self.game.buttons[@"native-pause"] tap];
    XCUIElement* settings=self.game.tables[@"native-game-settings"];
    XCTAssertTrue([settings waitForExistenceWithTimeout:8]);
    XCUIElement* motion=self.game.switches[@"render.motion"];
    for(NSUInteger i=0;i<12 && !motion.hittable;i++) [settings swipeUp];
    XCTAssertTrue(motion.hittable);
    if([motion.value isEqual:@"1"]!=enabled) [motion tap];
    XCTAssertEqualObjects(motion.value,enabled ? @"1" : @"0");
    [self.game.buttons[@"Resume"] tap];
}
- (void)testAuthorizedCountryMapSourceBatch {
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_AUTHORIZED_MAP_SOURCE_BATCH"],@"1");
    NSString* path=env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:path]],
        env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE_SHA256"]);
    NSArray* regions=[self json:path][@"regions"];
    XCTAssertEqual(regions.count,5u);
    for(NSUInteger selected=0;selected<regions.count;selected++) {
        NSString* save=[self beginAuthorizedArtwork:YES];
        self.executionTimeAllowance=900;
        [self.game.buttons[@"game-back"] tap];[self settle];
        for(NSUInteger r=1;r<=selected;r++) {
            [self controller:regions[r][@"world_move"]];[self controller:@"neutral"];[self settle];
        }
        NSString* name=[NSString stringWithFormat:@"country-source-r%lu",(unsigned long)selected];
        [self artworkCapture:name expectedSources:[NSSet set]];
        NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
        NSDictionary* state=[self json:[diagnostics stringByAppendingPathComponent:@"interactive-state.json"]];
        XCTAssertEqualObjects(state[@"native_world_map_layout"][@"region"],@(selected));
        NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
        [self setMapSourceMotion:NO];
        NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:20];
        while(![NSFileManager.defaultManager fileExistsAtPath:audit] && deadline.timeIntervalSinceNow>0)
            [NSThread sleepForTimeInterval:.1];
        NSDictionary* report=[self json:audit];
        XCTAssertEqualObjects(report[@"source"],@"translated_execution_callback");
        XCTAssertEqualObjects(report[@"omitted_orthographic_draws"],@0);
        XCTAssertEqualObjects(report[@"omitted_vertices"],@0);
        [self setMapSourceMotion:YES];[self.game terminate];
        XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],[self authorizedPhotoFixtureHash]);
        NSString* archive=[self.container stringByAppendingPathComponent:
            [@"Documents/country-source-batch-v1/" stringByAppendingString:name]];
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:archive withIntermediateDirectories:YES
            attributes:nil error:nil]);
        XCTAssertTrue([NSFileManager.defaultManager moveItemAtPath:diagnostics toPath:
            [archive stringByAppendingPathComponent:@"Diagnostics"] error:nil]);
        XCTAssertTrue([NSFileManager.defaultManager moveItemAtPath:
            [self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"] toPath:
            [archive stringByAppendingPathComponent:@"extras-ui-text.jsonl"] error:nil]);
    }
}
- (void)testAuthorizedMapCompletionCompact {
    NSString* save=[self beginAuthorizedArtwork:YES];
    self.executionTimeAllowance=600;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    NSString* path=env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:path]],env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE_SHA256"]);
    NSArray* regions=[self json:path][@"regions"];
    NSString* statePath=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"];
    [self artworkCapture:@"map-completion-regional-regression" expectedSources:[NSSet set]];
    XCTAssertEqualObjects([self json:statePath][@"native_world_map_layout"][@"admission"],@"complete-regional-overview");
    [self.game.buttons[@"game-back"] tap];[self settle];
    [self artworkCapture:@"map-completion-country-southwest" expectedSources:[NSSet set]];
    XCTAssertEqualObjects([self json:statePath][@"native_world_map_layout"][@"admission"],@"complete-country-title");
    for(NSUInteger r=1;r<5;r++) {
        NSDictionary* region=regions[r];
        [self controller:region[@"world_move"]];[self controller:@"neutral"];[self settle];
        if(r!=1&&r!=4)continue;
        if(r==4) {
            [self artworkCapture:@"map-completion-country-eastcoast" expectedSources:[NSSet set]];
            XCTAssertEqualObjects([self json:statePath][@"native_world_map_layout"][@"admission"],@"complete-country-title");
            XCTAssertEqualObjects([self json:statePath][@"native_world_map_layout"][@"region"],@4);
        }
        NSUInteger offset=[self artworkTraceOffset];
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self waitForFreshArtworkHeading:[NSString stringWithFormat:@"Panel-HubScreenNames-%@",region[@"steps"][0][@"ordinal"]] afterOffset:offset];
        const NSUInteger target=r==1?8:23;
        NSSet* expected=nil;
        for(NSDictionary* step in region[@"steps"]) {
            for(NSDictionary* move in step[@"route"]) {
                offset=[self artworkTraceOffset];
                [self controller:move[@"command"]];[self controller:@"neutral"];[self settle];
                [self waitForFreshArtworkHeading:[NSString stringWithFormat:@"Panel-HubScreenNames-%@",move[@"ordinal"]] afterOffset:offset];
            }
            if([step[@"ordinal"] unsignedIntegerValue]==target) { expected=[NSSet setWithArray:step[@"source_keys"]];break; }
        }
        XCTAssertNotNil(expected);
        [self.game.buttons[@"game-action-2048"] tap];[self settle];
        [self artworkCapture:r==1?@"map-completion-detail-seattle":@"map-completion-detail-eastcoast" expectedSources:expected];
        XCTAssertEqualObjects([self json:statePath][@"native_map_detail_backdrop"][@"enabled"],@YES);
        [self.game.buttons[@"game-back"] tap];[self settle];
        [self.game.buttons[@"game-back"] tap];[self settle];
    }
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],[self authorizedPhotoFixtureHash]);
    [self.game.buttons[@"native-pause"] tap];
}
- (void)testAuthorizedWorldMapSourceBatch {
    // Reuse the existing one-shot exporter, restarting only the disposable
    // QA app. No renderer instrumentation, save edits or level entry required.
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_AUTHORIZED_MAP_SOURCE_BATCH"],@"1");
    XCTAssertEqualObjects(env[@"PROTECTOR_AUTHORIZED_ARTWORK_MAP_FIXTURE"],@"source-bound-map-v1");
    NSString* path=env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:path]],
        env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE_SHA256"]);
    NSArray* regions=[self json:path][@"regions"];
    XCTAssertEqual(regions.count,5u);
    NSArray* targets=@[@0,@8,@10,@19,@23];
    for(NSUInteger sample=0;sample<11;sample++) {
        NSUInteger regionNumber=sample<10 ? sample/2 : 1;
        BOOL detail=sample<10 && sample%2;
        NSNumber* target=sample<10 ? targets[regionNumber] : @5;
        NSString* save=[self beginAuthorizedArtwork:YES];
        self.executionTimeAllowance=1800;
        NSMutableSet* emitted=[NSMutableSet setWithObject:@0];
        for(NSUInteger r=0;r<=regionNumber;r++) {
            NSDictionary* region=regions[r];
            if(r) {
                [self controller:region[@"world_move"]];[self controller:@"neutral"];[self settle];
                NSUInteger offset=[self artworkTraceOffset];
                [self.game.buttons[@"game-action-2048"] tap];[self settle];
                NSNumber* first=region[@"steps"][0][@"ordinal"];
                [self waitForFreshArtworkHeading:[NSString stringWithFormat:@"Panel-HubScreenNames-%@",first]
                    afterOffset:offset];
                [emitted addObject:first];
            }
            if(r<regionNumber) { [self.game.buttons[@"game-back"] tap];[self settle];continue; }
            BOOL reached=NO;
            for(NSDictionary* step in region[@"steps"]) {
                for(NSDictionary* move in step[@"route"]) {
                    NSUInteger offset=[self artworkTraceOffset];
                    [self controller:move[@"command"]];[self controller:@"neutral"];[self settle];
                    if(![emitted containsObject:move[@"ordinal"]]) {
                        [self waitForFreshArtworkHeading:[NSString stringWithFormat:@"Panel-HubScreenNames-%@",move[@"ordinal"]]
                            afterOffset:offset];
                        [emitted addObject:move[@"ordinal"]];
                    }
                }
                if([step[@"ordinal"] isEqual:target]) { reached=YES;break; }
            }
            XCTAssertTrue(reached);
        }
        if(detail) { [self.game.buttons[@"game-action-2048"] tap];[self settle]; }
        NSString* name=[NSString stringWithFormat:@"map-source-r%lu-photo%@-%@",(unsigned long)regionNumber,
            target,detail ? @"detail" : @"overview"];
        [self artworkCapture:[name stringByAppendingString:@"-smooth"] expectedSources:[NSSet set]];
        NSString* diagnostics=[self.container stringByAppendingPathComponent:@"Documents/Diagnostics"];
        NSString* audit=[diagnostics stringByAppendingPathComponent:@"interface-source/audit.json"];
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:audit]);
        [self setMapSourceMotion:NO];
        NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:20];
        while(![NSFileManager.defaultManager fileExistsAtPath:audit] && deadline.timeIntervalSinceNow>0)
            [NSThread sleepForTimeInterval:.1];
        NSDictionary* report=[self json:audit];
        XCTAssertEqualObjects(report[@"schema"],@"protector-native.interface-source-audit/v1");
        XCTAssertEqualObjects(report[@"source"],@"translated_execution_callback");
        XCTAssertEqualObjects(report[@"omitted_orthographic_draws"],@0);
        XCTAssertEqualObjects(report[@"omitted_vertices"],@0);
        [self artworkCapture:[name stringByAppendingString:@"-audit"] expectedSources:[NSSet set]];
        [self attach:@{@"region":@(regionNumber),@"ordinal":target,@"detail":@(detail),
            @"frame_index":report[@"frame_index"],@"guest_timebase":report[@"guest_timebase"]} name:name];
        [self setMapSourceMotion:YES];
        [self.game terminate];
        XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],[self authorizedPhotoFixtureHash]);
        NSString* archive=[self.container stringByAppendingPathComponent:
            [@"Documents/map-source-batch-v1/" stringByAppendingString:name]];
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:archive]);
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:archive withIntermediateDirectories:YES
            attributes:nil error:nil]);
        XCTAssertTrue([NSFileManager.defaultManager moveItemAtPath:diagnostics toPath:
            [archive stringByAppendingPathComponent:@"Diagnostics"] error:nil]);
        XCTAssertTrue([NSFileManager.defaultManager moveItemAtPath:
            [self.container stringByAppendingPathComponent:@"Documents/extras-ui-text.jsonl"] toPath:
            [archive stringByAppendingPathComponent:@"extras-ui-text.jsonl"] error:nil]);
    }
}
- (void)testAuthorizedStoryPhotographCompleteMap {
    [self runAuthorizedStoryPhotographMap:NO];
}
- (void)testAuthorizedWorldMapLayout {
    [self runAuthorizedStoryPhotographMap:YES];
}
- (void)testAuthorizedWorldMapRemainingEdges {
    NSString* save=[self beginAuthorizedArtwork:YES];
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    NSString* path=env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:path]],
        env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE_SHA256"]);
    NSArray* regions=[self json:path][@"regions"];
    for(NSUInteger r=0;r<5;++r) {
        NSDictionary* region=regions[r];
        if(r) {
            [self controller:region[@"world_move"]];[self controller:@"neutral"];[self settle];
            [self.game.buttons[@"game-action-2048"] tap];[self settle];
        }
        if(r!=2&&r!=4) { [self.game.buttons[@"game-back"] tap];[self settle];continue; }
        NSNumber* target=r==2?@12:@22;
        BOOL reached=NO;
        for(NSDictionary* step in region[@"steps"]) {
            for(NSDictionary* move in step[@"route"]) {
                [self controller:move[@"command"]];[self controller:@"neutral"];[self settle];
                [self waitForNativeMapOrdinal:move[@"ordinal"]];
            }
            if(![step[@"ordinal"] isEqual:target])continue;
            NSSet* expected=[NSSet setWithArray:step[@"source_keys"]];
            NSString* name=[NSString stringWithFormat:@"photo-%02lu",(unsigned long)target.unsignedIntegerValue];
            [self artworkCapture:[name stringByAppendingString:@"-overview"] expectedSources:expected];
            [self assertNativeMapLayout:YES ordinal:target];
            [self.game.buttons[@"game-action-2048"] tap];[self settle];
            [self artworkCapture:[name stringByAppendingString:@"-detail"] expectedSources:expected];
            [self assertNativeMapLayout:NO ordinal:nil];
            [self.game.buttons[@"game-back"] tap];[self settle];
            [self artworkCapture:[name stringByAppendingString:@"-return"] expectedSources:expected];
            [self assertNativeMapLayout:YES ordinal:target];
            reached=YES;break;
        }
        XCTAssertTrue(reached);
        if(r<4) { [self.game.buttons[@"game-back"] tap];[self settle]; }
    }
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],[self authorizedPhotoFixtureHash]);
    [self.game.buttons[@"native-pause"] tap];
}
- (void)runAuthorizedStoryPhotographMap:(BOOL)layoutQA {
    NSString* save=[self beginAuthorizedArtwork:YES];
    self.executionTimeAllowance=900;
    NSDictionary* env=NSProcessInfo.processInfo.environment;
    XCTAssertEqualObjects(env[@"PROTECTOR_AUTHORIZED_ARTWORK_MAP_FIXTURE"],@"source-bound-map-v1");
    NSString* path=env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE"];
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:path]],
        env[@"PROTECTOR_AUTHORIZED_ARTWORK_PHOTO_ROUTE_SHA256"]);
    NSDictionary* plan=[self json:path];
    BOOL reuse=[env[@"PROTECTOR_AUTHORIZED_ARTWORK_REUSE_PHONE_PREFIX"] isEqual:@"1"];
    const uint32_t layoutTargets=(1u<<0)|(1u<<3)|(1u<<4)|(1u<<5)|(1u<<8)|(1u<<9)|(1u<<10)|(1u<<12)|(1u<<18)|(1u<<22)|(1u<<23);
    NSMutableSet* visited=[NSMutableSet set];
    uint32_t emittedHeadingMask=1;
    for(NSDictionary* region in plan[@"regions"]) {
        NSUInteger number=[region[@"region"] unsignedIntegerValue];
        if(number) {
            [self controller:region[@"world_move"]];
            [self attach:[self json:[self.commandPath stringByAppendingString:@".receipt.json"]]
                name:[NSString stringWithFormat:@"photo-region-%lu-input",(unsigned long)number]];
            [self controller:@"neutral"];[self settle];
            [self artworkCapture:[NSString stringWithFormat:@"photo-region-%lu-world-selection",(unsigned long)number]
                expectedSources:[NSSet set]];
            NSUInteger offset=[self artworkTraceOffset];
            [self.game.buttons[@"game-action-2048"] tap];[self settle];
            NSNumber* ordinal=region[@"steps"][0][@"ordinal"];
            [self waitForFreshArtworkHeading:[NSString stringWithFormat:@"Panel-HubScreenNames-%@",ordinal]
                afterOffset:offset];
            emittedHeadingMask|=1u<<ordinal.unsignedIntegerValue;
        }
        for(NSDictionary* step in region[@"steps"]) {
            NSNumber* ordinal=step[@"ordinal"];
            XCTAssertFalse([visited containsObject:ordinal]);
            for(NSDictionary* move in step[@"route"]) {
                NSUInteger offset=[self artworkTraceOffset];
                [self controller:move[@"command"]];
                [self attach:[self json:[self.commandPath stringByAppendingString:@".receipt.json"]]
                    name:[NSString stringWithFormat:@"photo-%@-move-to-%@",ordinal,move[@"ordinal"]]];
                [self controller:@"neutral"];[self settle];
                // The runtime's trace intentionally logs each key/text/builtin/
                // context tuple once. An intermediate return to an already
                // visited node cannot emit another identical trace row. Require
                // fresh evidence for every new node, including the final target;
                // do not mistake the trace's deduplication for failed movement.
                NSNumber* movedOrdinal=move[@"ordinal"];
                XCTAssertLessThan(movedOrdinal.unsignedIntegerValue,24u);
                if(layoutQA) {
                    [self waitForNativeMapOrdinal:movedOrdinal];
                } else if(!(emittedHeadingMask&(1u<<movedOrdinal.unsignedIntegerValue))) {
                    [self waitForFreshArtworkHeading:[NSString stringWithFormat:@"Panel-HubScreenNames-%@",move[@"ordinal"]]
                        afterOffset:offset];
                }
                emittedHeadingMask|=1u<<movedOrdinal.unsignedIntegerValue;
            }
            if(layoutQA&&!(layoutTargets&(1u<<ordinal.unsignedIntegerValue))) {
                // Traversal is required by the original selection graph, but
                // artwork already passed. Capture only changed-layout cases.
            } else if(reuse && [plan[@"reuse_phone_ordinals"] containsObject:ordinal]) {
                [self attach:@{@"ordinal":ordinal,@"retained_evidence":plan[@"retained_phone_observation"]}
                    name:[NSString stringWithFormat:@"photo-%@-retained-prefix",ordinal]];
            } else {
                NSString* name=[NSString stringWithFormat:@"photo-%02lu",(unsigned long)ordinal.unsignedIntegerValue];
                NSSet* expected=[NSSet setWithArray:step[@"source_keys"]];
                [self artworkCapture:[name stringByAppendingString:@"-overview"] expectedSources:expected];
                if(layoutQA)[self assertNativeMapLayout:YES ordinal:ordinal];
                [self.game.buttons[@"game-action-2048"] tap];[self settle];
                [self artworkCapture:[name stringByAppendingString:@"-detail"] expectedSources:expected];
                if(layoutQA)[self assertNativeMapLayout:NO ordinal:nil];
                // Confirm is deliberately never sent from detail: it enters a level.
                [self.game.buttons[@"game-back"] tap];[self settle];
                [self artworkCapture:[name stringByAppendingString:@"-return"] expectedSources:expected];
                if(layoutQA)[self assertNativeMapLayout:YES ordinal:ordinal];
            }
            [visited addObject:ordinal];
        }
        [self.game.buttons[@"game-back"] tap];[self settle];
        [self artworkCapture:[NSString stringWithFormat:@"photo-region-%lu-exit",(unsigned long)number]
            expectedSources:[NSSet set]];
        if(layoutQA)[self assertNativeMapLayout:NO ordinal:nil];
    }
    XCTAssertEqual(visited.count,24u);
    XCTAssertEqualObjects([self hash:[NSData dataWithContentsOfFile:save]],[self authorizedPhotoFixtureHash]);
    [self attach:@{@"visited_ordinals":[visited.allObjects sortedArrayUsingSelector:@selector(compare:)],
        @"reused_phone_prefix":@(reuse),@"map_layout_assertions":@(layoutQA)} name:@"complete-photo-route-coverage"];
    [self.game.buttons[@"native-pause"] tap];
}
- (void)assertNativeMapLayout:(BOOL)enabled ordinal:(NSNumber*)ordinal {
    NSDictionary* state=[self json:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"]];
    NSDictionary* map=state[@"native_world_map_layout"];
    XCTAssertNotNil(map);
    XCTAssertEqualObjects(map[@"enabled"],@(enabled),@"%@",map);
    if(enabled) {
        XCTAssertEqualObjects(map[@"admission"],@"complete-regional-overview");
        XCTAssertEqualObjects(map[@"selected_ordinal"],ordinal);
        XCTAssertEqualObjects(map[@"source_vertices_immutable"],@YES);
    }
}
- (void)waitForNativeMapOrdinal:(NSNumber*)ordinal {
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:12];
    while(deadline.timeIntervalSinceNow>0) {
        NSDictionary* state=[self json:[self.container stringByAppendingPathComponent:@"Documents/Diagnostics/interactive-state.json"]];
        NSDictionary* map=state[@"native_world_map_layout"];
        if([map[@"enabled"] boolValue]&&[map[@"selected_ordinal"] isEqual:ordinal])return;
        [NSThread sleepForTimeInterval:.1];
    }
    XCTFail(@"The live source-bound map did not select ordinal %@",ordinal);
}
@end
