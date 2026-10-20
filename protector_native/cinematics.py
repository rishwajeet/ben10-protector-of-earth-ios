"""Source-only Bink 1 timing admission for the local cinematic restoration lane.

Field offsets are cross-checked against FFmpeg's Bink demuxer, not inferred from
filenames: https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/bink.c
This reads a header; it neither decodes a movie nor certifies a usable crop.
"""
from __future__ import annotations

from fractions import Fraction
import struct


def bink_header(data: bytes, file_size: int) -> dict:
    if len(data) < 44:
        raise ValueError("truncated Bink header")
    signature, declared, frames, maximum, _, width, height, numerator, denominator, flags, tracks = \
        struct.unpack_from("<4s10I", data)
    if signature != b"BIKi":
        raise ValueError("only the source title's Bink 1 revision i is admitted")
    if declared + 8 != file_size or maximum < 1 or maximum > file_size:
        raise ValueError("Bink file length or maximum frame size is invalid")
    if not 1 <= frames <= 1_000_000 or not 1 <= width <= 7680 or not 1 <= height <= 4800:
        raise ValueError("Bink frame count or dimensions are out of bounds")
    if not numerator or not denominator or not Fraction(1, 1) <= Fraction(numerator, denominator) <= 120:
        raise ValueError("Bink frame rate is invalid")
    if tracks > 256:
        raise ValueError("Bink audio track count is out of bounds")
    rate = Fraction(numerator, denominator)
    duration = frames / rate
    return {"signature": signature.decode("ascii"), "width": width, "height": height,
        "frame_count": frames, "frame_rate": str(rate), "frame_rate_numerator": rate.numerator,
        "frame_rate_denominator": rate.denominator, "duration_seconds": float(duration),
        "duration_exact": str(duration), "audio_tracks": tracks, "flags": flags,
        "maximum_frame_bytes": maximum}


def verify_probe(header: dict, probe: dict) -> list[dict]:
    streams = probe.get("streams", [])
    video = [s for s in streams if s.get("codec_type") == "video"]
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    if len(video) != 1 or len(audio) != header["audio_tracks"]:
        raise ValueError("decoder/header stream counts disagree")
    stream = video[0]
    if stream.get("codec_name") != "binkvideo" or any(stream.get(k) != header[k] for k in ("width", "height")):
        raise ValueError("decoder/header codec or dimensions disagree")
    rate = Fraction(header["frame_rate"])
    if Fraction(stream.get("r_frame_rate", "0")) != rate or \
            Fraction(stream.get("time_base", "0")) != 1 / rate or stream.get("duration_ts") != header["frame_count"]:
        raise ValueError("decoder/header frame timing disagrees")
    return audio


def review_frame_indices(frame_count: int, count: int = 6) -> list[int]:
    if type(frame_count) is not int or frame_count < 1 or type(count) is not int or not 1 <= count <= 12:
        raise ValueError("invalid bounded review sample")
    # Interior, equally spaced samples avoid taking every first/last fade as a
    # framing observation. Still only a sample: no full-movie crop acceptance.
    return sorted({min(frame_count-1, (2*i+1)*frame_count//(2*count)) for i in range(count)})


def linear_movie_plane(rgba: bytes, width: int, height: int) -> bytes:
    """Recover the movie's linear plane from its audited GX I8 texture.

    Interface audits contain the generic GX decoder's RGBA interpretation.
    Re-serializing 8x4 I8 tiles recovers the Bink buffer for independent decoder
    comparison. All four I8 channels must be the exact same intensity.
    """
    if type(width) is not int or type(height) is not int or width % 8 or height % 4 or \
            not 8 <= width <= 7680 or not 4 <= height <= 4800 or len(rgba) != width*height*4:
        raise ValueError("movie plane dimensions or byte length are invalid")
    gray = rgba[0::4]
    if any(rgba[c::4] != gray for c in (1, 2, 3)):
        raise ValueError("movie plane must be an exact I8 intensity/alpha texture")
    return b"".join(gray[(y+row)*width+x:(y+row)*width+x+8]
                    for y in range(0, height, 4) for x in range(0, width, 8) for row in range(4))


def compare_movie_planes(actual: tuple[bytes, bytes, bytes], decoded: bytes,
                         width: int, height: int) -> dict:
    """Exact Y/U/V parity only; not perceptual quality or presentation framing."""
    if type(width) is not int or type(height) is not int or width < 2 or height < 2 or width % 2 or height % 2:
        raise ValueError("even movie dimensions required")
    sizes = (width*height, width*height//4, width*height//4)
    if len(decoded) != sum(sizes) or len(actual) != 3 or tuple(map(len, actual)) != sizes:
        raise ValueError("decoded frame/plane byte count disagrees")
    cursor = 0
    result = {}
    for name, size, plane in zip(("Y", "U", "V"), sizes, actual):
        reference = decoded[cursor:cursor+size]
        result[name] = {"bytes": size, "exact": plane == reference,
            "different_bytes": sum(a != b for a, b in zip(plane, reference))}
        cursor += size
    return {"exact": all(v["exact"] for v in result.values()), "planes": result}
