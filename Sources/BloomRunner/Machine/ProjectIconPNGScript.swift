import Foundation

/// Kept as source rather than a loose package file so a release cannot omit the decoder while the
/// Runner still compiles. Python is part of the machine image and is already required by the
/// installer. The script accepts PNG only and never interprets metadata as a URL or a command.
enum ProjectIconPNGScript {
    static let source = #"""
import binascii
import math
import os
import struct
import sys
import zlib

MAX_SOURCE = 512 * 1024
MAX_DIMENSION = 2048
MAX_PIXELS = 2048 * 2048
OUTPUT = 256
INVALID = 42

def require(condition):
    if not condition:
        raise ValueError("invalid image")

def paeth(left, above, upper_left):
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left

def chunk(kind, contents):
    checksum = binascii.crc32(kind + contents) & 0xffffffff
    return struct.pack(">I", len(contents)) + kind + contents + struct.pack(">I", checksum)

def read_png(path):
    with open(path, "rb") as source:
        data = source.read(MAX_SOURCE + 1)
    require(len(data) <= MAX_SOURCE and data.startswith(b"\x89PNG\r\n\x1a\n"))

    position = 8
    header = None
    palette = None
    transparency = None
    compressed = bytearray()
    ended = False
    while position < len(data):
        require(position + 12 <= len(data))
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        end = position + 12 + length
        require(length <= MAX_SOURCE and end <= len(data))
        contents = data[position + 8:position + 8 + length]
        expected_crc = struct.unpack(">I", data[position + 8 + length:end])[0]
        require((binascii.crc32(kind + contents) & 0xffffffff) == expected_crc)
        position = end

        if kind == b"IHDR":
            require(header is None and length == 13 and position == 33)
            header = struct.unpack(">IIBBBBB", contents)
        elif kind == b"PLTE":
            require(palette is None and not compressed and length > 0 and length <= 768 and length % 3 == 0)
            palette = contents
        elif kind == b"tRNS":
            require(transparency is None and not compressed)
            transparency = contents
        elif kind == b"IDAT":
            require(header is not None)
            compressed.extend(contents)
            require(len(compressed) <= MAX_SOURCE)
        elif kind == b"IEND":
            require(length == 0 and header is not None and compressed and position == len(data))
            ended = True
            break
        elif kind[0] & 32 == 0:
            raise ValueError("unknown critical PNG chunk")
    require(ended and header is not None)

    width, height, depth, colour, compression, filtering, interlace = header
    require(32 <= width <= MAX_DIMENSION and 32 <= height <= MAX_DIMENSION)
    require(width * height <= MAX_PIXELS and max(width / height, height / width) <= 2)
    require(depth == 8 and compression == 0 and filtering == 0 and interlace == 0)
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    require(channels is not None)
    if colour == 3:
        require(palette is not None)
    expected = (width * channels + 1) * height
    decoder = zlib.decompressobj()
    raw = decoder.decompress(bytes(compressed), expected + 1)
    require(len(raw) <= expected and not decoder.unconsumed_tail)
    raw += decoder.flush()
    require(decoder.eof and not decoder.unused_data and len(raw) == expected)

    rows = []
    previous = bytearray(width * channels)
    offset = 0
    for _ in range(height):
        filter_kind = raw[offset]
        offset += 1
        current = bytearray(raw[offset:offset + width * channels])
        offset += width * channels
        require(filter_kind <= 4)
        for index in range(len(current)):
            left = current[index - channels] if index >= channels else 0
            above = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_kind == 1:
                current[index] = (current[index] + left) & 255
            elif filter_kind == 2:
                current[index] = (current[index] + above) & 255
            elif filter_kind == 3:
                current[index] = (current[index] + ((left + above) // 2)) & 255
            elif filter_kind == 4:
                current[index] = (current[index] + paeth(left, above, upper_left)) & 255
        rows.append(current)
        previous = current

    rgba = bytearray(width * height * 4)
    transparent_gray = struct.unpack(">H", transparency)[0] if colour == 0 and transparency and len(transparency) == 2 else None
    transparent_rgb = struct.unpack(">HHH", transparency) if colour == 2 and transparency and len(transparency) == 6 else None
    palette_alpha = transparency or b""
    for y, row in enumerate(rows):
        for x in range(width):
            source = x * channels
            target = (y * width + x) * 4
            if colour == 0:
                gray = row[source]
                pixel = (gray, gray, gray, 0 if transparent_gray == gray else 255)
            elif colour == 2:
                red, green, blue = row[source:source + 3]
                pixel = (red, green, blue, 0 if transparent_rgb == (red, green, blue) else 255)
            elif colour == 3:
                index = row[source]
                require(index * 3 + 2 < len(palette))
                pixel = (
                    palette[index * 3], palette[index * 3 + 1], palette[index * 3 + 2],
                    palette_alpha[index] if index < len(palette_alpha) else 255,
                )
            elif colour == 4:
                gray, alpha = row[source:source + 2]
                pixel = (gray, gray, gray, alpha)
            else:
                pixel = row[source:source + 4]
            rgba[target:target + 4] = pixel
    return width, height, rgba

def bilinear(source, width, height, rendered_width, rendered_height):
    result = bytearray(rendered_width * rendered_height * 4)
    for y in range(rendered_height):
        source_y = (y + 0.5) * height / rendered_height - 0.5
        y0 = max(0, min(height - 1, math.floor(source_y)))
        y1 = max(0, min(height - 1, y0 + 1))
        wy = max(0.0, min(1.0, source_y - y0))
        for x in range(rendered_width):
            source_x = (x + 0.5) * width / rendered_width - 0.5
            x0 = max(0, min(width - 1, math.floor(source_x)))
            x1 = max(0, min(width - 1, x0 + 1))
            wx = max(0.0, min(1.0, source_x - x0))
            samples = (
                ((y0 * width + x0) * 4, (1 - wx) * (1 - wy)),
                ((y0 * width + x1) * 4, wx * (1 - wy)),
                ((y1 * width + x0) * 4, (1 - wx) * wy),
                ((y1 * width + x1) * 4, wx * wy),
            )
            alpha = sum(source[index + 3] * weight for index, weight in samples)
            target = (y * rendered_width + x) * 4
            result[target + 3] = max(0, min(255, int(alpha + 0.5)))
            if alpha > 0:
                for channel in range(3):
                    premultiplied = sum(
                        source[index + channel] * source[index + 3] * weight
                        for index, weight in samples
                    )
                    result[target + channel] = max(0, min(255, int(premultiplied / alpha + 0.5)))
    return result

def write_png(path, width, height, source):
    scale = min(OUTPUT / width, OUTPUT / height)
    rendered_width = max(1, int(width * scale + 0.5))
    rendered_height = max(1, int(height * scale + 0.5))
    left = (OUTPUT - rendered_width) // 2
    top = (OUTPUT - rendered_height) // 2
    rendered = bilinear(source, width, height, rendered_width, rendered_height)
    canvas = bytearray(OUTPUT * OUTPUT * 4)
    for y in range(rendered_height):
        source_start = y * rendered_width * 4
        target_start = ((top + y) * OUTPUT + left) * 4
        canvas[target_start:target_start + rendered_width * 4] = rendered[source_start:source_start + rendered_width * 4]

    scanlines = b"".join(
        b"\x00" + canvas[y * OUTPUT * 4:(y + 1) * OUTPUT * 4]
        for y in range(OUTPUT)
    )
    header = struct.pack(">IIBBBBB", OUTPUT, OUTPUT, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
    png += chunk(b"IDAT", zlib.compress(scanlines, 9)) + chunk(b"IEND", b"")
    require(len(png) <= MAX_SOURCE)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as destination:
        destination.write(png)

def main():
    require(len(sys.argv) == 3)
    width, height, pixels = read_png(sys.argv[1])
    write_png(sys.argv[2], width, height, pixels)

try:
    main()
except (AssertionError, OSError, ValueError, struct.error, zlib.error):
    sys.exit(INVALID)
"""#
}
