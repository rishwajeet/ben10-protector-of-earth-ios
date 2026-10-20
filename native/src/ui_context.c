#include "protector/ui_context.h"
#include "protector/script_flow.h"
#include <stdatomic.h>
#include <stdio.h>

/* RBNEG9 99_91.gcs front end, 99_96.gcs in-game Menu and 99_99.gcs loading:
 * full normalized script blocks, not copied bytecode.
 * from_offset is a DisplayText/Right return; to_offset is unused by this reader.
 * The source verifier checks block identity, every relocation and call site. */
static const u32 title_pointers[] = {
    0x4174, 0x460c, 0x4680, 0x46b4, 0x46d4, 0x4754,
    0x4764, 0x47c4, 0x4860, 0x48ac, 0x4920, 0x495c,
};
static const u32 menu_pointers[] = {
    0x5014, 0x508c, 0x50e4, 0x5190, 0x51b4, 0x52f8, 0x5334, 0x5364,
    0x5394, 0x5af4, 0x5b40, 0x5bb8, 0x5bd8, 0x5bfc, 0x5c38, 0x5cf0,
    0x5d3c, 0x5d4c, 0x6164, 0x62a0, 0x6300, 0x6330, 0x6358, 0x6388,
    0x63b8, 0x63e0, 0x641c, 0x644c, 0x647c, 0x64ac, 0x64dc, 0x6508,
    0x652c, 0x6550, 0x6574, 0x65a4, 0x65c8, 0x65ec, 0x6610, 0x6634,
    0x6654, 0x6950, 0x69f4, 0x6a84, 0x6ad4, 0x6b34,
};
static const u32 new_game_pointers[] = {
    0x88c8, 0x896c, 0x89a4, 0x89e8, 0x8a30, 0x8b2c, 0x8b54, 0x8bc0,
    0x8c2c, 0x8c9c, 0x8dc8, 0x8df0, 0x8e64, 0x8ed4, 0x8f44, 0x9114,
    0x9128, 0x9144, 0x916c, 0x9198, 0x91b4, 0x91dc, 0x91f0, 0x9220,
    0x9250, 0x9290, 0x92e4, 0x9320, 0x9368, 0x93b0, 0x93dc, 0x9434,
    0x9458, 0x947c, 0x94a0, 0x94c4, 0x94e8, 0x950c, 0x9530, 0x9554,
    0x9578, 0x9724, 0x97ec, 0x9830, 0x9898, 0x99fc, 0x9a44, 0x9a70,
    0x9aa4, 0x9aac, 0x9ae4, 0x9c68, 0x9cd4, 0x9d24, 0x9d4c, 0x9d74,
    0x9de4, 0x9e68, 0x9e74, 0x9e80, 0x9e8c, 0x9e98, 0x9ea4, 0x9eb0,
    0x9ebc, 0x9ec8, 0x9ed4, 0x9ee0, 0x9eec, 0x9ef8, 0x9f04, 0x9f10,
    0x9f1c, 0x9f28, 0x9f34, 0x9f40, 0x9f4c, 0x9f58, 0x9f64, 0x9f70,
    0x9f7c, 0x9f88, 0x9ff8, 0xa040, 0xa0e8, 0xa270, 0xa2a0, 0xa350,
    0xa390, 0xa404, 0xa430,
};
static const u32 save_slot_pointers[] = {
    0xfd04, 0xfd44, 0xfd98, 0xfdbc, 0xfde0, 0xfe04, 0xfe28, 0xfe4c,
    0xfe70, 0xfe94, 0xfeb8, 0xfedc, 0xfff8, 0x100d4, 0x1013c, 0x101a4,
    0x101d0, 0x101fc, 0x10224, 0x10394, 0x103c0, 0x10404, 0x10438, 0x10464,
    0x104bc, 0x104d8, 0x104f4, 0x10520, 0x1053c, 0x10558, 0x10598, 0x1063c,
    0x1068c,
};
static const u32 load_game_pointers[] = {
    0x12fdc, 0x13080, 0x130b8, 0x130fc, 0x13144, 0x13240, 0x13268, 0x132b0,
    0x132f8, 0x13344, 0x133f0, 0x13414, 0x13438, 0x1345c, 0x13480, 0x134a4,
    0x134c8, 0x134ec, 0x13510, 0x13534, 0x136e0, 0x137a8, 0x137f0, 0x13854,
    0x1391c, 0x13964, 0x13990, 0x139b4, 0x13a98, 0x13adc, 0x13c04, 0x13c10,
    0x13c1c, 0x13c28, 0x13c34, 0x13c40, 0x13c4c, 0x13c58, 0x13c64, 0x13c70,
    0x13c7c, 0x13c88, 0x13c94, 0x13ca0, 0x13cac, 0x13cb8, 0x13cc4, 0x13cd0,
    0x13cdc, 0x13ce8, 0x13cf4, 0x13d00, 0x13d0c, 0x13d18, 0x13d24, 0x13d98,
    0x13dc8, 0x13e38, 0x13e7c, 0x13eb8,
};
static const u32 options_pointers[] = {
    0x1453c, 0x1458c, 0x14598, 0x145a4, 0x145b0, 0x145bc, 0x145c8, 0x145d4,
    0x14834, 0x1486c, 0x148b0, 0x148f8, 0x14ae8, 0x14b2c, 0x14ba8, 0x14be8,
    0x14c1c, 0x14c5c, 0x14c9c, 0x14cc4, 0x14cf8, 0x14d20, 0x14d68, 0x14d90,
    0x14dd0, 0x14e00, 0x14e28, 0x14e64, 0x14e8c, 0x14ec0, 0x14f18, 0x14f44,
    0x14f68, 0x1502c, 0x15060, 0x150b0, 0x151d0, 0x151e8, 0x15284, 0x152a8,
    0x152c0, 0x1542c, 0x15480, 0x15654,
};
static const u32 audio_options_pointers[] = {
    0x1572c, 0x1577c, 0x15788, 0x15794, 0x157a0, 0x157ac, 0x157b8, 0x157c4,
    0x15aa0, 0x15b00, 0x15bb0, 0x15bdc, 0x15c1c, 0x15c98, 0x15cc4, 0x15d04,
    0x15d80, 0x15dac, 0x15dec, 0x15e68, 0x15e94, 0x15ed4, 0x15f40, 0x15f6c,
    0x15fac, 0x15fd4, 0x15ffc, 0x161e8, 0x16210, 0x16234, 0x1625c, 0x164d8,
    0x16504, 0x16528, 0x16550, 0x16574, 0x16594, 0x165bc, 0x165e0, 0x16604,
    0x16624, 0x166c0, 0x166e4, 0x16708, 0x16734, 0x167f0,
};
static const u32 in_game_menu_pointers[] = {0x1033c};
/* Complete Controller block, including selector/Continue/cleanup handlers. */
static const u32 controller_guide_pointers[] = {
    0x16d68, 0x16f6c, 0x16fa4, 0x16fdc, 0x17014, 0x1704c, 0x17084, 0x170bc,
    0x170f4, 0x1712c, 0x17164, 0x1719c, 0x171d4, 0x1720c, 0x1723c, 0x17278,
    0x172b0, 0x172e8, 0x17320, 0x17358, 0x17390, 0x173c8, 0x17400, 0x17438,
    0x17480, 0x174b8, 0x174f0, 0x17528, 0x17558, 0x17594, 0x175cc, 0x17604,
    0x1763c, 0x17674, 0x176ac, 0x176e4, 0x1771c, 0x17754, 0x1779c, 0x177d4,
    0x1780c, 0x17844, 0x17874, 0x178ac, 0x178c8, 0x17ac0, 0x17b40,
};
static const u32 init_system_pointers[] = {
    0x86938, 0x8698c, 0x86998, 0x869a4, 0x869b0, 0x869bc, 0x869c8, 0x869d4,
    0x86cac, 0x86cb8, 0x86cc4, 0x874dc, 0x87584, 0x87628, 0x87b30, 0x87b58,
    0x87ba0, 0x87be8, 0x87c34, 0x87cf8, 0x87d30, 0x87d74, 0x87dbc, 0x87ed4,
    0x87ef0, 0x87f0c, 0x87f24, 0x87f3c, 0x87f6c, 0x87f84, 0x88364, 0x88394,
    0x8842c, 0x88468, 0x8851c, 0x88544, 0x88620, 0x888a0, 0x888d4,
    0x88b30, 0x88b40, 0x88b54, 0x88b68, 0x88c5c, 0x88c6c, 0x88c90, 0x88d0c,
    0x88d20, 0x88d34, 0x88d48, 0x88dcc, 0x88ddc, 0x88df8, 0x88e38, 0x88e4c,
    0x88e6c, 0x88e84, 0x88e9c, 0x88eb8, 0x88ee0, 0x88ef8, 0x88f10, 0x88fbc,
    0x88fe8, 0x88ff8, 0x89008, 0x89018, 0x89028, 0x89038, 0x89048, 0x89058,
    0x890cc, 0x890dc, 0x89114, 0x89130, 0x89150, 0x8918c, 0x891ac, 0x891cc,
    0x891f0, 0x89210, 0x89230, 0x89250, 0x8927c,
};
/* 99_04.gcs world map: include handlers after the main definition body. */
static const u32 map_pointers[] = {
    0x10608, 0x106ec, 0x107c8, 0x108a4, 0x108fc, 0x10a10, 0x10a38, 0x10aac,
    0x10b1c, 0x10b8c, 0x10c68, 0x10ca0, 0x10ce4, 0x10d2c, 0x111dc, 0x11214,
    0x11228, 0x11244, 0x11264, 0x1127c, 0x11298, 0x112b4, 0x112d4, 0x112f4,
    0x11314, 0x11334, 0x1135c, 0x11370, 0x11390, 0x113ac, 0x113c8, 0x113e8,
    0x11408, 0x11430, 0x11444, 0x11464, 0x11480, 0x1149c, 0x114bc, 0x114d4,
    0x114f4, 0x1151c, 0x11530, 0x11550, 0x11570, 0x11590, 0x115b0, 0x115d0,
    0x115f4, 0x11608, 0x11628, 0x11644, 0x11664, 0x1167c, 0x1169c, 0x116b0,
    0x116cc, 0x116ec, 0x1170c, 0x11724, 0x11744, 0x11760, 0x11780, 0x117a0,
    0x117c0, 0x117e4, 0x117f8, 0x11818, 0x11834, 0x11850, 0x11878, 0x1188c,
    0x118ac, 0x118c8, 0x118e4, 0x11904, 0x11920, 0x11940, 0x1195c, 0x11978,
    0x11998, 0x119c0, 0x119d4, 0x119f4, 0x11a14, 0x11a2c, 0x11a54, 0x11a68,
    0x11a88, 0x11aa8, 0x11ac8, 0x11ae8, 0x11b10, 0x11b24, 0x11b44, 0x11b64,
    0x11b80, 0x11b9c, 0x11bb8, 0x11bd8, 0x11bf8, 0x11c18, 0x11c3c, 0x11c50,
    0x11c6c, 0x11c8c, 0x11ca8, 0x11ccc, 0x11ce0, 0x11d00, 0x11d28, 0x11d3c,
    0x11d58, 0x11d78, 0x11d98, 0x11db8, 0x11dd8, 0x11df8, 0x11e18, 0x11e38,
    0x11e58, 0x11e7c, 0x11e90, 0x11eb0, 0x11ecc, 0x11eec, 0x11f08, 0x11f28,
    0x11f50, 0x11f64, 0x11f84, 0x11fa0, 0x11fc8, 0x11fdc, 0x11ffc, 0x12018,
    0x12034, 0x12050, 0x12078, 0x1208c, 0x120a8, 0x120c8, 0x120e4, 0x12104,
    0x12124, 0x12144, 0x12160, 0x12180, 0x121a0, 0x121c8, 0x121dc, 0x121f4,
    0x1221c, 0x12230, 0x12258, 0x1226c, 0x12284, 0x122a0, 0x122b8, 0x122d8,
    0x122f8, 0x12314, 0x12334, 0x1235c, 0x12370, 0x1238c, 0x123ac, 0x123cc,
    0x123ec, 0x12408, 0x12428, 0x12450, 0x12464, 0x12480, 0x124a0, 0x124c0,
    0x124e4, 0x124f8, 0x12510, 0x12530, 0x12550, 0x12570, 0x1258c, 0x125b4,
    0x125c8, 0x125e8, 0x12604, 0x12624, 0x12644, 0x12664, 0x12684, 0x126ac,
    0x126c0, 0x126e0, 0x12700, 0x12720, 0x12740, 0x12768, 0x1277c, 0x1279c,
    0x127bc, 0x127d8, 0x127fc, 0x12810, 0x12830, 0x1284c, 0x1286c, 0x1288c,
    0x128b4, 0x128c8, 0x128e8, 0x12910, 0x12924, 0x1294c, 0x12960, 0x1297c,
    0x12998, 0x129b8, 0x129d4, 0x129f4, 0x12a14, 0x12a3c, 0x12a50, 0x12a70,
    0x12a90, 0x12ab0, 0x12ad0, 0x12af0, 0x12b0c, 0x12b28, 0x12b50, 0x12b64,
    0x12b80, 0x12ba0, 0x12bbc, 0x12be0, 0x12bf4, 0x12c10, 0x12c30, 0x12c50,
    0x12c70, 0x12c98, 0x12cac, 0x12ccc, 0x12cec, 0x12d08, 0x12d30, 0x12d44,
    0x12d5c, 0x12d7c, 0x12d94, 0x12db4, 0x12ddc, 0x12df0, 0x12e0c, 0x12e28,
    0x12e48, 0x12e68, 0x12e90, 0x12ea4, 0x12ec0, 0x12edc, 0x12efc, 0x12f1c,
    0x12f38, 0x12f58, 0x12f78, 0x12fa0, 0x12fb4, 0x12fd4, 0x12ff0, 0x13018,
    0x1302c, 0x13048, 0x13064, 0x1307c, 0x130a4, 0x130b8, 0x130d8, 0x130f8,
    0x13118, 0x13134, 0x1315c, 0x13170, 0x13190, 0x131b0, 0x131d0, 0x131ec,
    0x13214, 0x13228, 0x13248, 0x13264, 0x1328c, 0x132a0, 0x132bc, 0x132d8,
    0x13300, 0x13314, 0x13330, 0x1334c, 0x13374, 0x13388, 0x133a4, 0x133c0,
    0x133e0, 0x133fc, 0x1341c, 0x13440, 0x13454, 0x13478, 0x1348c, 0x134a8,
    0x134c8, 0x134ec, 0x13500, 0x1351c, 0x1353c, 0x13558, 0x13574, 0x135a0,
    0x13648, 0x136f4, 0x1402c, 0x14060, 0x140f8, 0x14108, 0x14f40, 0x14f64,
    0x14f88, 0x15490, 0x154bc, 0x154e8, 0x15514, 0x1572c, 0x15744, 0x157e0,
    0x157f4, 0x1580c, 0x15820, 0x15830, 0x15840, 0x15858, 0x1586c, 0x15884,
    0x15898, 0x158b0, 0x158c4, 0x158dc, 0x158f0, 0x15908, 0x1591c, 0x15934,
    0x15948, 0x15960, 0x15974, 0x1598c, 0x159a0, 0x159b8, 0x159cc, 0x159e4,
    0x159f8, 0x15a10, 0x15a24, 0x15a3c, 0x15a50, 0x15a68, 0x15a7c, 0x15a94,
    0x15aa8, 0x15ac0, 0x15ad4, 0x15aec, 0x15b00, 0x15b18, 0x15b2c, 0x15b44,
    0x15b58, 0x15b70, 0x15b84, 0x15b9c, 0x15bb0, 0x15bc8, 0x15bdc, 0x15bf4,
    0x15c08, 0x15d04, 0x15da8, 0x15dd4, 0x15e88, 0x15eb0, 0x15edc, 0x15f14,
    0x15f4c, 0x15fcc, 0x16064, 0x160a8, 0x160dc, 0x16110, 0x16144, 0x16178,
    0x161ac, 0x161e0, 0x16214, 0x16248, 0x1627c, 0x163c8, 0x16410, 0x16518,
    0x1653c, 0x16570, 0x16684, 0x166a8, 0x166e4, 0x16708, 0x16764, 0x16840,
    0x16864, 0x16898, 0x16988, 0x16ce0, 0x16cec, 0x16cf8, 0x16d04, 0x16d10,
    0x16d1c, 0x16d28, 0x16d34, 0x16d40, 0x16d4c, 0x16d58, 0x16d64, 0x16d70,
    0x16d7c, 0x16d88, 0x16d94, 0x16da0, 0x16dac, 0x16db8, 0x16dc4, 0x16dd0,
    0x16ddc, 0x16de8, 0x16df4, 0x16e00, 0x16e88, 0x16eec, 0x16f68, 0x16fd0,
    0x173e8, 0x17418, 0x17548, 0x17578, 0x17624, 0x17638, 0x1764c, 0x17664,
    0x17684, 0x176a0, 0x17710, 0x17744, 0x177cc, 0x177d8, 0x177e4, 0x177f0,
    0x177fc, 0x17818, 0x17824, 0x17830, 0x1783c, 0x17848, 0x17854, 0x17860,
    0x1786c, 0x17878, 0x17884, 0x17890, 0x1789c, 0x178a8, 0x178b4, 0x178c0,
    0x178cc, 0x178d8, 0x178e4, 0x178f0, 0x178fc, 0x17908, 0x17914, 0x17920,
    0x1792c, 0x17938, 0x17954, 0x17960, 0x1796c, 0x17978, 0x17984, 0x17990,
    0x1799c, 0x179a8, 0x179b4, 0x179c0, 0x179cc, 0x179d8, 0x179e4, 0x179f0,
    0x179fc, 0x17a08, 0x17a14, 0x17a20, 0x17a2c, 0x17a38, 0x17a44, 0x17a50,
    0x17a5c, 0x17a68, 0x17a74, 0x17a90, 0x17a9c, 0x17aa8, 0x17ab4, 0x17ac0,
    0x17acc, 0x17ad8, 0x17ae4, 0x17af0, 0x17afc, 0x17b08, 0x17b14, 0x17b20,
    0x17b2c, 0x17b38, 0x17b44, 0x17b50, 0x17b5c, 0x17b68, 0x17b74, 0x17b80,
    0x17b8c, 0x17b98, 0x17ba4, 0x17bb0, 0x17bd4, 0x17c0c, 0x17c54, 0x17c78,
    0x17c9c, 0x17cbc, 0x17ce0, 0x17d04, 0x17d28, 0x17d4c, 0x17d6c, 0x17d90,
    0x17db4, 0x17dd8, 0x17dfc, 0x17e1c, 0x17e40, 0x17e64, 0x17e88, 0x17eac,
    0x17ecc, 0x17ef0, 0x17f14, 0x17f34, 0x17f54, 0x17f74, 0x17fa4, 0x17fc8,
    0x17fec, 0x18010, 0x18034, 0x1808c, 0x180c0, 0x180dc, 0x18640, 0x18698,
    0x186b4, 0x186e4, 0x186fc, 0x18714, 0x1872c, 0x18744, 0x1875c, 0x18774,
    0x1878c, 0x187a4, 0x187bc, 0x187d4, 0x187ec, 0x18804, 0x1881c, 0x18834,
    0x1884c, 0x18864, 0x1887c, 0x18894, 0x188ac, 0x188c4, 0x188dc, 0x188f4,
    0x1890c, 0x18928, 0x18944, 0x18964, 0x189e8, 0x18a14, 0x18a48, 0x18ae4,
    0x18b20, 0x18bfc, 0x18cf4, 0x18d04, 0x18f78, 0x1918c, 0x191c8, 0x19400,
    0x194bc, 0x195d8, 0x19868, 0x19924, 0x19a40, 0x19af4, 0x19b10, 0x19ba0,
    0x19bbc, 0x19c18, 0x19c38,
};
/* The three shipped player packages relocate this complete 196-word block.
 * Its short definition is followed by handlers; match the whole block. */
static const u32 death_93_pointers[] = {
    0x33ea24, 0x33ea5c, 0x33ea7c, 0x33ea94, 0x33eab0, 0x33ebf4, 0x33ec0c, 0x33ec64,
};
static const u32 death_94_pointers[] = {
    0x37ed24, 0x37ed5c, 0x37ed7c, 0x37ed94, 0x37edb0, 0x37eef4, 0x37ef0c, 0x37ef64,
};
static const u32 death_95_pointers[] = {
    0x3803e4, 0x38041c, 0x38043c, 0x380454, 0x380470, 0x3805b4, 0x3805cc, 0x380624,
};
/* Hub Menu is a separate packaged copy. Extras/gallery include all handlers,
 * including the full-art Exit branch and both original texture tables. */
static const u32 hub_menu_pointers[] = {0x22004};
static const u32 extras_pointers[] = {
    0x19e8, 0x1b80, 0x1bc4, 0x1c40, 0x1c74, 0x1c9c, 0x1cc4, 0x1ce8,
    0x1d0c, 0x1d34, 0x1d5c, 0x1da4, 0x1dd0, 0x1de4, 0x1e28, 0x1e78,
    0x1eb4, 0x1ef4, 0x1f7c, 0x2008, 0x203c, 0x20f4, 0x2154, 0x2208,
    0x22c0, 0x2378, 0x2414, 0x24ac, 0x258c, 0x2620,
};
static const u32 concept_art_pointers[] = {
    0x1008, 0x141c, 0x1470, 0x14a0, 0x15d4, 0x1610, 0x1660, 0x169c,
    0x16c8, 0x1714, 0x1720, 0x172c, 0x1738, 0x1744, 0x1750, 0x175c,
    0x1768, 0x1774, 0x1780, 0x178c, 0x1798, 0x17a4, 0x17b0, 0x17bc,
    0x17c8, 0x17d4, 0x17e0, 0x17ec, 0x17f8, 0x1804, 0x1810, 0x181c,
    0x1828, 0x1834, 0x1840, 0x184c, 0x1858, 0x1864, 0x1870, 0x187c,
    0x1888, 0x1894, 0x18a0, 0x18ac, 0x18b8, 0x18c4, 0x18d0, 0x18dc,
    0x18e8, 0x18f4, 0x1900, 0x190c, 0x1918, 0x1924, 0x1930, 0x193c,
    0x1948, 0x1964, 0x1970, 0x197c, 0x1988, 0x1994, 0x19a0, 0x19ac,
    0x19b8, 0x19c4, 0x19d0, 0x19dc, 0x19e8, 0x19f4, 0x1a00, 0x1a0c,
    0x1a18, 0x1a24, 0x1a30, 0x1a3c, 0x1a48, 0x1a54, 0x1a60, 0x1a6c,
    0x1a78, 0x1a84, 0x1a90, 0x1a9c, 0x1aa8, 0x1ab4, 0x1ac0, 0x1acc,
    0x1ad8, 0x1ae4, 0x1af0, 0x1afc, 0x1b08, 0x1b14, 0x1b20, 0x1b2c,
    0x1b38, 0x1b44, 0x1b50, 0x1b5c, 0x1b68, 0x1b74, 0x1b80, 0x1b8c,
    0x1b98, 0x1c38, 0x1c60, 0x1ca4, 0x1cdc, 0x1d00, 0x1d2c, 0x1d5c,
    0x1d8c, 0x1db4, 0x1f00, 0x1f68, 0x1f94, 0x20e8, 0x2174,
};
/* Four source-owned collection browsers. Each includes its later handlers;
 * no name-prefix or unlocked-state heuristic admits native controls. */
static const u32 movies_pointers[] = {
    0x313c, 0x33ac, 0x33c0, 0x33d4, 0x33e8, 0x33fc, 0x3410, 0x3424,
    0x3438, 0x344c, 0x3460, 0x3474, 0x3488, 0x349c, 0x34b0, 0x34e8,
    0x3540, 0x3614, 0x372c, 0x3774, 0x37b0, 0x37cc, 0x37e8, 0x3804,
    0x3820, 0x383c, 0x3858, 0x3874, 0x3890, 0x38ac, 0x38c8, 0x38e4,
    0x3900, 0x391c, 0x3980, 0x39c8, 0x3a0c, 0x3a30, 0x3a4c, 0x3a90,
    0x3ae8, 0x3b9c, 0x3bec, 0x3c2c,
};
static const u32 boss_viewer_pointers[] = {
    0x24d668, 0x24d9fc, 0x24da50, 0x24da8c, 0x24db2c, 0x24db5c, 0x24dc54, 0x24dc9c,
    0x24dca8, 0x24dcb4, 0x24dcc0, 0x24dccc, 0x24dcd8, 0x24dce4, 0x24dcf0, 0x24dcfc,
    0x24dd08, 0x24dd14, 0x24ddb8, 0x24ddf8, 0x24de3c, 0x24de60, 0x24dea0, 0x24dec8,
    0x24dfd8, 0x24e040, 0x24e06c, 0x24e14c, 0x24e1ac,
};
static const u32 enemy_viewer_pointers[] = {
    0x318264, 0x3185d4, 0x318628, 0x318664, 0x3186fc, 0x31872c, 0x318830, 0x31887c,
    0x318888, 0x318894, 0x3188a0, 0x3188ac, 0x3188b8, 0x3188c4, 0x3188d0, 0x3188dc,
    0x3188e8, 0x3188f4, 0x318900, 0x31890c, 0x318918, 0x318924, 0x318930, 0x31893c,
    0x318948, 0x318954, 0x318960, 0x31896c, 0x318978, 0x318984, 0x318990, 0x31899c,
    0x3189a8, 0x3189b4, 0x3189c0, 0x3189cc, 0x3189d8, 0x318a80, 0x318ac0, 0x318b04,
    0x318b28, 0x318b68, 0x318bd0, 0x318ca0, 0x318d08, 0x318d34, 0x318e14, 0x318e74,
};
static const u32 hero_viewer_pointers[] = {
    0x1ffaec, 0x1ffe48, 0x1ffe9c, 0x1ffed8, 0x1fff78, 0x1fffa8, 0x2000a0, 0x2000ec,
    0x2000f8, 0x200104, 0x200110, 0x20011c, 0x200128, 0x200134, 0x200140, 0x20014c,
    0x200158, 0x200164, 0x200170, 0x20017c, 0x200188, 0x200194, 0x2001a0, 0x2001ac,
    0x2001b8, 0x2001c4, 0x2001d0, 0x200274, 0x2002b4, 0x2002f8, 0x20031c, 0x20035c,
    0x200384, 0x200494, 0x2004fc, 0x200528, 0x200608, 0x200668,
};
static const u32 secrets_pointers[] = {
    0x3cb4, 0x3ec8, 0x3f08, 0x3f60, 0x4178, 0x4280, 0x42b8, 0x443c,
    0x446c, 0x4490, 0x44a8, 0x4528, 0x4534, 0x4540, 0x454c, 0x4558,
    0x4564, 0x4570, 0x457c, 0x4588, 0x45a0, 0x45ac, 0x45b8, 0x45c4,
    0x45d0, 0x45dc, 0x45e8, 0x45f4, 0x4600, 0x4620, 0x4658, 0x46cc,
    0x46e8, 0x4704, 0x477c, 0x4798, 0x47b4, 0x487c, 0x4910,
};
static const u32 secret_code_pointers[] = {
    0x4960, 0x49a8, 0x49bc, 0x49e0, 0x49f4, 0x4a18, 0x4a2c, 0x4a50,
    0x4a64, 0x4a88, 0x4a9c, 0x4bac, 0x4bf8, 0x4c74, 0x4cac, 0x4e04,
    0x4e10, 0x4e1c, 0x4e28, 0x4e34, 0x4e40, 0x4e4c, 0x4e58, 0x4e64,
    0x4e70, 0x4ec8, 0x4ee0, 0x4efc, 0x4f78, 0x4f8c, 0x4fa8, 0x5010,
    0x502c, 0x5074, 0x50c8, 0x5170, 0x51b4, 0x51d4, 0x51f8, 0x5218,
    0x523c, 0x5260, 0x5334, 0x536c,
};
/* Complete 99_96 Combo List, including selection and teardown handlers. */
static const u32 combo_list_pointers[] = {
    0xe128, 0xe35c, 0xe40c, 0xe418, 0xe424, 0xe430, 0xe43c, 0xe448,
    0xe454, 0xe460, 0xe46c, 0xe478, 0xe484, 0xe490, 0xe49c, 0xe4a8,
    0xe4b4, 0xe4c0, 0xe4cc, 0xe4d8, 0xe4e4, 0xe4f0, 0xe508, 0xe514,
    0xe520, 0xe52c, 0xe538, 0xe544, 0xe550, 0xe55c, 0xe568, 0xe574,
    0xe580, 0xe58c, 0xe598, 0xe5a4, 0xe5b0, 0xe5bc, 0xe5c8, 0xe5d4,
    0xe5e0, 0xe5ec, 0xe604, 0xe610, 0xe61c, 0xe628, 0xe634, 0xe640,
    0xe64c, 0xe658, 0xe664, 0xe670, 0xe67c, 0xe688, 0xe694, 0xe6a0,
    0xe6ac, 0xe6b8, 0xe6c4, 0xe6d0, 0xe6dc, 0xe6e8, 0xe700, 0xe70c,
    0xe718, 0xe724, 0xe730, 0xe73c, 0xe748, 0xe754, 0xe760, 0xe76c,
    0xe778, 0xe784, 0xe790, 0xe79c, 0xe7a8, 0xe7b4, 0xe7c0, 0xe7cc,
    0xe7d8, 0xe7e4, 0xe7fc, 0xe808, 0xe814, 0xe820, 0xe82c, 0xe838,
    0xe844, 0xe850, 0xe85c, 0xe868, 0xe874, 0xe880, 0xe88c, 0xe898,
    0xe8a4, 0xe8b0, 0xe8bc, 0xe8c8, 0xe8d4, 0xe8e0, 0xe9bc, 0xe9f8,
    0xea20, 0xeb94, 0xebb8, 0xec74, 0xec80, 0xec8c, 0xec98, 0xeca4,
    0xecb0, 0xecbc, 0xecc8, 0xecd4, 0xece0, 0xecec, 0xecf8, 0xed04,
    0xed10, 0xed1c, 0xed28, 0xed34, 0xed40, 0xed4c, 0xed6c, 0xed78,
    0xed84, 0xed90, 0xed9c, 0xeda8, 0xedb4, 0xedc0, 0xedcc, 0xedd8,
    0xede4, 0xedf0, 0xedfc, 0xee08, 0xee14, 0xee20, 0xee2c, 0xee38,
    0xee44, 0xee64, 0xee70, 0xee7c, 0xee88, 0xee94, 0xeea0, 0xeeac,
    0xeeb8, 0xeec4, 0xeed0, 0xeedc, 0xeee8, 0xeef4, 0xef00, 0xef0c,
    0xef18, 0xef24, 0xef30, 0xef3c, 0xef4c, 0xef58, 0xef64, 0xef70,
    0xef7c, 0xef88, 0xef94, 0xefa0, 0xefac, 0xefb8, 0xefc4, 0xefd0,
    0xefdc, 0xefe8, 0xeff4, 0xf000, 0xf00c, 0xf018, 0xf024, 0xf09c,
    0xf0cc, 0xf154, 0xf170, 0xf190, 0xf204, 0xf224, 0xf240, 0xf2c0,
    0xf2e0, 0xf300, 0xf380, 0xf3b8, 0xf3d4, 0xf3f4, 0xf460, 0xf480,
    0xf49c, 0xf518, 0xf538, 0xf558, 0xf5d4, 0xf608, 0xf62c, 0xf650,
    0xf674, 0xf698, 0xf75c, 0xf7a0, 0xf7e4, 0xf828, 0xf86c, 0xfa04,
    0xfb68,
};

/* Complete Upgrade Menu, independently bound from the read-only move list. */
static const u32 upgrade_menu_pointers[] = {
    0x106dc, 0x1096c, 0x10978, 0x10984, 0x10990, 0x1099c, 0x109a8, 0x109b4,
    0x109c0, 0x109cc, 0x109d8, 0x109e4, 0x109f0, 0x109fc, 0x10a08, 0x10a14,
    0x10a20, 0x10a2c, 0x10a38, 0x10a44, 0x10a50, 0x10a68, 0x10a74, 0x10a80,
    0x10a8c, 0x10a98, 0x10aa4, 0x10ab0, 0x10abc, 0x10ac8, 0x10ad4, 0x10ae0,
    0x10aec, 0x10af8, 0x10b04, 0x10b10, 0x10b1c, 0x10b28, 0x10b34, 0x10b40,
    0x10b4c, 0x10b64, 0x10b70, 0x10b7c, 0x10b88, 0x10b94, 0x10ba0, 0x10bac,
    0x10bb8, 0x10bc4, 0x10bd0, 0x10bdc, 0x10be8, 0x10bf4, 0x10c00, 0x10c0c,
    0x10c18, 0x10c24, 0x10c30, 0x10c3c, 0x10c48, 0x10c60, 0x10c6c, 0x10c78,
    0x10c84, 0x10c90, 0x10c9c, 0x10ca8, 0x10cb4, 0x10cc0, 0x10ccc, 0x10cd8,
    0x10ce4, 0x10cf0, 0x10cfc, 0x10d08, 0x10d14, 0x10d20, 0x10d2c, 0x10d38,
    0x10d44, 0x10d5c, 0x10d68, 0x10d74, 0x10d80, 0x10d8c, 0x10d98, 0x10da4,
    0x10db0, 0x10dbc, 0x10dc8, 0x10dd4, 0x10de0, 0x10dec, 0x10df8, 0x10e04,
    0x10e10, 0x10e1c, 0x10e28, 0x10e34, 0x10e40, 0x10e64, 0x10e90, 0x10f30,
    0x10f94, 0x10fbc, 0x110ac, 0x11148, 0x1117c, 0x111a0, 0x111c0, 0x111ec,
    0x11258, 0x11304, 0x11310, 0x1131c, 0x11328, 0x11334, 0x11340, 0x1134c,
    0x11358, 0x11364, 0x11370, 0x1137c, 0x11388, 0x11394, 0x113a0, 0x113ac,
    0x113b8, 0x113c4, 0x113d0, 0x113dc, 0x113fc, 0x11408, 0x11414, 0x11420,
    0x1142c, 0x11438, 0x11444, 0x11450, 0x1145c, 0x11468, 0x11474, 0x11480,
    0x1148c, 0x11498, 0x114a4, 0x114b0, 0x114bc, 0x114c8, 0x114d4, 0x114f4,
    0x11500, 0x1150c, 0x11518, 0x11524, 0x11530, 0x1153c, 0x11548, 0x11554,
    0x11560, 0x1156c, 0x11578, 0x11584, 0x11590, 0x1159c, 0x115a8, 0x115b4,
    0x115c0, 0x115cc, 0x115dc, 0x115e8, 0x115f4, 0x11600, 0x1160c, 0x11618,
    0x11624, 0x11630, 0x1163c, 0x11648, 0x11654, 0x11660, 0x1166c, 0x11678,
    0x11684, 0x11690, 0x1169c, 0x116a8, 0x116b4, 0x116d4, 0x11704, 0x11788,
    0x117a4, 0x117c4, 0x11838, 0x11854, 0x11874, 0x118f4, 0x1192c, 0x11948,
    0x11968, 0x119d8, 0x119f4, 0x11a14, 0x11a94, 0x11ac8, 0x11aec, 0x11b10,
    0x11b34, 0x11b58, 0x11c1c, 0x11c60, 0x11ca4, 0x11ce8, 0x11d24, 0x11e2c,
    0x11e8c, 0x11fc0,
};

static const u32 extras_movie_player_pointers[] = {
    0x168, 0x1b0, 0x218, 0x22c, 0x240, 0x254, 0x268, 0x27c,
    0x290, 0x2a4, 0x2b8, 0x2cc, 0x2e0, 0x2f4, 0x308, 0x31c, 0x3c0,
};

static const u32 continue_dialog_pointers[] = {0x8ead4, 0x8ebc0, 0x8ebe0, 0x8ec10};
static const u32 continue_frontend_pointers[] = {0xa4dc, 0xa5c8, 0xa5e8, 0xa618};
static const u32 continue_ingame_pointers[] = {0x8000, 0x80ec, 0x810c, 0x813c};
static const u32 continue_hub_pointers[] = {0x1fd9c, 0x1fe88, 0x1fea8, 0x1fed8};

/* Full results blocks in the three player packages, including input and cleanup. */
static const u32 results_93_pointers[] = {
    0x2c6f14, 0x2c6f4c, 0x2c6f84, 0x2c6fbc, 0x2c6ff4, 0x2c702c, 0x2c7064,
    0x2c709c, 0x2c70d4, 0x2c710c, 0x2c7144, 0x2c7190, 0x2c74fc, 0x2c752c,
    0x2c769c, 0x2c76bc, 0x2c76d4, 0x2c772c, 0x2c77a8, 0x2c77cc, 0x2c780c,
    0x2c7868, 0x2c7894, 0x2c78b8, 0x2c78e8, 0x2c7950, 0x2c799c,
};
static const u32 results_94_pointers[] = {
    0x307214, 0x30724c, 0x307284, 0x3072bc, 0x3072f4, 0x30732c, 0x307364,
    0x30739c, 0x3073d4, 0x30740c, 0x307444, 0x307490, 0x3077fc, 0x30782c,
    0x30799c, 0x3079bc, 0x3079d4, 0x307a2c, 0x307aa8, 0x307acc, 0x307b0c,
    0x307b68, 0x307b94, 0x307bb8, 0x307be8, 0x307c50, 0x307c9c,
};
static const u32 results_95_pointers[] = {
    0x3088d4, 0x30890c, 0x308944, 0x30897c, 0x3089b4, 0x3089ec, 0x308a24,
    0x308a5c, 0x308a94, 0x308acc, 0x308b04, 0x308b50, 0x308ebc, 0x308eec,
    0x30905c, 0x30907c, 0x309094, 0x3090ec, 0x309168, 0x30918c, 0x3091cc,
    0x309228, 0x309254, 0x309278, 0x3092a8, 0x309310, 0x30935c,
};
/* Independent map/pause settings copies; original input and handlers stay intact. */
static const u32 hub_options_pointers[] = {
    0x2210c, 0x2215c, 0x22168, 0x22174, 0x22180, 0x2218c, 0x22198, 0x221a4,
    0x22404, 0x2243c, 0x22480, 0x224c8, 0x226b8, 0x226fc, 0x22778, 0x227b8,
    0x227ec, 0x2282c, 0x2286c, 0x22894, 0x228c8, 0x228f0, 0x22938, 0x22960,
    0x229a0, 0x229d0, 0x229f8, 0x22a34, 0x22a5c, 0x22a90, 0x22ae8, 0x22b14,
    0x22b38, 0x22bfc, 0x22c30, 0x22c80, 0x22da0, 0x22db8, 0x22e54, 0x22e78,
    0x22e90, 0x22ffc, 0x23050, 0x23224,
};
static const u32 hub_audio_pointers[] = {
    0x232fc, 0x2334c, 0x23358, 0x23364, 0x23370, 0x2337c, 0x23388, 0x23394,
    0x23670, 0x236d0, 0x23780, 0x237ac, 0x237ec, 0x23868, 0x23894, 0x238d4,
    0x23950, 0x2397c, 0x239bc, 0x23a38, 0x23a64, 0x23aa4, 0x23b10, 0x23b3c,
    0x23b7c, 0x23ba4, 0x23bcc, 0x23db8, 0x23de0, 0x23e04, 0x23e2c, 0x240a8,
    0x240d4, 0x240f8, 0x24120, 0x24144, 0x24164, 0x2418c, 0x241b0, 0x241d4,
    0x241f4, 0x24290, 0x242b4, 0x242d8, 0x24304, 0x243c0,
};
static const u32 hub_controller_pointers[] = {
    0x24938, 0x24b3c, 0x24b74, 0x24bac, 0x24be4, 0x24c1c, 0x24c54, 0x24c8c,
    0x24cc4, 0x24cfc, 0x24d34, 0x24d6c, 0x24da4, 0x24ddc, 0x24e0c, 0x24e48,
    0x24e80, 0x24eb8, 0x24ef0, 0x24f28, 0x24f60, 0x24f98, 0x24fd0, 0x25008,
    0x25050, 0x25088, 0x250c0, 0x250f8, 0x25128, 0x25164, 0x2519c, 0x251d4,
    0x2520c, 0x25244, 0x2527c, 0x252b4, 0x252ec, 0x25324, 0x2536c, 0x253a4,
    0x253dc, 0x25414, 0x25444, 0x2547c, 0x25498, 0x25690, 0x25710,
};
static const u32 ingame_options_pointers[] = {
    0x6f60, 0x6fb0, 0x6fbc, 0x6fc8, 0x6fd4, 0x6fe0, 0x6fec, 0x6ff8,
    0x7258, 0x7290, 0x72d4, 0x731c, 0x74f8, 0x753c, 0x75b8, 0x75f4,
    0x7630, 0x766c, 0x7690, 0x76c0, 0x76e4, 0x7728, 0x774c, 0x7784,
    0x77b0, 0x77d4, 0x780c, 0x7830, 0x7860, 0x78b0, 0x78dc, 0x7900,
    0x79d8, 0x7a0c, 0x7b0c, 0x7b24, 0x7c88, 0x7cd0, 0x7d50, 0x7d68,
    0x7dd8, 0x7f30,
};
static const u32 ingame_audio_pointers[] = {
    0xcf7c, 0xcfcc, 0xcfd8, 0xcfe4, 0xcff0, 0xcffc, 0xd008, 0xd014,
    0xd2f0, 0xd350, 0xd400, 0xd42c, 0xd46c, 0xd4e8, 0xd514, 0xd554,
    0xd5d0, 0xd5fc, 0xd63c, 0xd6b8, 0xd6e4, 0xd724, 0xd790, 0xd7bc,
    0xd7fc, 0xd824, 0xd84c, 0xda38, 0xda60, 0xda84, 0xdaac, 0xdd28,
    0xdd54, 0xdd78, 0xdda0, 0xddc4, 0xdde4, 0xde0c, 0xde30, 0xde54,
    0xde74, 0xdf10, 0xdf34, 0xdf58, 0xdf84, 0xe040,
};

static const ProtectorScriptFlowRule context_rules[] = {
    {"Ben10TitleScreen", 0x154f, 0x207420, 0x414c, 0x8c4, 0x486c, 0x4870,
        title_pointers, 12, UINT64_C(0xfea8261d55aa6ad0)},
    {"Ben10MainMenu", 0x1573, 0x207420, 0x4fec, 0x1ba4, 0x5a68, 0x5a6c,
        menu_pointers, 46, UINT64_C(0x61bce89ecae2bdc4)},
    {"Ben10NewGame", 0x159b, 0x207420, 0x88a0, 0x1c04, 0x932c, 0x9330,
        new_game_pointers, 91, UINT64_C(0x5165bf9465fda4b9)},
    {"Ben10_NewGame_Menu", 0x169c, 0x207420, 0xfcdc, 0xa04, 0x10470, 0x10474,
        save_slot_pointers, 33, UINT64_C(0xc6a0a398b5366370)},
    {"Ben10LoadGame", 0x16fa, 0x207420, 0x12fb4, 0x1044, 0x13860, 0x13864,
        load_game_pointers, 60, UINT64_C(0xb8bd09862d4dcf9b)},
    {"Ben10OptionsScreen", 0x171f, 0x207420, 0x14514, 0x11f0, 0x14bb4, 0x14bb8,
        options_pointers, 44, UINT64_C(0xd9db201980376e1b)},
    {"Ben10OptionsScreenAudio", 0x1732, 0x207420, 0x15704, 0x11ac, 0x15f4c, 0x15f50,
        audio_options_pointers, 46, UINT64_C(0xf72a5b01018b151e)},
    {"Menu", 0x13f7, 0x48f40, 0xfeec, 0x530, 0x100d8, 0x100dc,
        in_game_menu_pointers, 1, UINT64_C(0x7c9b0407e21607d5)},
    {"InitSystem", 0x7cde0, 0x116420, 0x86910, 0x2998, 0x88528, 0x8852c,
        init_system_pointers, 84, UINT64_C(0x830f69ebb0c514b5)},
    {"Ben10HubScreen", 0x5860, 0x2b1f00, 0x105e0, 0x96e4, 0x163d4, 0x163d8,
        map_pointers, 627, UINT64_C(0xda42673ada324bd6)},
    {"Ben10ControllerScreenWII", 0x1763, 0x207420, 0x16d40, 0xe44, 0x17acc, 0x17ad0,
        controller_guide_pointers, 47, UINT64_C(0x212c0fd6e9e68dd1)},
    {"PlayerDeathScreen", 0x2b493a, 0x4ffd40, 0x33e9fc, 0x310, 0x33ec18, 0x33ec1c,
        death_93_pointers, 8, UINT64_C(0xfc09af61194de93a)},
    {"PlayerDeathScreen", 0x2f4c3a, 0x542520, 0x37ecfc, 0x310, 0x37ef18, 0x37ef1c,
        death_94_pointers, 8, UINT64_C(0x1befaf6909f90734)},
    {"PlayerDeathScreen", 0x2f62fa, 0x5405c0, 0x3803bc, 0x310, 0x3805d8, 0x3805dc,
        death_95_pointers, 8, UINT64_C(0x0b9ea09c9ce8ab98)},
    {"Menu", 0x597f, 0x2b1f00, 0x21bb4, 0x530, 0x21da0, 0x21da4,
        hub_menu_pointers, 1, UINT64_C(0x47dfe137b48d3e1e)},
    {"Ben10ExtrasScreen", 0xe56, 0x5c860, 0x19c0, 0xcf0, 0x1c4c, 0x1c50,
        extras_pointers, 30, UINT64_C(0x5bf4d96d002a66d8)},
    {"Ben10ConceptArt", 0xde0, 0x1ab040, 0xfe0, 0x11c8, 0x1d0c, 0x1d10,
        concept_art_pointers, 119, UINT64_C(0x035fe4cf9db3b9a9)},
    {"Ben10UnlockableMovies", 0xe83, 0x5c860, 0x3114, 0xb78, 0x39d4, 0x39d8,
        movies_pointers, 44, UINT64_C(0xc758412f8f37ff79)},
    {"Ben10BossViewerMenu", 0x24d012, 0x2cb540, 0x24d640, 0xba0, 0x24de04, 0x24de08,
        boss_viewer_pointers, 29, UINT64_C(0x0cb661a32e481a9c)},
    {"Ben10EnemyViewerMenu", 0x317793, 0x386e40, 0x31823c, 0xc6c, 0x318acc, 0x318ad0,
        enemy_viewer_pointers, 48, UINT64_C(0x3da3c21d6be7fb9f)},
    {"Ben10HeroViewerMenu", 0x1ff0fe, 0x270f60, 0x1ffac4, 0xbd8, 0x2002c0, 0x2002c4,
        hero_viewer_pointers, 38, UINT64_C(0xf67b606dcf606d4a)},
    {"Ben10ManageSecrets", 0xe99, 0x5c860, 0x3c8c, 0xcac, 0x4184, 0x4188,
        secrets_pointers, 39, UINT64_C(0x2cdd91ef2b21cf85)},
    {"Ben10EnterCheatCode", 0xeac, 0x5c860, 0x4938, 0xc28, 0x517c, 0x5180,
        secret_code_pointers, 44, UINT64_C(0xf22a3fc83315a4c7)},
    {"Ben10MoveList", 0x13e2, 0x48f40, 0xe100, 0x1a90, 0xe9c8, 0xe9cc,
        combo_list_pointers, 217, UINT64_C(0x28c869db4c04f80d)},
    {"Ben10UpgradeMenu", 0x140a, 0x48f40, 0x106b4, 0x1934, 0x10f3c, 0x10f40,
        upgrade_menu_pointers, 218, UINT64_C(0x2a33325d5bbd0c24)},
    {"Ben10ExtrasMoviePlayer", 0x0, 0x540, 0x140, 0x2e4, 0x33c, 0x340,
        extras_movie_player_pointers, 17, UINT64_C(0x678c197caabc6004)},
    {"UICertContinueDialog", 0x7ce90, 0x116420, 0x8ea9c, 0x1a4, 0x8ebec, 0x8ebf0,
        continue_dialog_pointers, 4, UINT64_C(0xabb5cb32f26c49ab)},
    {"UICertContinueDialog", 0x15a8, 0x207420, 0xa4a4, 0x1a4, 0xa5f4, 0xa5f8,
        continue_frontend_pointers, 4, UINT64_C(0xfff86a98f56f718d)},
    {"UICertContinueDialog", 0x131e, 0x48f40, 0x7fc8, 0x1a4, 0x8118, 0x811c,
        continue_ingame_pointers, 4, UINT64_C(0xefc587d52c5bcf23)},
    {"UICertContinueDialog", 0x58f5, 0x2b1f00, 0x1fd64, 0x1a4, 0x1feb4, 0x1feb8,
        continue_hub_pointers, 4, UINT64_C(0x8d08b415314a92f6)},
    {"EndOfLevelStats", 0x2b3d10, 0x4ffd40, 0x2c6de8, 0xc84, 0x2c78f4, 0x2c78f8,
        results_93_pointers, 27, UINT64_C(0x1beab2ed83c08915)},
    {"EndOfLevelStats", 0x2f4010, 0x542520, 0x3070e8, 0xc84, 0x307bf4, 0x307bf8,
        results_94_pointers, 27, UINT64_C(0x6f29fc1afecef140)},
    {"EndOfLevelStats", 0x2f56d0, 0x5405c0, 0x3087a8, 0xc84, 0x3092b4, 0x3092b8,
        results_95_pointers, 27, UINT64_C(0xf4f66a02a6fec04b)},
    /* Dynamic word-wrapped choices have no keyed DisplayText call. Their
     * initial selection assignment admits the complete source block once;
     * original direction/Confirm predicates and result messages stay intact. */
    {"UICertYesNoDialog", 0x7cea5, 0x116420, 0x8ec40, 0x264, 0x8ec6c, 0x8ec70,
        NULL, 0, UINT64_C(0x6d664733d01e94b2)},
    {"UICertThreeWayDialog", 0x7ceb7, 0x116420, 0x8eea4, 0x33c, 0x8eed0, 0x8eed4,
        NULL, 0, UINT64_C(0xbc7344450579efed)},
    {"UICertYesNoDialog", 0x15bd, 0x207420, 0xa648, 0x264, 0xa674, 0xa678,
        NULL, 0, UINT64_C(0x6d664733d01e94b2)},
    {"UICertThreeWayDialog", 0x15cf, 0x207420, 0xa8ac, 0x33c, 0xa8d8, 0xa8dc,
        NULL, 0, UINT64_C(0xbc7344450579efed)},
    {"UICertYesNoDialog", 0x1333, 0x48f40, 0x816c, 0x264, 0x8198, 0x819c,
        NULL, 0, UINT64_C(0x6d664733d01e94b2)},
    {"UICertThreeWayDialog", 0x1345, 0x48f40, 0x83d0, 0x33c, 0x83fc, 0x8400,
        NULL, 0, UINT64_C(0xbc7344450579efed)},
    {"UICertYesNoDialog", 0x590a, 0x2b1f00, 0x1ff08, 0x264, 0x1ff34, 0x1ff38,
        NULL, 0, UINT64_C(0x6d664733d01e94b2)},
    {"UICertThreeWayDialog", 0x591c, 0x2b1f00, 0x2016c, 0x33c, 0x20198, 0x2019c,
        NULL, 0, UINT64_C(0xbc7344450579efed)},
    /* This renderer also displays Saving. Only the exact fatal message below
     * admits an exit action; neither the block nor a broad key prefix does. */
    {"UICertNonInteractiveDialog", 0x7cecc, 0x116420, 0x8f1e0, 0xe4, 0x8f238, 0x8f23c,
        NULL, 0, UINT64_C(0x56d83354c7e48c52)},
    {"UICertNonInteractiveDialog", 0x15e4, 0x207420, 0xabe8, 0xe4, 0xac40, 0xac44,
        NULL, 0, UINT64_C(0x56d83354c7e48c52)},
    {"UICertNonInteractiveDialog", 0x5931, 0x2b1f00, 0x204a8, 0xe4, 0x20500, 0x20504,
        NULL, 0, UINT64_C(0x56d83354c7e48c52)},
    {"Ben10OptionsScreen", 0x5984, 0x2b1f00, 0x220e4, 0x11f0, 0x22784, 0x22788,
        hub_options_pointers, 44, UINT64_C(0xd084c1e131873c8e)},
    {"Ben10OptionsScreenAudio", 0x5997, 0x2b1f00, 0x232d4, 0x11ac, 0x23b1c, 0x23b20,
        hub_audio_pointers, 46, UINT64_C(0x264915c8ce8a970f)},
    {"Ben10ControllerScreenWII", 0x59c8, 0x2b1f00, 0x24910, 0xe44, 0x2569c, 0x256a0,
        hub_controller_pointers, 47, UINT64_C(0xde4b4e038999bade)},
    {"Ben10InGameOptionsScreen", 0x1305, 0x48f40, 0x6f38, 0x1090, 0x75c4, 0x75c8,
        ingame_options_pointers, 42, UINT64_C(0x149a1849335ca053)},
    {"Ben10OptionsScreenAudio", 0x13ca, 0x48f40, 0xcf54, 0x11ac, 0xd79c, 0xd7a0,
        ingame_audio_pointers, 46, UINT64_C(0x479ddbffc0b20285)},
};
/* A block may have different authored paths to the same visible menu. Each
 * entry admits one exact key at one DisplayText return, never a key prefix. */
static const ProtectorUIContextAdmission context_admissions[] = {
    {0, 0x486c, "Platform-PC-42", PROTECTOR_UI_TITLE, 0x0, 0x0},
    {1, 0x5a68, "Panel-MainMenu-1", PROTECTOR_UI_MENU, 0x0, 0x0},
    {1, 0x5a68, "Panel-MainMenu-2", PROTECTOR_UI_MENU, 0x0, 0x0},
    {1, 0x5a68, "Panel-MainMenu-3", PROTECTOR_UI_MENU, 0x0, 0x0},
    {2, 0x932c, "Panel-LoadGame-15", PROTECTOR_UI_MENU, 0x0, 0x0},
    {2, 0x93e8, "Panel-LoadGame-2", PROTECTOR_UI_MENU, 0x0, 0x0},
    {2, 0x9a7c, "Panel-LoadGame-2", PROTECTOR_UI_MENU, 0x0, 0x0},
    {3, 0x10470, "Panel-LoadGame-2", PROTECTOR_UI_MENU, 0x0, 0x0},
    {4, 0x13860, "Panel-LoadGame-3", PROTECTOR_UI_MENU, 0x0, 0x0},
    {5, 0x14bb4, "Panel-OptionsScreen-11", PROTECTOR_UI_MENU, 0x0, 0x0},
    {6, 0x15f4c, "Panel-OptionsScreen-12", PROTECTOR_UI_MENU, 0x0, 0x0},
    {6, 0x15f78, "Panel-OptionsScreen-12", PROTECTOR_UI_MENU, 0x0, 0x0},
    /* Generic Menu also serves other screens. Admit only the observed pause
     * header at its exact return, not item text or every Menu instance. */
    {7, 0x100d8, "Panel-Options-1", PROTECTOR_UI_MENU, 0x0, 0x0},
    /* InitSystem lives through gameplay. Accepted Confirm releases controls
     * and retains passive ownership. The no-tip yield at 0x88674 repeats during
     * bootstrap, but ends subsequent loads after that same owner was confirmed.
     * Its exact yield and preceding no-tip branch are source-verified. */
    {8, 0x88528, "Panel-Misc-4", PROTECTOR_UI_LOADING, 0x88634, 0x88674},
    {8, 0x8862c, "Panel-Options-16", PROTECTOR_UI_PROMPT, 0x88634, 0x88674},
    {9, 0x163d4, "Platform-PC-41", PROTECTOR_UI_MAP, 0x0, 0x0},
    {9, 0x166b4, "Panel-HubScreen-5", PROTECTOR_UI_MAP, 0x0, 0x0},
    {9, 0x16770, "Panel-HubScreen-8", PROTECTOR_UI_MAP, 0x0, 0x0},
    {9, 0x16994, "Panel-HubScreen-8", PROTECTOR_UI_MAP, 0x0, 0x0},
    {10, 0x17acc, "Panel-ControllerScreen-1", PROTECTOR_UI_CONTROLS_GUIDE, 0x0, 0x0},
    {11, 0x33ec18, "Panel-Options-16", PROTECTOR_UI_DEFEAT, 0x0, 0x0},
    {12, 0x37ef18, "Panel-Options-16", PROTECTOR_UI_DEFEAT, 0x0, 0x0},
    {13, 0x3805d8, "Panel-Options-16", PROTECTOR_UI_DEFEAT, 0x0, 0x0},
    {14, 0x21da0, "Panel-Options-1", PROTECTOR_UI_MENU, 0x0, 0x0},
    {15, 0x1c4c, "Panel-ExtrasScreen-1", PROTECTOR_UI_EXTRAS_ROOT, 0x0, 0x0},
    {16, 0x1d0c, "panel-UnlockableScreen-3", PROTECTOR_UI_GALLERY, 0x0, 0x0},
    {16, 0x1fa0, "Panel-LoadGame-2", PROTECTOR_UI_GALLERY, 0x0, 0x0},
    {17, 0x39d4, "Panel-UnlockableScreen-19", PROTECTOR_UI_EXTRAS_BROWSER, 0x0, 0x0},
    {18, 0x24de04, "Panel-ExtrasScreen-4", PROTECTOR_UI_EXTRAS_BROWSER, 0x0, 0x0},
    {19, 0x318acc, "Panel-ExtrasScreen-8", PROTECTOR_UI_EXTRAS_BROWSER, 0x0, 0x0},
    {20, 0x2002c0, "Panel-ExtrasScreen-7", PROTECTOR_UI_EXTRAS_BROWSER, 0x0, 0x0},
    /* Actual Wii full-view branch: the exact Back draw follows model entry.
     * The grid's next header switches the same owner back on return. */
    {18, 0x24e078, "Panel-LoadGame-2", PROTECTOR_UI_EXTRAS_VIEWER, 0x0, 0x0},
    {19, 0x318d40, "Panel-LoadGame-2", PROTECTOR_UI_EXTRAS_VIEWER, 0x0, 0x0},
    {20, 0x200534, "Panel-LoadGame-2", PROTECTOR_UI_EXTRAS_VIEWER, 0x0, 0x0},
    {21, 0x4184, "Panel-UnlockableScreen-8", PROTECTOR_UI_EXTRAS_OPTIONS, 0x0, 0x0},
    {22, 0x517c, "Panel-ExtrasScreen-6", PROTECTOR_UI_EXTRAS_OPTIONS, 0x0, 0x0},
    {23, 0xe9c8, "Panel-UpgradeScreen-8", PROTECTOR_UI_COMBO_LIST, 0x0, 0x0},
    {24, 0x10f3c, "Panel-UpgradeScreen-7", PROTECTOR_UI_UPGRADE_MENU, 0x0, 0x0},
    /* The header resets readiness each source frame; unavailable forms do not
     * execute this draw. Never offer purchase merely because the menu exists. */
    {24, 0x110b8, "Panel-UpgradeScreen-1", PROTECTOR_UI_UPGRADE_READY, 0x0, 0x0},
    /* Independent complete copies, not a shared alias-name assumption. The
     * live return-map error uses the hub copy (29). Only each Wii Continue
     * draw is admitted; blocks include the A-bit check and completion send. */
    {26, 0x8ebec, "Cert-General-1", PROTECTOR_UI_CONTINUE_DIALOG, 0x0, 0x0},
    {27, 0xa5f4, "Cert-General-1", PROTECTOR_UI_CONTINUE_DIALOG, 0x0, 0x0},
    {28, 0x8118, "Cert-General-1", PROTECTOR_UI_CONTINUE_DIALOG, 0x0, 0x0},
    {29, 0x1feb4, "Cert-General-1", PROTECTOR_UI_CONTINUE_DIALOG, 0x0, 0x0},
    /* Reuse the existing one-action surface only while source offers Continue. */
    {30, 0x2c78f4, "Panel-EndOfLevelStats-3", PROTECTOR_UI_CONTINUE_DIALOG, 0x0, 0x0},
    {31, 0x307bf4, "Panel-EndOfLevelStats-3", PROTECTOR_UI_CONTINUE_DIALOG, 0x0, 0x0},
    {32, 0x3092b4, "Panel-EndOfLevelStats-3", PROTECTOR_UI_CONTINUE_DIALOG, 0x0, 0x0},
    {41, 0x8f238, "Platform-Wii-5", PROTECTOR_UI_FATAL_DIALOG, 0x0, 0x0},
    {42, 0xac40, "Platform-Wii-5", PROTECTOR_UI_FATAL_DIALOG, 0x0, 0x0},
    {43, 0x20500, "Platform-Wii-5", PROTECTOR_UI_FATAL_DIALOG, 0x0, 0x0},
    {44, 0x22784, "Panel-OptionsScreen-11", PROTECTOR_UI_MENU, 0x0, 0x0},
    {45, 0x23b1c, "Panel-OptionsScreen-12", PROTECTOR_UI_MENU, 0x0, 0x0},
    {45, 0x23b48, "Panel-OptionsScreen-12", PROTECTOR_UI_MENU, 0x0, 0x0},
    {46, 0x2569c, "Panel-ControllerScreen-1", PROTECTOR_UI_CONTROLS_GUIDE, 0x0, 0x0},
    {47, 0x75c4, "Panel-OptionsScreen-11", PROTECTOR_UI_MENU, 0x0, 0x0},
    {48, 0xd79c, "Panel-OptionsScreen-12", PROTECTOR_UI_MENU, 0x0, 0x0},
    {48, 0xd7c8, "Panel-OptionsScreen-12", PROTECTOR_UI_MENU, 0x0, 0x0},
};

/* In the same hash-bound HubScreen: video start, authored skip-input check,
 * and common movie cleanup. Natural completion and Skip share the last site.
 * No duration guess or guest mutation is used. */
static const ProtectorUIContextTransition context_transitions[] = {
    {9, 0x15c70, PROTECTOR_UI_CINEMATIC},
    {9, 0x15cb4, PROTECTOR_UI_CINEMATIC_READY},
    {9, 0x15cf8, PROTECTOR_UI_LOADING},
    /* Both source-authored FadeOut returns withdraw defeat confirmation.
     * Dispatch/end/expiry retire this ordinary owner; no loading lease. */
    {11, 0x33ec48, PROTECTOR_UI_LOADING},
    {11, 0x33ec90, PROTECTOR_UI_LOADING},
    {12, 0x37ef48, PROTECTOR_UI_LOADING},
    {12, 0x37ef90, PROTECTOR_UI_LOADING},
    {13, 0x380608, PROTECTOR_UI_LOADING},
    {13, 0x380650, PROTECTOR_UI_LOADING},
    {25, 0x33c, PROTECTOR_UI_CINEMATIC},
    {25, 0x36c, PROTECTOR_UI_CINEMATIC_READY},
    {25, 0x3b0, PROTECTOR_UI_GAMEPLAY},
    {30, 0x2c79d4, PROTECTOR_UI_LOADING},
    {31, 0x307cd4, PROTECTOR_UI_LOADING},
    {32, 0x309394, PROTECTOR_UI_LOADING},
};

/* Extras unloads HubScreen and runs its independent 05_12 movie player.
 * The instruction following its original avpPlay call is a cold admission,
 * not a renderer-active heuristic or permission to skip the authored delay. */
static const ProtectorUIContextDispatchAdmission context_dispatch_admissions[] = {
    {25, 0x33c, 0x320bff01, PROTECTOR_UI_CINEMATIC},
    {33, 0x8ec6c, 0x0a05ff03, PROTECTOR_UI_CHOICE_DIALOG},
    {34, 0x8eed0, 0x0a09ff04, PROTECTOR_UI_CHOICE_DIALOG},
    {35, 0xa674, 0x0a05ff03, PROTECTOR_UI_CHOICE_DIALOG},
    {36, 0xa8d8, 0x0a09ff04, PROTECTOR_UI_CHOICE_DIALOG},
    {37, 0x8198, 0x0a05ff03, PROTECTOR_UI_CHOICE_DIALOG},
    {38, 0x83fc, 0x0a09ff04, PROTECTOR_UI_CHOICE_DIALOG},
    {39, 0x1ff34, 0x0a05ff03, PROTECTOR_UI_CHOICE_DIALOG},
    {40, 0x20198, 0x0a09ff04, PROTECTOR_UI_CHOICE_DIALOG},
};

static atomic_uint published_context;

static void observe_map_actions(ProtectorUIContextOwner* owner,
    const ProtectorUIContextAdmission* admission, u64 frame) {
    if (admission->kind != PROTECTOR_UI_MAP) return;
    if (owner->map_actions_frame != frame) owner->map_actions = 0;
    owner->map_actions_frame = frame;
    if (!strcmp(admission->key, "Panel-HubScreen-5"))
        owner->map_actions |= PROTECTOR_UI_MAP_REPLAY;
    if (!strcmp(admission->key, "Panel-HubScreen-8"))
        owner->map_actions |= PROTECTOR_UI_MAP_CHALLENGE;
}

static void discard_loading_for_menu(ProtectorUIContextTracker* tracker,
    ProtectorUIContext kind) {
    if (kind != PROTECTOR_UI_TITLE && kind != PROTECTOR_UI_MENU && kind != PROTECTOR_UI_GALLERY &&
        kind != PROTECTOR_UI_EXTRAS_BROWSER && kind != PROTECTOR_UI_EXTRAS_OPTIONS && kind != PROTECTOR_UI_EXTRAS_ROOT &&
        kind != PROTECTOR_UI_COMBO_LIST && kind != PROTECTOR_UI_EXTRAS_VIEWER &&
        kind != PROTECTOR_UI_UPGRADE_MENU && kind != PROTECTOR_UI_UPGRADE_READY &&
        kind != PROTECTOR_UI_MAP && kind != PROTECTOR_UI_CONTROLS_GUIDE) return;
    for (u32 i = 0; i < tracker->count;) {
        ProtectorUIContextOwner* owner = &tracker->owners[i];
        if (owner->kind == PROTECTOR_UI_LOADING || owner->kind == PROTECTOR_UI_PROMPT) {
            if (owner->loading_confirmed) {
                owner->kind = PROTECTOR_UI_GAMEPLAY;
                ++i;
            } else tracker->owners[i] = tracker->owners[--tracker->count];
        } else ++i;
    }
}

const char* protector_combo_action_sequence(u32 ordinal) {
    /* The nineteen source table ordinals, verified across all three Wii
     * notation families. These describe actions, never move availability. */
    static const char* sequences[] = {
        "1", "2", "11", "12", "21", "22", "111", "112", "222",
        "114", "224", "4", "41", "42", "44", "31", "32", "34", "4",
    };
    return ordinal >= 1 && ordinal <= 19 ? sequences[ordinal - 1] : NULL;
}

u32 protector_combo_action_for_glyph(u32 scheme, u8 glyph) {
    static const u8 source_glyphs[3][4] = {{1,2,4,6}, {1,2,4,9}, {2,6,1,4}};
    if (scheme < 1 || scheme > 3) return 0;
    for (u32 action = 0; action < 4; ++action)
        if (source_glyphs[scheme - 1][action] == glyph) return action + 1;
    return 0;
}

static u32 combo_text_scheme(const ProtectorUIText* text) {
    static const char prefix[] = "Panel-CombosButtonsOnlyWii";
    if (strncmp(text->key, prefix, sizeof(prefix) - 1)) return 0;
    if (text->language_slot != 1 || text->text_size < 1 || text->text_size > 3 ||
        text->text[text->text_size] != 0) return 0;
    u32 scheme = 0;
    for (u32 family = 1; family <= 3 && !scheme; ++family) {
        for (u32 ordinal = 1; ordinal <= 19; ++ordinal) {
            char key[64];
            if (family == 1) snprintf(key, sizeof(key), "Panel-CombosButtonsOnlyWii-%u", ordinal);
            else snprintf(key, sizeof(key), "Panel-CombosButtonsOnlyWii%u-%u", family, ordinal);
            if (strcmp(key, text->key)) continue;
            const char* actions = protector_combo_action_sequence(ordinal);
            if (strlen(actions) != text->text_size) return 0;
            for (u32 byte = 0; byte < text->text_size; ++byte)
                if (protector_combo_action_for_glyph(family, text->text[byte]) != (u32)(actions[byte] - '0')) return 0;
            scheme = family;
            break;
        }
    }
    return scheme;
}

static void observe_combo_glyphs(ProtectorUIContextTracker* tracker, const CPUState* cpu,
    const ProtectorUIText* text, u32 context, u32 ip) {
    for (u32 i = 0; i < tracker->count; ++i) {
        ProtectorUIContextOwner* owner = &tracker->owners[i];
        if (owner->context != context) continue;
        const bool combo = owner->kind == PROTECTOR_UI_COMBO_LIST && owner->rule_index == 23 &&
            ip == owner->begin - 0xe100u + 0xe2f0u;
        const bool upgrade = (owner->kind == PROTECTOR_UI_UPGRADE_MENU || owner->kind == PROTECTOR_UI_UPGRADE_READY) &&
            owner->rule_index == 24 &&
            ip == owner->begin - 0x106b4u + 0x10800u;
        if (!combo && !upgrade) continue;
        if (owner->combo_glyph_frame != cpu->presented_frame_count) owner->combo_glyph_families = 0;
        owner->combo_glyph_frame = cpu->presented_frame_count;
        // Bit zero poisons this frame if the owned call supplies unknown,
        // translated, truncated or changed notation; later valid rows cannot
        // hide the invalid row. A new presented frame starts fresh.
        owner->combo_glyph_families |= 1u << combo_text_scheme(text);
    }
}

bool protector_ui_context_observe(ProtectorUIContextTracker* tracker,
    const CPUState* cpu, const ProtectorUIText* text, u32 context, u32 ip) {
    if (!tracker || !cpu || !text || !context) return false;
    const bool keyed = text->key_available && memchr(text->key, 0, sizeof(text->key));
    /* A reused non-interactive renderer can switch to Saving in the same
     * frame. Revoke the fatal lease before key filtering, including an unknown
     * key. Other text draws cannot revoke a still-visible fatal message. */
    for (u32 i = 0; i < tracker->count;) {
        ProtectorUIContextOwner* owner = &tracker->owners[i];
        const ProtectorScriptFlowRule* rule = &context_rules[owner->rule_index];
        if (owner->kind == PROTECTOR_UI_FATAL_DIALOG && owner->context == context &&
            ip == owner->begin - rule->code_offset + rule->from_offset &&
            (!keyed || strcmp(text->key, "Platform-Wii-5"))) {
            tracker->owners[i] = tracker->owners[--tracker->count];
        } else ++i;
    }
    if (!keyed) return false;
    observe_combo_glyphs(tracker, cpu, text, context, ip);
    for (size_t entry = 0; entry < sizeof(context_admissions) / sizeof(context_admissions[0]); ++entry) {
        const ProtectorUIContextAdmission* admission = &context_admissions[entry];
        if (strcmp(text->key, admission->key)) continue;
        const u32 index = admission->rule_index;
        const ProtectorUIContext kind = admission->kind;
        for (u32 i = 0; i < tracker->count; ++i) {
            ProtectorUIContextOwner* owner = &tracker->owners[i];
            if (owner->context == context && owner->rule_index == index &&
                ip == owner->begin - context_rules[index].code_offset + admission->return_offset) {
                if (cpu->presented_frame_count < owner->last_frame)
                    owner->loading_confirmed = false;
                owner->last_frame = cpu->presented_frame_count;
                owner->kind = kind;
                observe_map_actions(owner, admission, cpu->presented_frame_count);
                discard_loading_for_menu(tracker, kind);
                return true;
            }
        }
        ProtectorScriptFlowRule source = context_rules[index];
        source.from_offset = admission->return_offset;
        source.to_offset = source.from_offset + 4;
        ProtectorScriptFlowMatch match;
        if (!protector_script_flow_match(cpu, ip, &source, &match)) continue;
        discard_loading_for_menu(tracker, kind);
        /* Replacement of a reused context cannot retain an old script's lease. */
        u32 slot = tracker->count;
        for (u32 i = 0; i < tracker->count; ++i)
            if (tracker->owners[i].context == context) { slot = i; break; }
        if (slot == 4) return false;
        if (slot == tracker->count) tracker->count++;
        tracker->owners[slot] = (ProtectorUIContextOwner){.context = context,
            .begin = match.file_info_base + source.code_offset,
            .end = match.file_info_base + source.code_offset + source.code_size,
            .last_frame = cpu->presented_frame_count, .kind = kind, .rule_index = index,
            .leave_begin = admission->leave_begin ? match.file_info_base + admission->leave_begin : 0,
            .leave_end = admission->leave_end ? match.file_info_base + admission->leave_end : 0};
        observe_map_actions(&tracker->owners[slot], admission, cpu->presented_frame_count);
        tracker->admission_count++;
        tracker->last_admission = context_rules[index].name;
        return true;
    }
    return false;
}

static void remove_owner(ProtectorUIContextTracker* tracker, u32 index) {
    tracker->owners[index] = tracker->owners[--tracker->count];
}

bool protector_ui_context_admit_dispatch(ProtectorUIContextTracker* tracker,
    const CPUState* cpu, u32 context, u32 ip, u32 instruction) {
    if (!tracker || !cpu || !context || tracker->count > 4) return false;
    for (size_t n = 0; n < sizeof(context_dispatch_admissions) / sizeof(context_dispatch_admissions[0]); ++n) {
        const ProtectorUIContextDispatchAdmission* admission = &context_dispatch_admissions[n];
        // This cheap filter runs at every dispatch. Hash only a candidate marker.
        if (instruction != admission->instruction) continue;
        ProtectorScriptFlowRule source = context_rules[admission->rule_index];
        source.from_offset = admission->offset;
        source.to_offset = admission->offset + 4;
        ProtectorScriptFlowMatch match;
        if (!protector_script_flow_match(cpu, ip, &source, &match)) continue;
        u32 slot = tracker->count;
        for (u32 i = 0; i < tracker->count; ++i)
            if (tracker->owners[i].context == context) { slot = i; break; }
        if (slot == 4) return false;
        if (slot == tracker->count) ++tracker->count;
        tracker->owners[slot] = (ProtectorUIContextOwner){.context = context,
            .begin = match.file_info_base + source.code_offset,
            .end = match.file_info_base + source.code_offset + source.code_size,
            .last_frame = cpu->presented_frame_count, .kind = admission->kind,
            .rule_index = admission->rule_index};
        ++tracker->admission_count;
        tracker->last_admission = source.name;
        return true;
    }
    return false;
}

void protector_ui_context_dispatch(ProtectorUIContextTracker* tracker,
    u32 context, u32 ip, u32 instruction, u64 frame) {
    if (!tracker) return;
    for (u32 i = 0; i < tracker->count; ++i) {
        ProtectorUIContextOwner* owner = &tracker->owners[i];
        if (owner->context != context) continue;
        if (ip < owner->begin || ip >= owner->end || (instruction >> 24) == 0x89 ||
            frame < owner->last_frame)
            remove_owner(tracker, i);
        else if (owner->leave_end && ip >= owner->leave_begin && ip < owner->leave_end) {
            if (owner->kind == PROTECTOR_UI_PROMPT || owner->loading_confirmed) {
                owner->loading_confirmed = true;
                owner->kind = PROTECTOR_UI_GAMEPLAY;
                owner->last_frame = frame;
            } else remove_owner(tracker, i);
        }
        else {
            owner->last_frame = frame;
            /* Only a later no-tip load can finish here. Initial resource-batch
             * gaps retain Loading, and a visible ready prompt still needs its
             * own accepted-Confirm departure. No timeout or render heuristic. */
            if (owner->loading_confirmed && owner->kind == PROTECTOR_UI_LOADING &&
                ip == owner->leave_end && instruction == 0x47ffff00u)
                owner->kind = PROTECTOR_UI_GAMEPLAY;
            const u32 base = owner->begin - context_rules[owner->rule_index].code_offset;
            for (size_t n = 0; n < sizeof(context_transitions) / sizeof(context_transitions[0]); ++n) {
                const ProtectorUIContextTransition* transition = &context_transitions[n];
                if (owner->rule_index == transition->rule_index && ip == base + transition->offset) {
                    owner->kind = transition->kind;
                    owner->map_actions = 0;
                }
            }
        }
        return;
    }
}

static unsigned context_priority(ProtectorUIContext kind) {
    /* Collection browsers specialize Menu placement, never override loading,
     * instruction, cinematic or death stage merely because its enum is newer. */
    return kind == PROTECTOR_UI_GALLERY || kind == PROTECTOR_UI_EXTRAS_BROWSER ||
        kind == PROTECTOR_UI_EXTRAS_OPTIONS || kind == PROTECTOR_UI_EXTRAS_ROOT ||
        kind == PROTECTOR_UI_COMBO_LIST || kind == PROTECTOR_UI_EXTRAS_VIEWER ||
        kind == PROTECTOR_UI_UPGRADE_MENU || kind == PROTECTOR_UI_UPGRADE_READY ?
        PROTECTOR_UI_MENU : (unsigned)kind;
}

ProtectorUIContext protector_ui_context_frame(ProtectorUIContextTracker* tracker, u64 frame) {
    ProtectorUIContext result = PROTECTOR_UI_GAMEPLAY;
    if (!tracker) return result;
    for (u32 i = 0; i < tracker->count;) {
        ProtectorUIContextOwner* owner = &tracker->owners[i];
        /* Ordinary menus expire when dispatch stops. InitSystem loading can
         * intentionally sleep while asynchronous content still presents frames;
         * its source-verified departure window, not a guessed frame timeout,
         * owns the loading/ready lifetime. End/out-of-block dispatch and a
         * backwards frame clock still remove every kind of owner. */
        if (frame < owner->last_frame || (!owner->leave_end && frame - owner->last_frame > 2)) {
            remove_owner(tracker, i);
            continue;
        }
        if (context_priority(owner->kind) > context_priority(result) ||
            (context_priority(owner->kind) == PROTECTOR_UI_MENU && owner->kind != PROTECTOR_UI_MENU &&
                (result == PROTECTOR_UI_MENU || (result == PROTECTOR_UI_EXTRAS_ROOT &&
                    owner->kind != PROTECTOR_UI_EXTRAS_ROOT))))
            result = owner->kind;
        ++i;
    }
    return result;
}

u32 protector_ui_context_map_actions(const ProtectorUIContextTracker* tracker, u64 frame) {
    u32 actions = 0;
    if (!tracker) return actions;
    for (u32 i = 0; i < tracker->count; ++i) {
        const ProtectorUIContextOwner* owner = &tracker->owners[i];
        if (owner->kind == PROTECTOR_UI_MAP && frame >= owner->map_actions_frame &&
            frame - owner->map_actions_frame <= 2) actions |= owner->map_actions;
    }
    return actions;
}
static u32 notation_scheme(const ProtectorUIContextTracker* tracker, u64 frame, ProtectorUIContext kind) {
    u32 families = 0;
    if (!tracker) return 0;
    for (u32 i = 0; i < tracker->count; ++i) {
        const ProtectorUIContextOwner* owner = &tracker->owners[i];
        const bool matches = owner->kind == kind ||
            (kind == PROTECTOR_UI_UPGRADE_MENU && owner->kind == PROTECTOR_UI_UPGRADE_READY);
        if (matches && owner->last_frame == frame &&
            owner->combo_glyph_frame == frame) families |= owner->combo_glyph_families;
    }
    for (u32 scheme = 1; scheme <= 3; ++scheme)
        if (families == (1u << scheme)) return scheme;
    return 0;
}
u32 protector_ui_context_combo_scheme(const ProtectorUIContextTracker* tracker, u64 frame) {
    return notation_scheme(tracker, frame, PROTECTOR_UI_COMBO_LIST);
}
u32 protector_ui_context_upgrade_scheme(const ProtectorUIContextTracker* tracker, u64 frame) {
    return notation_scheme(tracker, frame, PROTECTOR_UI_UPGRADE_MENU);
}

void protector_ui_context_publish_snapshot(ProtectorUIContext context, u32 map_actions) {
    const u32 actions = context == PROTECTOR_UI_MAP ?
        map_actions & (PROTECTOR_UI_MAP_REPLAY | PROTECTOR_UI_MAP_CHALLENGE) : 0;
    atomic_store_explicit(&published_context, (u32)context | (actions << 8), memory_order_release);
}
ProtectorUIContextSnapshot protector_ui_context_snapshot(void) {
    const u32 value = atomic_load_explicit(&published_context, memory_order_acquire);
    return (ProtectorUIContextSnapshot){(ProtectorUIContext)(value & 0xff), value >> 8};
}
void protector_ui_context_publish(ProtectorUIContext context) {
    protector_ui_context_publish_snapshot(context, 0);
}
ProtectorUIContextSnapshot protector_ui_context_startup_snapshot(
    ProtectorUIContextSnapshot snapshot, bool* observed_source_screen) {
    if (!observed_source_screen) return snapshot;
    if (snapshot.context != PROTECTOR_UI_GAMEPLAY) *observed_source_screen = true;
    if (!*observed_source_screen)
        return (ProtectorUIContextSnapshot){PROTECTOR_UI_LOADING, 0};
    return snapshot;
}
ProtectorUIContext protector_ui_context_current(void) {
    return protector_ui_context_snapshot().context;
}
const char* protector_ui_context_name(ProtectorUIContext context) {
    switch (context) {
        case PROTECTOR_UI_TITLE: return "title";
        case PROTECTOR_UI_MAP: return "world-map";
        case PROTECTOR_UI_CINEMATIC: return "cinematic";
        case PROTECTOR_UI_CINEMATIC_READY: return "cinematic-ready";
        case PROTECTOR_UI_CONTROLS_GUIDE: return "controls-guide";
        case PROTECTOR_UI_DEFEAT: return "defeat-ready";
        case PROTECTOR_UI_MENU: return "menu";
        case PROTECTOR_UI_GALLERY: return "gallery";
        case PROTECTOR_UI_EXTRAS_BROWSER: return "extras-browser";
        case PROTECTOR_UI_EXTRAS_OPTIONS: return "extras-options";
        case PROTECTOR_UI_EXTRAS_ROOT: return "extras-root";
        case PROTECTOR_UI_COMBO_LIST: return "combo-list";
        case PROTECTOR_UI_EXTRAS_VIEWER: return "extras-viewer";
        case PROTECTOR_UI_UPGRADE_MENU: return "upgrade-menu";
        case PROTECTOR_UI_UPGRADE_READY: return "upgrade-ready";
        case PROTECTOR_UI_CONTINUE_DIALOG: return "continue-dialog";
        case PROTECTOR_UI_CHOICE_DIALOG: return "choice-dialog";
        case PROTECTOR_UI_FATAL_DIALOG: return "fatal-dialog";
        case PROTECTOR_UI_LOADING: return "loading";
        case PROTECTOR_UI_PROMPT: return "confirm-prompt";
        case PROTECTOR_UI_READING: return "instruction-reading";
        case PROTECTOR_UI_INSTRUCTION: return "instruction-ready";
        default: return "full-controls";
    }
}

const ProtectorScriptFlowRule* protector_ui_context_rules(size_t* count) {
    if (count) *count = sizeof(context_rules) / sizeof(context_rules[0]);
    return context_rules;
}
const ProtectorUIContextAdmission* protector_ui_context_admissions(size_t* count) {
    if (count) *count = sizeof(context_admissions) / sizeof(context_admissions[0]);
    return context_admissions;
}
const ProtectorUIContextTransition* protector_ui_context_transitions(size_t* count) {
    if (count) *count = sizeof(context_transitions) / sizeof(context_transitions[0]);
    return context_transitions;
}

const ProtectorUIContextDispatchAdmission* protector_ui_context_dispatch_admissions(size_t* count) {
    if (count) *count = sizeof(context_dispatch_admissions) / sizeof(context_dispatch_admissions[0]);
    return context_dispatch_admissions;
}
