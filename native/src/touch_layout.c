#include "protector/touch_layout.h"
#include <math.h>

static ProtectorTouchRect rect(double x, double y, double width, double height) {
    return (ProtectorTouchRect){x, y, width, height};
}

static void mirror(ProtectorTouchRect* value, double left, double width) {
    value->x = left + width - (value->x - left) - value->width;
}

bool protector_touch_layout(double width, double height, ProtectorTouchInsets insets,
                            double scale, bool swapped, ProtectorTouchLayout* layout) {
    if (!layout || !isfinite(width) || !isfinite(height) || !isfinite(scale) ||
        !isfinite(insets.top) || !isfinite(insets.left) ||
        !isfinite(insets.bottom) || !isfinite(insets.right) ||
        insets.top < 0 || insets.left < 0 || insets.bottom < 0 || insets.right < 0)
        return false;
    const double safe_width = width - insets.left - insets.right;
    const double safe_height = height - insets.top - insets.bottom;
    if (safe_width < 480 || safe_height < 260) return false;
    /* Even a large saved preference must fit the smallest supported phone.
     * Native settings remain scrollable independently of this game layout. */
    const double fit = fmin((safe_width - 48) / 414.0, (safe_height - 76) / 180.0);
    const double s = fmin(fmin(fmax(scale, 0.85), 1.25), fit);
    const double left = insets.left + 12;
    const double right = width - insets.right - 12;
    const double bottom = height - insets.bottom - 12;
    const double top = insets.top + 8;
    ProtectorTouchLayout value = {0};
    value.effective_scale = s;
    value.stick = rect(left + 20 * s, bottom - 112 * s, 112 * s, 112 * s);
    value.actions[0] = rect(right - 146 * s, bottom - 72 * s, 72 * s, 72 * s);
    value.actions[1] = rect(right - 62 * s, bottom - 138 * s, 56 * s, 56 * s);
    value.actions[2] = rect(right - 212 * s, bottom - 62 * s, 56 * s, 56 * s);
    value.actions[3] = rect(right - 64 * s, bottom - 64 * s, 64 * s, 64 * s);
    value.actions[4] = rect(left, top, 64, 44);
    value.actions[5] = rect(left + 72, top, 52, 44);
    /* Alien cycling surrounds Transform, with at least 44pt touch targets. */
    const double small = fmax(44, 44 * s);
    /* The optional Transform caption remains at least 11pt even at the
     * smallest control preference; 56pt also enlarges its original hit area. */
    const double transform = fmax(56, 56 * s);
    const double omnitrix_y = bottom - 112 * s - 12 - transform;
    value.actions[6] = rect(left, omnitrix_y + (transform - small) / 2, small, small);
    value.actions[7] = rect(left + small + 8, omnitrix_y, transform, transform);
    value.actions[8] = rect(left + small + transform + 16,
                            omnitrix_y + (transform - small) / 2, small, small);
    value.actions[9] = rect(right - 132 * s, bottom - 138 * s, 56 * s, 56 * s);
    value.actions[10] = rect(right - 100, top, 44, 44);
    value.pause = rect(right - 44, top, 44, 44);
    if (swapped) {
        mirror(&value.stick, insets.left, safe_width);
        for (unsigned i = 0; i < PROTECTOR_TOUCH_ACTION_COUNT; ++i)
            if (i != 4 && i != 5 && i != 10)
                mirror(&value.actions[i], insets.left, safe_width);
        /* Move the group, not the meaning of its directional arrows. */
        const ProtectorTouchRect previous = value.actions[6];
        value.actions[6] = value.actions[8];
        value.actions[8] = previous;
    }
    *layout = value;
    return true;
}

bool protector_touch_menu_layout(double width, double height, ProtectorTouchInsets insets,
                                 double scale, bool swapped, ProtectorTouchLayout* layout) {
    ProtectorTouchLayout value;
    if (!layout || !protector_touch_layout(width, height, insets, scale, false, &value)) return false;
    const double s = value.effective_scale;
    const double d = fmax(44, 48 * s), gap = 8;
    const double left = insets.left + 12, right = width - insets.right - 12;
    const double bottom = height - insets.bottom - 12;
    const double middle = bottom - 2 * d - gap;
    value.actions[6] = rect(left, middle, d, d);
    value.actions[7] = rect(left + d + gap, bottom - 3 * d - 2 * gap, d, d);
    value.actions[8] = rect(left + 2 * (d + gap), middle, d, d);
    value.actions[9] = rect(left + d + gap, bottom - d, d, d);
    const double confirm_width = fmax(88, 88 * s), confirm_height = fmax(64, 64 * s);
    /* A labeled symbol needs room for both the 24pt icon and its caption. */
    const double back_width = fmax(64, 64 * s), back_height = fmax(64, 64 * s);
    value.actions[0] = rect(right - confirm_width, bottom - confirm_height,
                            confirm_width, confirm_height);
    value.actions[5] = rect(right - confirm_width - gap - back_width,
                            bottom - back_height, back_width, back_height);
    if (swapped) {
        const double safe_width = width - insets.left - insets.right;
        const unsigned visible[] = {0, 5, 6, 7, 8, 9};
        for (unsigned i = 0; i < sizeof(visible) / sizeof(visible[0]); ++i)
            mirror(&value.actions[visible[i]], insets.left, safe_width);
        const ProtectorTouchRect previous = value.actions[6];
        value.actions[6] = value.actions[8];
        value.actions[8] = previous;
    }
    *layout = value;
    return true;
}

bool protector_touch_gallery_layout(double width, double height, ProtectorTouchInsets insets,
                                    double scale, bool swapped, ProtectorTouchLayout* layout) {
    ProtectorTouchLayout value;
    if (!layout || !protector_touch_menu_layout(width, height, insets, scale, swapped, &value))
        return false;
    const ProtectorTouchRect confirm = value.actions[0];
    ProtectorTouchRect* back = &value.actions[5];
    back->x = swapped ? confirm.x : confirm.x + confirm.width - back->width;
    back->y = confirm.y - 8 - back->height;
    *layout = value;
    return true;
}

bool protector_touch_extras_layout(double width, double height, ProtectorTouchInsets insets,
                                   double scale, bool swapped, ProtectorTouchLayout* layout) {
    ProtectorTouchLayout value;
    if (!layout || !protector_touch_gallery_layout(width, height, insets, scale, swapped, &value))
        return false;
    /* Preserve every hit size and vertical gap. A two-column diamond clears
     * the source grid's edge columns without shrinking the user's controls. */
    const double left = insets.left + 12, step = value.actions[6].width + 8;
    value.actions[6].x = left;
    value.actions[7].x = left + step / 2;
    value.actions[8].x = left + step;
    value.actions[9].x = left + step / 2;
    if (swapped) {
        const double safe_width = width - insets.left - insets.right;
        const unsigned visible[] = {6, 7, 8, 9};
        for (unsigned i = 0; i < sizeof(visible) / sizeof(visible[0]); ++i)
            mirror(&value.actions[visible[i]], insets.left, safe_width);
        const ProtectorTouchRect previous = value.actions[6];
        value.actions[6] = value.actions[8];
        value.actions[8] = previous;
    }
    *layout = value;
    return true;
}

bool protector_touch_viewer_layout(double width, double height, ProtectorTouchInsets insets,
                                   double scale, bool swapped, ProtectorTouchLayout* layout) {
    ProtectorTouchLayout value;
    if (!layout || !protector_touch_menu_layout(width,height,insets,scale,false,&value)) return false;
    const double right=width-insets.right-12, bottom=height-insets.bottom-12;
    value.actions[5].x=right-value.actions[5].width;
    value.actions[5].y=bottom-value.actions[5].height;
    if (swapped) {
        mirror(&value.stick,insets.left,width-insets.left-insets.right);
        mirror(&value.actions[5],insets.left,width-insets.left-insets.right);
    }
    *layout=value;
    return true;
}

bool protector_touch_upgrade_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorTouchLayout* layout, ProtectorTouchRect* content) {
    ProtectorTouchLayout value;
    if (!layout || !content || !protector_touch_menu_layout(width,height,insets,scale,false,&value)) return false;
    const double left=insets.left+12, right=width-insets.right-12;
    const double top=insets.top+8, bottom=height-insets.bottom-12;
    const double d=value.actions[6].width, w=value.actions[0].width, h=value.actions[0].height;
    const double side_height=fmin(height,(right-left-2*(fmax(d,w)+12))*3.0/4.0);
    const double footer_height=fmin(bottom-fmax(d,h)-12-top,(right-left)*3.0/4.0);
    ProtectorTouchRect frame;
    if (side_height>=footer_height) {
        if (side_height<=0) return false;
        frame=rect((left+right-side_height*4.0/3.0)/2,(height-side_height)/2,
                   side_height*4.0/3.0,side_height);
        value.actions[6]=rect(left,bottom-2*d-8,d,d);
        value.actions[8]=rect(left,bottom-d,d,d);
    } else {
        if (footer_height<=0) return false;
        frame=rect((left+right-footer_height*4.0/3.0)/2,top,footer_height*4.0/3.0,footer_height);
        value.actions[6]=rect(left,bottom-d,d,d);
        value.actions[8]=rect(left+d+8,bottom-d,d,d);
    }
    if (swapped) {
        const double safe_width=width-insets.left-insets.right;
        for (unsigned i=0;i<3;++i) {
            const unsigned index=i==0 ? 0 : i==1 ? 6 : 8;
            mirror(&value.actions[index],insets.left,safe_width);
        }
        if (value.actions[6].y==value.actions[8].y) {
            const ProtectorTouchRect previous=value.actions[6];
            value.actions[6]=value.actions[8];value.actions[8]=previous;
        }
    }
    *layout=value;*content=frame;
    return true;
}

bool protector_touch_combo_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorTouchLayout* layout, ProtectorTouchRect* content) {
    ProtectorTouchLayout value;
    if (!layout || !content || !protector_touch_menu_layout(width, height, insets, scale, false, &value))
        return false;
    const double left = insets.left + 12, right = width - insets.right - 12;
    const double bottom = height - insets.bottom - 12;
    const double d = value.actions[6].width, b = value.actions[5].width;
    const double source_width = height * 4.0 / 3.0, source_left = (width - source_width) / 2;
    ProtectorTouchRect frame = rect(source_left, 0, source_width, height);
    value.actions[5] = rect(right - b, bottom - b, b, b);
    if (source_left - left >= fmax(d, b) + 12 &&
        right - source_left - source_width >= fmax(d, b) + 12) {
        /* Both handedness choices clear the entire source panel. */
        value.actions[6] = rect(left, bottom - 2 * d - 8, d, d);
        value.actions[8] = rect(left, bottom - d, d, d);
    } else {
        value.actions[6] = rect(left, bottom - d, d, d);
        value.actions[8] = rect(left + d + 8, bottom - d, d, d);
        const double top = insets.top + 8;
        const double room = bottom - fmax(d, b) - 12 - top;
        const double frame_height = fmin(room, (right - left) * 3.0 / 4.0);
        if (frame_height <= 0) return false;
        frame = rect((left + right - frame_height * 4.0 / 3.0) / 2, top,
                     frame_height * 4.0 / 3.0, frame_height);
    }
    if (swapped) {
        const double safe_width = width - insets.left - insets.right;
        mirror(&value.actions[5], insets.left, safe_width);
        mirror(&value.actions[6], insets.left, safe_width);
        mirror(&value.actions[8], insets.left, safe_width);
        /* Horizontal ordering only: stacked previous remains above next. */
        if (value.actions[6].y == value.actions[8].y) {
            const ProtectorTouchRect previous = value.actions[6];
            value.actions[6] = value.actions[8]; value.actions[8] = previous;
        }
    }
    *layout = value;
    *content = frame;
    return true;
}

bool protector_touch_map_layout(double width, double height, ProtectorTouchInsets insets,
                                double scale, bool swapped, ProtectorTouchLayout* layout) {
    ProtectorTouchLayout value;
    if (!layout || !protector_touch_menu_layout(width, height, insets, scale, false, &value))
        return false;
    const double s = value.effective_scale, gap = 8;
    const double right = width - insets.right - 12;
    const double h = fmax(44, 48 * s);
    const double replay = fmax(88, 88 * s), challenge = fmax(104, 104 * s);
    const double y = value.actions[0].y - gap - h;
    value.actions[2] = rect(right - challenge - gap - replay, y, replay, h);
    value.actions[3] = rect(right - challenge, y, challenge, h);
    if (swapped) {
        const double safe_width = width - insets.left - insets.right;
        mirror(&value.stick, insets.left, safe_width);
        const unsigned visible[] = {0, 2, 3, 5};
        for (unsigned i = 0; i < sizeof(visible) / sizeof(visible[0]); ++i)
            mirror(&value.actions[visible[i]], insets.left, safe_width);
    }
    *layout = value;
    return true;
}

bool protector_touch_map_content_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorMapContentLayout* content) {
    ProtectorTouchLayout controls;
    if (!content || !protector_touch_map_layout(width,height,insets,scale,swapped,&controls)) return false;
    const double gap=12, left=insets.left+gap, right=width-insets.right-gap;
    const double top=insets.top+8, bottom=height-insets.bottom-gap;
    /* The source header remains one complete ornament/text group. Only its
     * destination is native; no lettering or extra frame is invented. */
    const double title_height=fmin(72,fmax(40,(height-insets.top-insets.bottom)*.11));
    const double title_right=fmin(right,controls.pause.x-gap);
    const double title_width=fmin(title_right-left,title_height*(464.0/60.0)*(14.0/15.0));
    const double title_x=fmin((left+right-title_width)/2,title_right-title_width);
    const double card_top=top+title_height+gap;
    const double card_bottom=fmin(controls.stick.y,fmin(controls.actions[0].y,controls.actions[5].y))-gap;
    double hint_left=left, hint_right=right;
    const double middle=(left+right)/2;
    const ProtectorTouchRect occupied[]={controls.stick,controls.actions[0],controls.actions[5]};
    for (unsigned i=0;i<3;i++) {
        const ProtectorTouchRect item=occupied[i];
        if (item.x+item.width/2<middle) hint_left=fmax(hint_left,item.x+item.width+gap);
        else hint_right=fmin(hint_right,item.x-gap);
    }
    /* Source help quads are 32 units tall but their painted glyphs occupy only
     * about 12. Reserve enough height for readable ink, independently of the
     * postcard fit. The width constraint still protects either control hand. */
    const double hint_height=fmin(40,fmax(36,(height-insets.top-insets.bottom)*.05));
    if (title_width<=0 || title_x<left || card_bottom-card_top<60 || hint_right-hint_left<120) return false;
    *content=(ProtectorMapContentLayout){
        rect(title_x,top,title_width,title_height),
        rect(left,card_top,right-left,card_bottom-card_top),
        rect(hint_left,bottom-hint_height,hint_right-hint_left,hint_height)
    };
    return true;
}

bool protector_touch_native_hud_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorTouchLayout* layout, ProtectorTouchRect* hud) {
    ProtectorTouchLayout value;
    if (!layout || !hud || !protector_touch_layout(width, height, insets, scale, swapped, &value))
        return false;
    const double left = insets.left + 12, top = insets.top + 8;
    /* Same actions and target sizes, one row. No extra floating HUD chrome. */
    value.actions[5].x = value.actions[10].x - 8 - value.actions[5].width;
    value.actions[4].x = value.actions[5].x - 8 - value.actions[4].width;
    const double room = value.actions[4].x - 12 - left;
    if (room <= 0) return false;
    double sx = fmin(0.75, room / 277.0);
    /* Original TV pixels are anamorphic. Preserve the watch's displayed shape:
     * source x uses 640/(4:3)=480 units; source y uses the 448-line viewport. */
    const double y_ratio = 480.0 / 448.0;
    const double right = left + 277 * sx;
    for (unsigned i = 0; i < PROTECTOR_TOUCH_ACTION_COUNT + 1; ++i) {
        if (i == 4 || i == 5 || i == 10) continue;
        const ProtectorTouchRect item = i == PROTECTOR_TOUCH_ACTION_COUNT ? value.stick : value.actions[i];
        if (item.x < right + 8 && item.x + item.width > left - 8)
            sx = fmin(sx, (item.y - 8 - top) / (120 * y_ratio));
    }
    if (!isfinite(sx) || sx <= 0) return false;
    *hud = rect(left, top, 277 * sx, 120 * sx * y_ratio);
    *layout = value;
    return true;
}

bool protector_touch_combat_feedback_layout(double width, double height, ProtectorTouchInsets insets,
    double scale, bool swapped, ProtectorTouchRect* feedback) {
    ProtectorTouchLayout controls;
    if (!feedback || !protector_touch_layout(width,height,insets,scale,swapped,&controls)) return false;
    const double gap=12, bottom=height-insets.bottom-gap;
    /* Match centred-4:3 rendering's TV pixel shape, not a square-pixel guess. */
    const double nominal_width=PROTECTOR_COMBAT_FEEDBACK_WIDTH*height/480.0;
    const double nominal_height=PROTECTOR_COMBAT_FEEDBACK_HEIGHT*height/448.0;
    const double top=bottom-nominal_height;
    const double middle=(insets.left+width-insets.right)/2;
    double left=insets.left+gap, right=width-insets.right-gap;
    for (unsigned i=0;i<PROTECTOR_TOUCH_ACTION_COUNT+1;++i) {
        if (i==4 || i==5 || i==10) continue; /* Hidden legacy/top-row actions. */
        const ProtectorTouchRect item=i==PROTECTOR_TOUCH_ACTION_COUNT ? controls.stick : controls.actions[i];
        if (item.y+item.height+gap<=top || item.y-gap>=bottom) continue;
        if (item.x+item.width/2<middle) left=fmax(left,item.x+item.width+gap);
        else right=fmin(right,item.x-gap);
    }
    const double fit=fmin(1,(right-left)/nominal_width);
    if (!isfinite(fit) || fit<=0 || bottom-nominal_height*fit<insets.top+gap) return false;
    /* Only the smallest supported spaces need this bounded uniform fallback.
     * Its value depends on layout preferences, never count/pulse/visibility. */
    *feedback=rect(left,bottom-nominal_height*fit,nominal_width*fit,nominal_height*fit);
    return true;
}
