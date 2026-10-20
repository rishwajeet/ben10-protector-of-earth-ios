#include "protector/live_input.h"
#include "protector/qte_presentation.h"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static uint32_t read_word(const uint8_t* value) {
    return ((uint32_t)value[0] << 24) | ((uint32_t)value[1] << 16) |
           ((uint32_t)value[2] << 8) | value[3];
}

static float read_float(const uint8_t* value) {
    const uint32_t bits = read_word(value);
    float result;
    memcpy(&result, &bits, sizeof(result));
    return result;
}

static void qte_caption_placement_tests(void) {
    ProtectorQTERect result={1,2,3,4};
    const ProtectorQTERect safe={50,0,774,382};
    const ProtectorQTERect bottomTarget={315,272,90,90};
    assert(protector_qte_cue_rect(safe,160,40,bottomTarget,&result));
    assert(result.y==8 && result.x==357);
    assert(protector_qte_cue_rect(safe,160,40,(ProtectorQTERect){315,0,90,90},&result));
    assert(result.y==334);
    assert(protector_qte_cue_rect((ProtectorQTERect){0,24,1376,983},316,118,
        (ProtectorQTERect){420,700,230,230},&result));
    assert(result.y==32 && result.width==316 && result.height==118);
    assert(!protector_qte_cue_rect(safe,160,40,(ProtectorQTERect){0,0,1000,1000},&result));
    assert(!protector_qte_cue_rect(safe,160,400,(ProtectorQTERect){0},&result));
    assert(!protector_qte_cue_rect(safe,NAN,40,(ProtectorQTERect){0},&result));
    assert(!protector_qte_cue_rect(safe,160,40,(ProtectorQTERect){0},NULL));
}

static void pointer_geometry_tests(void) {
    float x = 7, y = 9;
    assert(protector_live_input_map_pointer(320, 240, 640, 480, &x, &y));
    assert(x == 0 && y == 0);
    assert(protector_live_input_map_pointer(0, 0, 640, 480, &x, &y));
    assert(x == -1 && y == -1);
    assert(protector_live_input_map_pointer(640, 480, 640, 480, &x, &y));
    assert(x == 1 && y == 1);
    // A native 2.2:1 phone fills its display; only the centred source menu
    // rectangle receives pointer input. There is no hit target on the HUD.
    assert(protector_live_input_map_pointer_for_aspect(396, 180, 792, 360, 2.2f, &x, &y));
    assert(x == 0 && y == 0);
    assert(protector_live_input_map_pointer_for_aspect(156, 0, 792, 360, 2.2f, &x, &y));
    assert(x == -1 && y == -1);
    assert(!protector_live_input_map_pointer_for_aspect(155, 0, 792, 360, 2.2f, &x, &y));
    assert(!protector_live_input_map_pointer_for_aspect(637, 100, 792, 360, 2.2f, &x, &y));
    assert(!protector_live_input_map_pointer_for_aspect(300, 100, 792, 360, NAN, &x, &y));
    assert(!protector_live_input_map_pointer_for_aspect(300, 100, 792, 360, 1, &x, &y));
    assert(!protector_live_input_map_pointer_for_aspect(300, 100, 792, 360, 4, &x, &y));
    assert(x == -1 && y == -1);
    // Landscape pillarbox: the game occupies x=200..1000, y=0..600.
    assert(protector_live_input_map_pointer(200, 0, 1200, 600, &x, &y));
    assert(x == -1 && y == -1);
    assert(!protector_live_input_map_pointer(199, 0, 1200, 600, &x, &y));
    assert(x == -1 && y == -1);
    assert(!protector_live_input_map_pointer(1001, 0, 1200, 600, &x, &y));
    // Portrait letterbox: the game occupies y=275..725, x=0..600.
    assert(protector_live_input_map_pointer(300, 500, 600, 1000, &x, &y));
    assert(x == 0 && y == 0);
    assert(!protector_live_input_map_pointer(300, 274, 600, 1000, &x, &y));
    assert(!protector_live_input_map_pointer(300, 726, 600, 1000, &x, &y));
    assert(!protector_live_input_map_pointer(0, 0, 0, 480, &x, &y));
    assert(!protector_live_input_map_pointer(0, 0, 640, -1, &x, &y));
    assert(!protector_live_input_map_pointer(NAN, 0, 640, 480, &x, &y));
    assert(!protector_live_input_map_pointer(0, INFINITY, 640, 480, &x, &y));
    assert(!protector_live_input_map_pointer(0, 0, INFINITY, 480, &x, &y));
    assert(!protector_live_input_map_pointer(0, 0, 640, 480, NULL, &y));
    assert(x == 0 && y == 0);
}

static void widescreen_pointer_geometry_tests(void) {
    float x = 7, y = 9;
    // A 4:3 tablet displays the 16:9 scene at y=75..525. Its centred original
    // HUD is x=100..700, not the full tablet rectangle or full scene width.
    assert(protector_live_input_map_pointer_for_presentation(400, 300, 800, 600, true, &x, &y));
    assert(x == 0 && y == 0);
    assert(protector_live_input_map_pointer_for_presentation(100, 75, 800, 600, true, &x, &y));
    assert(x == -1 && y == -1);
    assert(protector_live_input_map_pointer_for_presentation(700, 525, 800, 600, true, &x, &y));
    assert(x == 1 && y == 1);
    assert(!protector_live_input_map_pointer_for_presentation(99, 300, 800, 600, true, &x, &y));
    assert(!protector_live_input_map_pointer_for_presentation(400, 74, 800, 600, true, &x, &y));
    assert(!protector_live_input_map_pointer_for_presentation(701, 300, 800, 600, true, &x, &y));
    assert(!protector_live_input_map_pointer_for_presentation(400, 526, 800, 600, true, &x, &y));
    assert(x == 1 && y == 1);
    // A wide phone has no vertical bars; the same-height HUD mapping survives.
    assert(protector_live_input_map_pointer_for_presentation(200, 0, 1200, 600, true, &x, &y));
    assert(x == -1 && y == -1);
    assert(protector_live_input_map_pointer_for_presentation(1000, 600, 1200, 600, true, &x, &y));
    assert(x == 1 && y == 1);
}

static void qte_pointer_geometry_tests(void) {
    float x=7,y=9;
    const float widths[]={640,874,1366},heights[]={480,402,1024};
    for (unsigned i=0;i<3;++i) {
        const float width=widths[i],height=heights[i],aspect=width/height;
        const float target_x=-.1432450712f,target_y=.2881424129f;
        const float view_x=width*.5f+target_x*height*4.f/3.f;
        const float view_y=height*.5f+target_y*height;
        assert(protector_live_input_map_qte_pointer_for_aspect(view_x,view_y,width,height,aspect,&x,&y));
        assert(fabsf(x-target_x)<1e-6f && fabsf(y-target_y)<1e-6f);
        // The incumbent menu mapping remains independent and unchanged.
        assert(protector_live_input_map_pointer_for_aspect(view_x,view_y,width,height,aspect,&x,&y));
        assert(fabsf(x-2*target_x)<1e-6f && fabsf(y-2*target_y)<1e-6f);
    }
    assert(protector_live_input_map_qte_pointer_for_aspect(156,0,792,360,2.2f,&x,&y));
    assert(x==-.5f && y==-.5f);
    assert(protector_live_input_map_qte_pointer_for_aspect(636,360,792,360,2.2f,&x,&y));
    assert(x==.5f && y==.5f);
    assert(!protector_live_input_map_qte_pointer_for_aspect(155,0,792,360,2.2f,&x,&y));
    assert(!protector_live_input_map_qte_pointer_for_aspect(NAN,0,792,360,2.2f,&x,&y));
    assert(!protector_live_input_map_qte_pointer_for_aspect(0,0,792,360,NAN,&x,&y));
    assert(!protector_live_input_map_qte_pointer_for_aspect(0,0,792,360,2.2f,NULL,&y));
    assert(x==.5f && y==.5f);
}

static void pointer_and_motion_tests(void) {
    ProtectorLiveInputSample sample;
    ProtectorLiveInputDiagnostics diagnostics;
    protector_live_input_enable(true);
    protector_live_input_pointer(true, -0.5f, 0.25f);
    // Polling diagnostics must not consume a pending pointer or button edge.
    protector_live_input_update(PROTECTOR_BUTTON_A, 0, 0);
    protector_live_input_diagnostics(&diagnostics);
    assert(diagnostics.samples == 0);
    assert(protector_live_input_sample(&sample));
    assert(sample.pointer_valid && sample.pointer_x == -0.5f && sample.pointer_y == 0.25f);
    assert(sample.pointer_dx == 0 && sample.pointer_dy == 0);
    assert(sample.trigger == PROTECTOR_BUTTON_A);
    protector_live_input_pointer(true, 0.75f, -0.25f);
    assert(protector_live_input_sample(&sample));
    assert(sample.pointer_dx == 1.25f && sample.pointer_dy == -0.5f);
    assert(protector_live_input_sample(&sample));
    assert(sample.pointer_valid && sample.pointer_dx == 0 && sample.pointer_dy == 0);
    protector_live_input_pointer(false, 0, 0);
    assert(protector_live_input_sample(&sample) && !sample.pointer_valid);
    // A quick touch gets exactly one valid sample after it is lifted.
    protector_live_input_pointer(true, 4, -4);
    protector_live_input_pointer(false, 0, 0);
    assert(protector_live_input_sample(&sample) && sample.pointer_valid);
    assert(sample.pointer_x == 1 && sample.pointer_y == -1);
    assert(sample.pointer_dx == 0 && sample.pointer_dy == 0);
    assert(protector_live_input_sample(&sample) && !sample.pointer_valid);
    protector_live_input_pointer(true, 0.5f, 0.5f);
    protector_live_input_clear_pointer();
    assert(protector_live_input_sample(&sample) && !sample.pointer_valid);
    protector_live_input_pointer(true, NAN, INFINITY);
    assert(protector_live_input_sample(&sample) && !sample.pointer_valid);
    protector_live_input_motion(PROTECTOR_MOTION_WIIMOTE);
    const float expected[] = {3, 3, 3, 0, 0, 0, -3, -3, -3, 0, 0, 0, 3};
    float previous = 0;
    for (unsigned i = 0; i < sizeof(expected) / sizeof(*expected); ++i) {
        assert(protector_live_input_sample(&sample));
        assert(sample.wiimote_motion[0] == expected[i]);
        assert(sample.wiimote_motion[1] == -1 && sample.wiimote_motion[2] == 0);
        assert(sample.wiimote_motion[3] == hypotf(expected[i], 1));
        assert(sample.wiimote_motion[4] == fabsf(expected[i] - previous));
        assert(sample.nunchuk_motion[0] == 0 && sample.nunchuk_motion[1] == -1);
        assert(sample.nunchuk_motion[3] == 1 && sample.nunchuk_motion[4] == 0);
        previous = expected[i];
    }
    protector_live_input_motion(0);
    assert(protector_live_input_sample(&sample) && sample.wiimote_motion[0] == 0);
    assert(sample.wiimote_motion[4] == 0);
    protector_live_input_motion(PROTECTOR_MOTION_WIIMOTE | PROTECTOR_MOTION_NUNCHUK);
    protector_live_input_motion(0);
    assert(protector_live_input_sample(&sample));
    assert(sample.wiimote_motion[0] == 3 && sample.nunchuk_motion[0] == 3);
    assert(sample.wiimote_motion[1] == 3 && sample.nunchuk_motion[1] == -3);
    assert(protector_live_input_sample(&sample));
    assert(sample.wiimote_motion[0] == 0 && sample.nunchuk_motion[0] == 0);
    protector_live_input_motion(UINT32_MAX);
    protector_live_input_pointer(true, 1, 1);
    protector_live_input_cancel();
    assert(protector_live_input_sample(&sample));
    assert(!sample.pointer_valid && sample.wiimote_motion[0] == 0 && sample.nunchuk_motion[0] == 0);
    protector_live_input_diagnostics(&diagnostics);
    assert(diagnostics.pointer_samples == 4);
    assert(diagnostics.wiimote_motion_samples == 14 && diagnostics.nunchuk_motion_samples == 1);
    assert(!diagnostics.last.pointer_valid);
    const uint64_t samples = diagnostics.samples;
    protector_live_input_enable(false);
    protector_live_input_pointer(true, 1, 1);
    protector_live_input_motion(UINT32_MAX);
    assert(!protector_live_input_sample(&sample));
    assert(!sample.pointer_valid && sample.wiimote_motion[0] == 0 && sample.nunchuk_motion[0] == 0);
    protector_live_input_diagnostics(&diagnostics);
    assert(diagnostics.samples == samples); // retained for the final receipt
    protector_live_input_diagnostics(NULL);
}

static void paired_vertical_motion_tests(void) {
    /* Single-trigger behavior is covered above. Test every staggered start,
     * both initiation orders, KPAD propagation and release/cancellation. The
     * asset probe separately runs the actual source predicate/translated VM. */
    for (unsigned first = 0; first < 2; ++first) {
        for (unsigned delay = 0; delay < 12; ++delay) {
            ProtectorLiveInputSample sample;
            protector_live_input_enable(true);
            protector_live_input_motion(first ? PROTECTOR_MOTION_NUNCHUK : PROTECTOR_MOTION_WIIMOTE);
            for (unsigned i = 0; i < delay; ++i) assert(protector_live_input_sample(&sample));
            protector_live_input_motion(PROTECTOR_MOTION_WIIMOTE | PROTECTOR_MOTION_NUNCHUK);
            unsigned positive = 0, negative = 0;
            float previous_x[2] = {0}, previous_y[2] = {-1, -1};
            for (unsigned i = 0; i < 24; ++i) {
                assert(protector_live_input_sample(&sample));
                const float x = sample.wiimote_motion[0];
                const float a = sample.wiimote_motion[1], b = sample.nunchuk_motion[1];
                assert(x == sample.nunchuk_motion[0]);
                if (x == 0) assert(a == -1 && b == -1);
                else { assert(a == x && b == -x); positive += a > 0; negative += a < 0; }
                for (unsigned j = 0; j < 2; ++j) {
                    const float* v = j ? sample.nunchuk_motion : sample.wiimote_motion;
                    assert(v[3] == hypotf(v[0], v[1]));
                    if (i) assert(v[4] == hypotf(v[0] - previous_x[j], v[1] - previous_y[j]));
                    previous_x[j] = v[0]; previous_y[j] = v[1];
                }
                uint8_t status[PROTECTOR_KPAD_STATUS_SIZE] = {0};
                assert(protector_live_input_encode_kpad(&sample, status, sizeof(status)));
                assert(read_float(status + 0x10) == a && read_float(status + 0x6c) == b);
            }
            assert(positive == 6 && negative == 6);
            protector_live_input_motion(PROTECTOR_MOTION_WIIMOTE);
            assert(protector_live_input_sample(&sample));
            assert(sample.wiimote_motion[1] == -1 && sample.nunchuk_motion[1] == -1);
            protector_live_input_cancel();
            assert(protector_live_input_sample(&sample));
            assert(sample.wiimote_motion[0] == 0 && sample.nunchuk_motion[0] == 0);
            assert(sample.wiimote_motion[1] == -1 && sample.nunchuk_motion[1] == -1);
            assert(sample.wiimote_motion[4] == 0 && sample.nunchuk_motion[4] == 0);
        }
    }
    protector_live_input_enable(false);
}

static void camera_input_tests(void) {
    ProtectorLiveInputSample sample;
    ProtectorLiveInputDiagnostics diagnostics;
    protector_live_input_enable(true);
    protector_live_input_update(PROTECTOR_BUTTON_ONE,0,0);
    protector_live_input_update(0,0,0);
    protector_live_input_diagnostics(&diagnostics);
    assert(diagnostics.camera_samples == 0 && diagnostics.camera_trigger_samples == 0);
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == PROTECTOR_BUTTON_ONE && sample.trigger == PROTECTOR_BUTTON_ONE);
    uint8_t status[PROTECTOR_KPAD_STATUS_SIZE] = {0};
    assert(protector_live_input_encode_kpad(&sample,status,sizeof(status)));
    assert(read_word(status) == 0x0200 && read_word(status+4) == 0x0200);
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0 && sample.trigger == 0 && sample.release == PROTECTOR_BUTTON_ONE);
    protector_live_input_diagnostics(&diagnostics);
    assert(diagnostics.camera_samples == 1 && diagnostics.camera_trigger_samples == 1);
    protector_live_input_update(PROTECTOR_BUTTON_ONE,0,0);
    protector_live_input_cancel();
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0 && sample.trigger == 0);
    protector_live_input_diagnostics(&diagnostics);
    assert(diagnostics.camera_samples == 1 && diagnostics.camera_trigger_samples == 1);
    protector_live_input_enable(false);
}

static void kpad_encoding_tests(void) {
    uint8_t status[PROTECTOR_KPAD_STATUS_SIZE + 8];
    memset(status, 0xA5, sizeof(status));
    ProtectorLiveInputSample sample;
    protector_live_input_enable(true);
    protector_live_input_update(PROTECTOR_BUTTON_B, 0.5f, -0.75f);
    protector_live_input_pointer(true, -0.5f, 0.25f);
    protector_live_input_motion(PROTECTOR_MOTION_NUNCHUK);
    assert(protector_live_input_sample(&sample));
    assert(protector_live_input_encode_kpad(&sample, status, sizeof(status)));
    assert(read_word(status) == PROTECTOR_BUTTON_B);
    assert(read_word(status + 4) == PROTECTOR_BUTTON_B && read_word(status + 8) == 0);
    assert(read_float(status + 0x0C) == 0 && read_float(status + 0x10) == -1);
    assert(read_float(status + 0x18) == 1 && read_float(status + 0x1C) == 0);
    assert(read_float(status + 0x20) == -0.5f && read_float(status + 0x24) == 0.25f);
    assert(read_float(status + 0x28) == 0 && read_float(status + 0x30) == 0);
    assert(status[0x5E] == 2);
    assert(read_float(status + 0x60) == 0.5f && read_float(status + 0x64) == -0.75f);
    assert(read_float(status + 0x68) == 3 && read_float(status + 0x6C) == -1);
    assert(read_float(status + 0x74) == hypotf(3, 1) && read_float(status + 0x78) == 3);
    for (unsigned i = 0; i < sizeof(status); ++i) {
        const bool modified = i < 0x34 || i == 0x5E || (i >= 0x60 && i < 0x7C);
        if (!modified) assert(status[i] == 0xA5); // connection/calibration/tail retained
    }
    protector_live_input_pointer(true, 0.25f, -0.75f);
    assert(protector_live_input_sample(&sample));
    assert(protector_live_input_encode_kpad(&sample, status, sizeof(status)));
    assert(read_float(status + 0x28) == 0.75f && read_float(status + 0x2C) == -1);
    assert(read_float(status + 0x30) == 1.25f);
    uint8_t original[sizeof(status)];
    memcpy(original, status, sizeof(status));
    assert(!protector_live_input_encode_kpad(NULL, status, sizeof(status)));
    assert(!protector_live_input_encode_kpad(&sample, NULL, sizeof(status)));
    assert(!protector_live_input_encode_kpad(&sample, status, PROTECTOR_KPAD_STATUS_SIZE - 1));
    sample.pointer_dx = 3;
    assert(!protector_live_input_encode_kpad(&sample, status, sizeof(status)));
    sample.pointer_dx = 0;
    sample.nunchuk_motion[4] = NAN;
    assert(!protector_live_input_encode_kpad(&sample, status, sizeof(status)));
    assert(memcmp(original, status, sizeof(status)) == 0);
    protector_live_input_cancel();
    assert(protector_live_input_sample(&sample));
    assert(protector_live_input_encode_kpad(&sample, status, sizeof(status)));
    assert(status[0x5E] == 0 && read_float(status + 0x30) == 0);
    assert(read_float(status + 0x0C) == 0 && read_float(status + 0x68) == 0);
    assert(read_word(status + 8) == PROTECTOR_BUTTON_B);
    protector_live_input_enable(false);
}

int main(void) {
    ProtectorLiveInputSample sample;
    assert(!protector_live_input_enabled());
    assert(!protector_live_input_sample(&sample));
    protector_live_input_enable(true);
    assert(protector_live_input_enabled());
    protector_live_input_update(PROTECTOR_BUTTON_A, 0.5f, -0.25f);
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0x0800u && sample.trigger == 0x0800u);
    assert(sample.release == 0u && sample.stick_x == 0.5f);
    assert(sample.stick_y == -0.25f);
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0x0800u && sample.trigger == 0u);
    protector_live_input_update(PROTECTOR_BUTTON_B, 4.0f, -4.0f);
    assert(protector_live_input_sample(&sample));
    assert(sample.trigger == 0x0400u && sample.release == 0x0800u);
    assert(sample.stick_x == 1.0f && sample.stick_y == -1.0f);
    protector_live_input_update(0u, NAN, INFINITY);
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0u && sample.release == 0x0400u);
    assert(sample.stick_x == 0.0f && sample.stick_y == 0.0f);
    protector_live_input_update(PROTECTOR_BUTTON_A, 0, 0);
    protector_live_input_update(0, 0, 0);
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0x0800u && sample.trigger == 0x0800u);
    assert(sample.release == 0u); /* A quick tap is not lost. */
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0u && sample.trigger == 0u);
    assert(sample.release == 0x0800u);
    // Pending, unobserved taps must not turn into attacks after app resume.
    protector_live_input_update(PROTECTOR_BUTTON_A, 1, -1);
    protector_live_input_update(0, 0, 0);
    protector_live_input_cancel();
    assert(protector_live_input_enabled());
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0 && sample.trigger == 0 && sample.release == 0);
    assert(sample.stick_x == 0 && sample.stick_y == 0);
    // A previously delivered hold still needs a single up edge. Do not emit
    // a press for a different button queued since the last guest poll.
    protector_live_input_update(PROTECTOR_BUTTON_A, 1, -1);
    assert(protector_live_input_sample(&sample) && sample.hold == PROTECTOR_BUTTON_A);
    protector_live_input_update(PROTECTOR_BUTTON_B, -1, 1);
    protector_live_input_cancel();
    protector_live_input_cancel();
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0 && sample.trigger == 0 && sample.release == PROTECTOR_BUTTON_A);
    assert(sample.stick_x == 0 && sample.stick_y == 0);
    assert(protector_live_input_sample(&sample));
    assert(sample.hold == 0 && sample.trigger == 0 && sample.release == 0);
    protector_live_input_enable(false);
    protector_live_input_update(PROTECTOR_BUTTON_A, 1, 1);
    assert(!protector_live_input_sample(&sample));
    assert(sample.hold == 0 && sample.trigger == 0 && sample.release == 0);
    assert(!protector_live_input_sample(NULL));
    protector_live_input_cancel();
    assert(!protector_live_input_enabled());
    pointer_geometry_tests();
    widescreen_pointer_geometry_tests();
    qte_pointer_geometry_tests();
    qte_caption_placement_tests();
    pointer_and_motion_tests();
    paired_vertical_motion_tests();
    kpad_encoding_tests();
    camera_input_tests();
    puts("live input: edges, cancellation, pointer geometry, touch latching, motion, KPAD encoding passed");
    return 0;
}
