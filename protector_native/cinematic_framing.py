"""Explicit per-shot framing for source-bound, frame-preserving movie masters."""
from __future__ import annotations


def master_dimensions(value, *, full_picture: bool = False) -> tuple[int, int]:
    """Versioned, square-pixel masters; V2 adds UHD-height complete 4:3 picture."""
    allowed = ((3840, 2160), (2880, 2160)) if full_picture else ((3840, 2160),)
    if not isinstance(value, (list, tuple)) or len(value) != 2 or \
            any(type(n) is not int for n in value) or tuple(value) not in allowed:
        raise ValueError("explicit supported cinematic master dimensions required")
    return tuple(value)


def scan_filters(config: dict, frames: int) -> list[str]:
    """Explicit whole-movie or reviewed frame-range field reconstruction.

    Range ends are exclusive, just like shot coverage. The source decoder's
    frame index remains the clock; send_frame never creates extra frames.
    """
    treatment = config.get("deinterlace")
    if treatment not in ("none", "bwdif-tff", "bwdif-bff"):
        raise ValueError("declare source scan treatment; never infer interlacing from the file flag")
    ranges = config.get("deinterlace_ranges")
    if "deinterlace_ranges" in config:
        if config.get("schema") != "protector-native.cinematic-restoration/v2" or treatment == "none" or \
                not isinstance(ranges, list) or not 1 <= len(ranges) <= min(frames, 64):
            raise ValueError("selective deinterlacing requires explicit nonempty V2 frame ranges and parity")
        cursor = 0
        for row in ranges:
            if not isinstance(row, dict) or type(row.get("first")) is not int or \
                    type(row.get("end")) is not int or not cursor <= row["first"] < row["end"] <= frames or \
                    not isinstance(row.get("reason"), str) or not row["reason"].strip() or \
                    ("parity" in row and row["parity"] not in ("tff", "bff")):
                raise ValueError("scan ranges need ordered nonoverlapping source indices and reviewed reasons")
            cursor = row["end"]
    if treatment == "none":
        return []
    value = f"bwdif=mode=send_frame:parity={treatment.rsplit('-', 1)[1]}:deint=all"
    if ranges:
        # bwdif buffers its next frame, so its generic enable=N belongs to
        # the incoming lookahead, not the output picture. Select between two
        # timestamp-synchronized streams instead. blend's N is one-based;
        # the expression chooses whole planes, never averages their pixels.
        default = treatment.rsplit('-', 1)[1]
        parities = sorted({r.get("parity", default) for r in ranges})
        if len(parities) == 1:
            expression = "+".join(f"between(N\\,{r['first']+1}\\,{r['end']})" for r in ranges)
            value = f"split[scan_original][scan_input];[scan_input]" \
                    f"bwdif=mode=send_frame:parity={parities[0]}:deint=all[scan_fields];" \
                    f"[scan_original][scan_fields]blend=all_expr=if({expression}\\,B\\,A)"
        else:
            # Some original edit reels combine footage from different field
            # orders. Each reviewed shot selects its own same-index branch;
            # graphics and progressive shots retain the untouched branch.
            branches = ["split=3[scan_original][scan_input_bff][scan_input_tff]"]
            for parity in parities:
                branches.append(f"[scan_input_{parity}]bwdif=mode=send_frame:parity={parity}:deint=all[scan_fields_{parity}]")
            original = "scan_original"
            for i, parity in enumerate(parities):
                expression = "+".join(f"between(N\\,{r['first']+1}\\,{r['end']})"
                                      for r in ranges if r.get("parity", default) == parity)
                suffix = "[scan_selected]" if i == 0 else ""
                branches.append(f"[{original}][scan_fields_{parity}]blend=all_expr=if({expression}\\,B\\,A){suffix}")
                original = "scan_selected"
            value = ";".join(branches)
    return [value]


def validate_shots(shots: list, width: int, height: int, frames: int, *,
                   target: tuple[int, int] = (3840, 2160), full_picture: bool = False) -> list[dict]:
    target = master_dimensions(target, full_picture=full_picture)
    if not isinstance(shots, list) or not 1 <= len(shots) <= min(frames, 4096):
        raise ValueError("explicit, bounded shot coverage is required")
    cursor = 0
    for shot in shots:
        if not isinstance(shot, dict) or type(shot.get("first")) is not int or \
                type(shot.get("end")) is not int or shot["first"] != cursor or \
                not cursor < shot["end"] <= frames:
            raise ValueError("shots must cover every frame once, in contiguous order")
        cursor = shot["end"]
        rect = shot.get("crop")
        if not isinstance(rect, list) or len(rect) != 4 or any(type(n) is not int for n in rect):
            raise ValueError("shot crop must be four integer source-pixel coordinates")
        x, y, w, h = rect
        if min(x, y) < 0 or min(w, h) < 32 or x+w > width or y+h > height:
            raise ValueError("shot crop exceeds source bounds")
        if shot.get("mode") == "crop":
            if w*target[1] != h*target[0]:
                raise ValueError("a crop must have exactly the target proportions, never stretch")
        elif shot.get("mode") == "preserve" and full_picture:
            if rect != [0, 0, width, height] or width*target[1] != height*target[0]:
                raise ValueError("preserve requires the complete source picture at its exact aspect")
        elif shot.get("mode") == "solid-extend":
            rgb = shot.get("matte_rgb")
            if not isinstance(rgb, list) or len(rgb) != 3 or \
                    any(type(n) is not int or not 0 <= n <= 255 for n in rgb):
                raise ValueError("solid extension needs an explicit source background color")
            if type(shot.get("edge_tolerance")) is not int or not 0 <= shot["edge_tolerance"] <= 8:
                raise ValueError("solid extension needs a bounded source edge tolerance")
        else:
            raise ValueError("unknown shot treatment; framing cannot be inferred")
        if not isinstance(shot.get("reason"), str) or not shot["reason"].strip():
            raise ValueError("each shot needs its composition rationale")
    if cursor != frames:
        raise ValueError("shot coverage stops before the original movie ends")
    return shots


def fitted_size(width: int, height: int, target: tuple[int, int]) -> tuple[int, int]:
    """Integer-pixel aspect fit, with at most half a target pixel of rounding."""
    if width*target[1] > height*target[0]:
        return target[0], round(height*target[0]/width)
    return round(width*target[1]/height), target[1]


def verify_extension_edges(rgb, shot: dict) -> None:
    """Reject solid extensions when the source actually reaches an open edge."""
    if shot["mode"] != "solid-extend":
        return
    import numpy as np
    _, _, width, height = shot["crop"]
    if rgb.shape != (height, width, 3) or rgb.dtype != np.uint8:
        raise ValueError("source crop must be exact RGB8 pixels")
    if width*9 == height*16:
        return
    edges = np.concatenate((rgb[:, :2].reshape(-1, 3), rgb[:, -2:].reshape(-1, 3))) \
        if width*9 < height*16 else np.concatenate((rgb[:2].reshape(-1, 3), rgb[-2:].reshape(-1, 3)))
    if int(np.abs(edges.astype(np.int16)-np.asarray(shot["matte_rgb"], dtype=np.int16)).max()) > shot["edge_tolerance"]:
        raise ValueError("nonuniform source edges cannot be extended with a solid field")
