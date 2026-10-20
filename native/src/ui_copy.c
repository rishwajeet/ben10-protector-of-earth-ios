#include "protector/ui_copy.h"

/* The source keys and fingerprints come from native-ux-source-v3. Replacement
 * copy is authored for the native action names. Preserve the source line-break
 * control where needed; never insert controller glyph bytes. */
static const ProtectorUICopyRule rules[] = {
    {"Platform-PC-42", 7, 0x85b014bb021c0b87ull, "Confirm"},
    {"Panel-LoadGame-1", 11, 0x91360b8f1c8b456aull, "Confirm"},
    {"Panel-LoadGame-2", 6, 0x0a49f299dd1623bfull, "Back"},
    /* ConceptArt uses its own case-sensitive keys, not LoadGame's record. */
    {"panel-UnlockableScreen-3", 6, 0x0a49f299dd1623bfull, "Back"},
    /* The four other Extras collections use a distinct case-sensitive key. */
    {"Panel-UnlockableScreen-3", 6, 0x0a49f299dd1623bfull, "Back"},
    {"Panel-UpgradeScreen-2", 6, 0x0a49f299dd1623bfull, "Back"},
    {"Panel-UpgradeScreen-1", 14, 0xbc8f023a28b738c4ull, "UNLOCK MOVE!"},
    {"Panel-UnlockableScreen-1", 17, 0x837649739817ff67ull, "Activate Secret"},
    {"Panel-UnlockableScreen-2", 19, 0x91c075a573760f26ull, "Deactivate Secret"},
    {"Panel-UnlockableScreen-14", 10, 0x211734c55e5c3465ull, "Continue"},
    {"Panel-UnlockableScreen-15", 12, 0xd081b5fb1bf31afbull, "Enter Code"},
    {"Platform-PC-44", 52, 0x37a9f4e779ec8d09ull,
        "Enable, then use Camera in Pause during play."},
    {"panel-UnlockableScreen-9", 13, 0x167fe6915330f317ull, "Open Art"},
    {"Panel-UnlockableScreen-17", 12, 0x55907d8d721e9c32ull, "Play Movie"},
    {"panel-UnlockableScreen-18", 16, 0xaba6f074e0e4d34eull, "View Character"},
    /* Shared horizontal navigation indicators in ConceptArt, EnterCheatCode,
     * MoveList and UpgradeMenu: retain one-byte allocation and source font.
     * Key 7 is the left indicator; text lookup order is not draw order. */
    {"Panel-Buttons-7", 1, 0xaf63ba4c8601b2c6ull, "<"},
    {"Panel-Buttons-8", 1, 0xaf63c54c8601c577ull, ">"},
    {"Panel-LoadGame-13", 8, 0x67810595c3facafcull, "Confirm"},
    {"Panel-LoadGame-10", 12, 0x7625417bba0612caull, "Confirm"},
    {"Panel-LoadGame-22", 19, 0x22d020d52171b645ull, "Back: No autosave"},
    {"Panel-Options-16", 10, 0x211734c55e5c3465ull, "Confirm"},
    /* Shared confirmation labels: retain their meanings and allocation sizes,
     * removing only the source-verified console button glyphs. */
    {"Panel-HubScreen-17", 5, 0x87421fa3221b65efull, "Yes"},
    {"Panel-HubScreen-18", 4, 0xa2f44390e7ca0624ull, "No"},
    /* PauseMenu/HubPauseMenu use a distinct No glyph; level results own a
     * separate Continue record. Strip only the verified button prefixes,
     * preserving the authored choice and consequence text. */
    {"Panel-HubScreen-19", 4, 0x017ced889050d6a5ull, "No"},
    {"Panel-EndOfLevelStats-3", 10, 0x211734c55e5c3465ull, "Continue"},
    {"Platform-PC-41", 6, 0xa7032ec4407da225ull, "Menu"},
    {"Panel-HubScreen-4", 9, 0x7fcd67c01408e1eeull, "Zoom In"},
    {"Panel-HubScreen-2", 10, 0x8e2249231818fd24ull, "Zoom Out"},
    {"Panel-HubScreen-5", 17, 0x087ad7450a5e65444ull, "Replay Location"},
    {"Panel-HubScreen-21", 10, 0x20d4816200a3418full, "Zoom Out"},
    {"Panel-HubScreen-6", 15, 0x3b8b0b3dca9de150ull, "Next Location"},
    {"Panel-HubScreen-8", 23, 0xcd1c94b1a3c928b4ull, "Play Secret Challenge"},
    {"Panel-HubScreen-7", 15, 0xed5ac16473243139ull, "Play Location"},
    {"Platform-Wii-1", 66, 0x866b72ee1ec4b562ull,
        "Saving progress. Keep the app open until saving finishes."},
    /* Exact English storage/error records. Preserve source choices and save
     * consequences; no console memory manager, SD card or hardware manual.
     * Wii-8 alone is paired with the native GCResetToIPL exit boundary.
     * The identically worded PSP-8 has a different source flow; do not alias it. */
    {"Platform-Wii-2", 170, 0x28169447096ba576ull,
        "There is not enough space to create save data. Free space on this device, then try again."},
    {"Platform-Wii-3", 134, 0xa405bd3934111c74ull,
        "There is not enough space to save. Free space on this device, then try again."},
    {"Platform-Wii-5", 102, 0x6232401c06e63036ull,
        "Save storage could not be read. End the game, then reopen it to try again."},
    {"Platform-Wii-6", 31, 0x76ccd8918be5e52bull,
        "Save storage was busy."},
    {"Platform-Wii-8", 29, 0x000a3d0321c3ebf5ull, "End Game"},
    {"Platform-PSP-2", 170, 0x28169447096ba576ull,
        "There is not enough space to create save data. Free space on this device, then try again."},
    {"Platform-PSP-3", 134, 0xa405bd3934111c74ull,
        "There is not enough space to save. Free space on this device, then try again."},
    {"Platform-PSP-5", 102, 0x6232401c06e63036ull,
        "Save storage could not be read. Reopen the game to try again."},
    {"Platform-PSP-6", 31, 0x76ccd8918be5e52bull, "Save storage was busy."},
    {"Platform-Sony-3", 134, 0xa405bd3934111c74ull,
        "There is not enough space to save. Free space on this device, then try again."},
    {"Platform-Sony-20", 20, 0xf09416d62c33bd79ull, "Continue"},
    {"Platform-PSP-20", 20, 0xf09416d62c33bd79ull, "Continue"},
    {"Platform-GameCube-26", 94, 0x7e8c626bad05e92dull,
        "Game data could not be read. Check the installed game files before trying again."},
    {"Platform-Sony-26", 94, 0x7e8c626bad05e92dull,
        "Game data could not be read. Check the installed game files before trying again."},
    {"Platform-PSP-26", 94, 0x7e8c626bad05e92dull,
        "Game data could not be read. Check the installed game files before trying again."},
    {"Front End UI-Load Tips-7", 74, 0x4334d8fc7bfb13a9ull,
        "Open Pause for touch settings, the controls guide, or the game menu."},
    {"Platform-GameCube-21", 83, 0x478209fb2332ba12ull,
        "Native controls are ready.\x1fUse Jump to continue."},
    {"Platform-Sony-21", 83, 0x478209fb2332ba12ull,
        "Native controls are ready.\x1fUse Jump to continue."},
    {"Platform-PSP-21", 83, 0x478209fb2332ba12ull,
        "Native controls are ready.\x1fUse Jump to continue."},
    {"Platform-GameCube-22", 20, 0x3d67a22b76098c5cull, "Jump to continue."},
    {"Platform-Sony-22", 20, 0x3d67a22b76098c5cull, "Jump to continue."},
    {"Platform-PSP-22", 20, 0x3d67a22b76098c5cull, "Jump to continue."},
    {"Platform-PC-101", 36, 0xa6dce24781dfd802ull, "Use Left / Right to choose an alien."},
    {"Platform-Gamecube-201", 36, 0xa6dce24781dfd802ull, "Use Left / Right to choose an alien."},
    {"Platform-Gamecube-301", 36, 0xa6dce24781dfd802ull, "Use Left / Right to choose an alien."},
    {"Platform-PC-102", 21, 0xfa014eb482386226ull, "Use Transform."},
    {"Platform-Gamecube-202", 21, 0xfa014eb482386226ull, "Use Transform."},
    {"Platform-Gamecube-302", 21, 0xfa014eb482386226ull, "Use Transform."},
    /* Tutorial bodies use the native action vocabulary, not the glyph's
     * platform-dependent shape. Each authored control-family variant keeps
     * its own source fingerprint; there is no blanket byte substitution. */
    {"Platform-PC-103", 76, 0x48cd5c6f9ae4ccd6ull,
        "Use Attack for light attacks, Heavy for heavy attacks, and Special."},
    {"Platform-Gamecube-203", 76, 0x56b5679596236fabull,
        "Use Attack for light attacks, Heavy for heavy attacks, and Special."},
    {"Platform-Gamecube-303", 76, 0x99ebcca3852c5071ull,
        "Use Attack for light attacks, Heavy for heavy attacks, and Special."},
    {"Platform-PC-107", 65, 0xa47f72380ef78a18ull,
        "Hold Block to stop most enemy attacks."},
    {"Platform-Gamecube-207", 65, 0x67add7762ab864c5ull,
        "Hold Block to stop most enemy attacks."},
    {"Platform-Gamecube-307", 65, 0xa47f72380ef78a18ull,
        "Hold Block to stop most enemy attacks."},
    {"Platform-PC-109", 95, 0x8221ed1858217ea0ull,
        "As Heatblast, press Jump twice to double-jump. Hold Jump in the air to glide."},
    {"Platform-Gamecube-209", 95, 0x8221ed1858217ea0ull,
        "As Heatblast, press Jump twice to double-jump. Hold Jump in the air to glide."},
    {"Platform-Gamecube-309", 95, 0xd3aa96e2759c498eull,
        "As Heatblast, press Jump twice to double-jump. Hold Jump in the air to glide."},
    /* FourArms tests normalized engine input 0x4000, not raw KPAD C.
     * Original normalization maps raw Down (native Special) to that bit.
     * See tools/verify_fourarms_grab_source.py; do not infer from glyph 6. */
    {"Platform-PC-112", 102, 0xbae1032052accd53ull,
        "As Four Arms, stand in front of the rock. Hold Special to grab it, then move to push."},
    {"Platform-Gamecube-212", 102, 0xbae1032052accd53ull,
        "As Four Arms, stand in front of the rock. Hold Special to grab it, then move to push."},
    {"Platform-Gamecube-312", 102, 0xbae1032052accd53ull,
        "As Four Arms, stand in front of the rock. Hold Special to grab it, then move to push."},
    {"Platform-PC-115", 83, 0x7d4b3eaa2c2e5bdbull,
        "As Ben, face the robot's hand and use Attack to start the mini-game."},
    {"Platform-Gamecube-215", 83, 0x7d4b3eaa2c2e5bdbull,
        "As Ben, face the robot's hand and use Attack to start the mini-game."},
    {"Platform-Gamecube-315", 83, 0x7d4b3eaa2c2e5bdbull,
        "As Ben, face the robot's hand and use Attack to start the mini-game."},
    {"Platform-PC-117", 46, 0xb8227b0a32d672b8ull,
        "Use Special, then move to steer XLR8."},
    {"Platform-Gamecube-217", 46, 0xec3f02990718baa3ull,
        "Use Special, then move to steer XLR8."},
    {"Platform-Gamecube-317", 46, 0xca93f39799d7c7aaull,
        "Use Special, then move to steer XLR8."},
    {"Platform-PC-118", 103, 0xcfccf3dac9eb68e7ull,
        "Use Special and move to draw the cursor. Dash through the door before it closes."},
    {"Platform-Gamecube-218", 103, 0x5be3b57d675b44c2ull,
        "Use Special and move to draw the cursor. Dash through the door before it closes."},
    {"Platform-Gamecube-318", 103, 0xb45ed7ede5168c55ull,
        "Use Special and move to draw the cursor. Dash through the door before it closes."},
    {"Platform-PC-120", 63, 0x3eb9bcde3a8d8948ull,
        "Aim at the ramp. Use Special to charge up and catapult up it."},
    {"Platform-Gamecube-220", 63, 0x4b029c9498c3890bull,
        "Aim at the ramp. Use Special to charge up and catapult up it."},
    {"Platform-Gamecube-320", 63, 0x8750b0d973892bf6ull,
        "Aim at the ramp. Use Special to charge up and catapult up it."},
    {"Platform-PC-122", 56, 0xaa202fa81a8846b9ull,
        "Near a grapple point, hold Jump to grapple."},
    {"Platform-Gamecube-222", 56, 0xaa202fa81a8846b9ull,
        "Near a grapple point, hold Jump to grapple."},
    {"Platform-Gamecube-322", 56, 0x91c7682b72da081aull,
        "Near a grapple point, hold Jump to grapple."},
    {"Platform-PC-125", 48, 0x51ae39525f20d95full,
        "Use Transform to change back to Ben."},
    {"Platform-Gamecube-225", 48, 0x51ae39525f20d95full,
        "Use Transform to change back to Ben."},
    {"Platform-Gamecube-325", 48, 0x51ae39525f20d95full,
        "Use Transform to change back to Ben."},
    /* The exact pointer helper is now presented by the native, device-
     * specific QTE cue. Its old fixed baseline crosses source targets.
     * Keep the target and its acceptance geometry entirely unchanged. */
    {"Platform-Gamecube-123", 57, 0x1c3ecba726937fe5ull,
        ""},
    {"Platform-Gamecube-128", 86, 0x92edd0db4f11712cull,
        "Move the aiming reticle onto the target to win the mini-game."},
    {"Platform-Gamecube-228", 86, 0x92edd0db4f11712cull,
        "Move the aiming reticle onto the target to win the mini-game."},
    {"Platform-Gamecube-328", 86, 0x92edd0db4f11712cull,
        "Move the aiming reticle onto the target to win the mini-game."},
};

const ProtectorUICopyRule* protector_ui_copy_rules(size_t* count) {
    if (count) *count = sizeof(rules) / sizeof(rules[0]);
    return rules;
}

const ProtectorUICopyRule* protector_ui_copy_match(const ProtectorUIText* text) {
    if (!text || !text->key_available || text->language_slot != 1 ||
        !memchr(text->key, 0, sizeof(text->key)) ||
        text->text_size >= sizeof(text->text) || text->text[text->text_size] != 0) return NULL;
    for (size_t index = 0; index < sizeof(rules) / sizeof(rules[0]); ++index) {
        const ProtectorUICopyRule* rule = &rules[index];
        if (strcmp(rule->key, text->key) || rule->source_size != text->text_size) continue;
        u64 hash = 14695981039346656037ull;
        for (u32 byte = 0; byte < text->text_size; ++byte)
            hash = (hash ^ text->text[byte]) * 1099511628211ull;
        return hash == rule->source_fnv1a64 ? rule : NULL;
    }
    return NULL;
}
