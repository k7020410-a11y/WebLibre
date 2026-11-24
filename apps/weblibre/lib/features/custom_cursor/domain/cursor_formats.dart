/*
 * This file is part of WebLibre (see https://weblibre.eu).
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:io' show zlib;
import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart readers for the cursor formats the custom-cursor feature imports.
///
/// Everything here is deliberately dependency-free (no `dart:ui`, no image
/// package) so it can be unit tested on the host VM, and so a hostile file can
/// only ever cost an exception, never reach a native decoder.
///
/// Supported input:
///  * `.cur` / `.ico` — Windows cursor/icon directories whose images are either
///    embedded PNG or classic DIB (1, 4, 8, 24 and 32 bpp, uncompressed, with
///    the AND transparency mask). The hotspot is read from the directory entry.
///  * `.ani` — RIFF `ACON` animated cursors made of `.cur` frames, including the
///    optional `rate` and `seq ` chunks.
///  * `.png` — taken as is; the hotspot defaults to (0, 0) and is chosen by the
///    user.
///
/// Not supported: OS/2 bitmaps, RLE or BITFIELDS compression, 16 bpp, and `.ani`
/// files whose frames are raw bitmaps instead of icons (`AF_ICON` unset).
/// Windows' "invert screen" cursors cannot be expressed on Android; the
/// inverting pixels become transparent.

/// Thrown for any file that is not a usable cursor.
class CursorFormatException implements Exception {
  final String message;

  const CursorFormatException(this.message);

  @override
  String toString() => 'CursorFormatException: $message';
}

/// One image of a cursor, always stored as PNG so it can be shown by Flutter
/// and handed to Android unchanged.
class CursorFrame {
  final Uint8List png;
  final int width;
  final int height;

  /// Hotspot in source pixels, from the top-left corner.
  final int hotX;
  final int hotY;

  /// How long this frame is shown when the cursor is animated.
  final int delayMs;

  const CursorFrame({
    required this.png,
    required this.width,
    required this.height,
    required this.hotX,
    required this.hotY,
    this.delayMs = defaultDelayMs,
  });

  static const defaultDelayMs = 100;

  CursorFrame withHotspot(int x, int y) => CursorFrame(
    png: png,
    width: width,
    height: height,
    hotX: x.clamp(0, width - 1).toInt(),
    hotY: y.clamp(0, height - 1).toInt(),
    delayMs: delayMs,
  );
}

/// The frames of a cursor in playback order. A static cursor has one frame.
class ParsedCursor {
  final List<CursorFrame> frames;

  /// Whether the file was a bare PNG, whose hotspot the user still has to pick.
  final bool needsHotspot;

  const ParsedCursor(this.frames, {this.needsHotspot = false});

  bool get animated => frames.length > 1;
}

/// Imports are refused above this size; real cursors are a few kilobytes.
const maxCursorFileBytes = 4 * 1024 * 1024;

const _maxDimension = 256;
const _maxSteps = 512;
const _minDelayMs = 16;

/// Parses [bytes] by sniffing their content, not their name, so a renamed file
/// still works. [fileName] is only used to word the error.
ParsedCursor parseCursorFile(Uint8List bytes, String fileName) {
  if (bytes.length > maxCursorFileBytes) {
    throw const CursorFormatException('File is too large');
  }
  try {
    if (_isPng(bytes)) {
      return ParsedCursor([_pngFrame(bytes, 0, 0)], needsHotspot: true);
    }
    if (bytes.length >= 12 &&
        _ascii(bytes, 0, 4) == 'RIFF' &&
        _ascii(bytes, 8, 4) == 'ACON') {
      return _parseAni(bytes);
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0 &&
        bytes[1] == 0 &&
        (bytes[2] == 1 || bytes[2] == 2) &&
        bytes[3] == 0) {
      return ParsedCursor([_parseDirectory(bytes, CursorFrame.defaultDelayMs)]);
    }
  } on RangeError {
    throw CursorFormatException('$fileName is truncated or corrupt');
  }
  throw CursorFormatException('$fileName is not a .cur, .ani or .png file');
}

// ---------------------------------------------------------------- helpers --

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

bool _isPng(Uint8List b) {
  if (b.length < 8) return false;
  for (var i = 0; i < 8; i++) {
    if (b[i] != _pngSignature[i]) return false;
  }
  return true;
}

String _ascii(Uint8List b, int offset, int length) =>
    String.fromCharCodes(b.sublist(offset, offset + length));

CursorFrame _pngFrame(Uint8List png, int hotX, int hotY, {int? delayMs}) {
  // IHDR is the first chunk: 8 signature + 4 length + 4 type, then width and
  // height as big-endian 32-bit integers.
  if (png.length < 24 || _ascii(png, 12, 4) != 'IHDR') {
    throw const CursorFormatException('PNG has no header');
  }
  final bd = ByteData.sublistView(png);
  final w = bd.getUint32(16, Endian.big);
  final h = bd.getUint32(20, Endian.big);
  _checkSize(w, h);
  return CursorFrame(
    png: Uint8List.fromList(png),
    width: w,
    height: h,
    hotX: hotX.clamp(0, w - 1).toInt(),
    hotY: hotY.clamp(0, h - 1).toInt(),
    delayMs: delayMs ?? CursorFrame.defaultDelayMs,
  );
}

void _checkSize(int w, int h) {
  if (w <= 0 || h <= 0 || w > _maxDimension || h > _maxDimension) {
    throw CursorFormatException(
      'Unsupported image size ${w}x$h (max ${_maxDimension}x$_maxDimension)',
    );
  }
}

// ------------------------------------------------------------- .cur / .ico --

/// Reads the largest image of a `.cur`/`.ico` directory.
CursorFrame _parseDirectory(Uint8List b, int delayMs) {
  final bd = ByteData.sublistView(b);
  final type = bd.getUint16(2, Endian.little);
  final count = bd.getUint16(4, Endian.little);
  if (count == 0) throw const CursorFormatException('Cursor has no images');

  var best = -1;
  var bestArea = -1;
  for (var i = 0; i < count; i++) {
    final base = 6 + 16 * i;
    if (base + 16 > b.length) {
      throw const CursorFormatException('Cursor directory is truncated');
    }
    final w = b[base] == 0 ? 256 : b[base];
    final h = b[base + 1] == 0 ? 256 : b[base + 1];
    if (w * h > bestArea) {
      bestArea = w * h;
      best = i;
    }
  }

  final base = 6 + 16 * best;
  // For cursors (type 2) these two fields are the hotspot; for icons they are
  // planes/bit count, so an icon gets the top-left corner.
  final hotX = type == 2 ? bd.getUint16(base + 4, Endian.little) : 0;
  final hotY = type == 2 ? bd.getUint16(base + 6, Endian.little) : 0;
  final size = bd.getUint32(base + 8, Endian.little);
  final offset = bd.getUint32(base + 12, Endian.little);
  if (size == 0 || offset + size > b.length) {
    throw const CursorFormatException('Cursor image lies outside the file');
  }
  final data = Uint8List.sublistView(b, offset, offset + size);

  if (_isPng(data)) {
    return _pngFrame(data, hotX, hotY, delayMs: delayMs);
  }

  final image = _decodeDib(data);
  return CursorFrame(
    png: encodePng(image.width, image.height, image.rgba),
    width: image.width,
    height: image.height,
    hotX: hotX.clamp(0, image.width - 1).toInt(),
    hotY: hotY.clamp(0, image.height - 1).toInt(),
    delayMs: delayMs,
  );
}

class _Rgba {
  final int width;
  final int height;
  final Uint8List rgba;

  const _Rgba(this.width, this.height, this.rgba);
}

/// Decodes the DIB stored in a cursor: a BITMAPINFOHEADER whose height counts
/// both the colour bitmap and the 1 bpp AND mask below it.
_Rgba _decodeDib(Uint8List data) {
  final bd = ByteData.sublistView(data);
  final headerSize = bd.getUint32(0, Endian.little);
  if (headerSize < 40) {
    throw const CursorFormatException('Unsupported bitmap header');
  }
  final width = bd.getInt32(4, Endian.little);
  final rawHeight = bd.getInt32(8, Endian.little);
  final bpp = bd.getUint16(14, Endian.little);
  final compression = bd.getUint32(16, Endian.little);
  final colorsUsed = bd.getUint32(32, Endian.little);

  final topDown = rawHeight < 0;
  final height = rawHeight.abs() ~/ 2;
  _checkSize(width, height);
  if (compression != 0) {
    throw const CursorFormatException('Compressed bitmaps are not supported');
  }
  if (!const [1, 4, 8, 24, 32].contains(bpp)) {
    throw CursorFormatException('Unsupported colour depth: $bpp bpp');
  }

  final paletteSize = bpp <= 8
      ? (colorsUsed == 0 ? (1 << bpp) : math.min(colorsUsed, 1 << bpp))
      : 0;
  final paletteOffset = headerSize;
  final pixelOffset = paletteOffset + paletteSize * 4;
  final rowBytes = ((width * bpp + 31) ~/ 32) * 4;
  final maskOffset = pixelOffset + rowBytes * height;
  final maskRowBytes = ((width + 31) ~/ 32) * 4;

  if (maskOffset > data.length) {
    throw const CursorFormatException('Bitmap data is truncated');
  }
  final hasMask = maskOffset + maskRowBytes * height <= data.length;

  final rgba = Uint8List(width * height * 4);
  var anyAlpha = false;

  for (var y = 0; y < height; y++) {
    final storedRow = topDown ? y : height - 1 - y;
    final row = pixelOffset + storedRow * rowBytes;
    for (var x = 0; x < width; x++) {
      int r, g, b, a = 255;
      if (bpp == 32) {
        b = data[row + 4 * x];
        g = data[row + 4 * x + 1];
        r = data[row + 4 * x + 2];
        a = data[row + 4 * x + 3];
        if (a != 0) anyAlpha = true;
      } else if (bpp == 24) {
        b = data[row + 3 * x];
        g = data[row + 3 * x + 1];
        r = data[row + 3 * x + 2];
      } else {
        // 8, 4 or 1 bpp: palette indices.
          final int index;
          if (bpp == 8) {
            index = data[row + x];
          } else if (bpp == 4) {
            final v = data[row + (x >> 1)];
            index = (x & 1) == 0 ? (v >> 4) : (v & 15);
          } else {
            index = (data[row + (x >> 3)] >> (7 - (x & 7))) & 1;
          }
          final entry = paletteOffset + 4 * index;
          b = _paletteByte(data, entry, paletteOffset, pixelOffset);
          g = _paletteByte(data, entry + 1, paletteOffset, pixelOffset);
          r = _paletteByte(data, entry + 2, paletteOffset, pixelOffset);
      }
      final o = (y * width + x) * 4;
      rgba[o] = r;
      rgba[o + 1] = g;
      rgba[o + 2] = b;
      rgba[o + 3] = a;
    }
  }

  // A 32 bpp image with a real alpha channel ignores the mask; every other
  // image is opaque except where the AND mask is set.
  final alphaFromImage = bpp == 32 && anyAlpha;
  if (!alphaFromImage) {
    for (var y = 0; y < height; y++) {
      final storedRow = topDown ? y : height - 1 - y;
      final maskRow = maskOffset + storedRow * maskRowBytes;
      for (var x = 0; x < width; x++) {
        final masked =
            hasMask && ((data[maskRow + (x >> 3)] >> (7 - (x & 7))) & 1) == 1;
        rgba[(y * width + x) * 4 + 3] = masked ? 0 : 255;
      }
    }
  }

  return _Rgba(width, height, rgba);
}

/// Reads one palette byte, refusing indices that point past the palette.
int _paletteByte(Uint8List data, int index, int start, int end) {
  if (index < start || index >= end) {
    throw const CursorFormatException('Colour index outside the palette');
  }
  return data[index];
}

// ------------------------------------------------------------------- .ani --

ParsedCursor _parseAni(Uint8List b) {
  final bd = ByteData.sublistView(b);
  final riffEnd = math.min(b.length, 8 + bd.getUint32(4, Endian.little));

  var jiffies = 10;
  var flags = 0;
  List<int>? rates;
  List<int>? sequence;
  final frameData = <Uint8List>[];

  var offset = 12;
  while (offset + 8 <= riffEnd) {
    final id = _ascii(b, offset, 4);
    final size = bd.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    final end = math.min(start + size, riffEnd);

    switch (id) {
      case 'anih':
        if (end - start >= 36) {
          jiffies = bd.getUint32(start + 28, Endian.little);
          flags = bd.getUint32(start + 32, Endian.little);
        }
      case 'rate':
        rates = [
          for (var o = start; o + 4 <= end; o += 4)
            bd.getUint32(o, Endian.little),
        ];
      case 'seq ':
        sequence = [
          for (var o = start; o + 4 <= end; o += 4)
            bd.getUint32(o, Endian.little),
        ];
      case 'LIST':
        if (end - start >= 4 && _ascii(b, start, 4) == 'fram') {
          var o = start + 4;
          while (o + 8 <= end) {
            final subId = _ascii(b, o, 4);
            final subSize = bd.getUint32(o + 4, Endian.little);
            final subStart = o + 8;
            final subEnd = math.min(subStart + subSize, end);
            if (subId == 'icon') {
              if (frameData.length >= _maxSteps) {
                throw const CursorFormatException('Too many animation frames');
              }
              frameData.add(Uint8List.sublistView(b, subStart, subEnd));
            }
            o = subStart + subSize + (subSize & 1);
          }
        }
    }
    offset = start + size + (size & 1);
  }

  if ((flags & 0x1) == 0) {
    throw const CursorFormatException(
      'Animated cursors made of raw bitmaps are not supported',
    );
  }
  if (frameData.isEmpty) {
    throw const CursorFormatException('Animated cursor has no frames');
  }
  final stepCount = (flags & 0x2) != 0 && sequence != null && sequence.isNotEmpty
      ? math.min(sequence.length, _maxSteps)
      : frameData.length;

  int delayFor(int step) {
    final j = (rates != null && step < rates.length) ? rates[step] : jiffies;
    // A jiffy is 1/60 s.
    return math.max(_minDelayMs, ((j == 0 ? 10 : j) * 1000 / 60).round());
  }

  // Each distinct frame is decoded once, then reused for repeated steps.
  final decoded = <int, CursorFrame>{};
  CursorFrame frameAt(int index) {
    if (index < 0 || index >= frameData.length) {
      throw const CursorFormatException('Animation refers to a missing frame');
    }
    return decoded[index] ??= _parseDirectory(
      frameData[index],
      CursorFrame.defaultDelayMs,
    );
  }

  final frames = <CursorFrame>[];
  for (var step = 0; step < stepCount; step++) {
    final index = (flags & 0x2) != 0 && sequence != null && sequence.isNotEmpty
        ? sequence[step]
        : step;
    final base = frameAt(index);
    frames.add(
      CursorFrame(
        png: base.png,
        width: base.width,
        height: base.height,
        hotX: base.hotX,
        hotY: base.hotY,
        delayMs: delayFor(step),
      ),
    );
  }
  return ParsedCursor(frames);
}

// -------------------------------------------------------------------- PNG --

/// Encodes straight (non-premultiplied) RGBA as an 8-bit PNG.
Uint8List encodePng(int width, int height, Uint8List rgba) {
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter: none
    raw.add(Uint8List.sublistView(rgba, y * width * 4, (y + 1) * width * 4));
  }

  final header = ByteData(13)
    ..setUint32(0, width, Endian.big)
    ..setUint32(4, height, Endian.big)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6); // colour type: RGBA

  final out = BytesBuilder(copy: false)..add(_pngSignature);
  _writeChunk(out, 'IHDR', header.buffer.asUint8List());
  _writeChunk(out, 'IDAT', Uint8List.fromList(zlib.encode(raw.takeBytes())));
  _writeChunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _writeChunk(BytesBuilder out, String type, Uint8List data) {
  final length = ByteData(4)..setUint32(0, data.length, Endian.big);
  final typeBytes = Uint8List.fromList(type.codeUnits);
  out
    ..add(length.buffer.asUint8List())
    ..add(typeBytes)
    ..add(data);
  var crc = 0xFFFFFFFF;
  for (final byte in typeBytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  final crcBytes = ByteData(4)
    ..setUint32(0, (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF, Endian.big);
  out.add(crcBytes.buffer.asUint8List());
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});
