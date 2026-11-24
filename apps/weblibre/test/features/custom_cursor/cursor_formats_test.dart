import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:weblibre/features/custom_cursor/domain/cursor_formats.dart';

/// The cursors below are built byte by byte so the expected pixels are worked
/// out by hand, not produced by the code under test.

Uint8List _u16(int v) => (ByteData(2)..setUint16(0, v, Endian.little))
    .buffer
    .asUint8List();
Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little))
    .buffer
    .asUint8List();

/// A 2x2, 8 bpp cursor with hotspot (1, 0).
///
/// Top row:    red, blue (masked, so transparent)
/// Bottom row: blue, red
Uint8List _cur2x2({int hotX = 1, int hotY = 0}) {
  final dib = BytesBuilder()
    ..add(_u32(40)) // header size
    ..add(_u32(2)) // width
    ..add(_u32(4)) // height, doubled for the AND mask
    ..add(_u16(1)) // planes
    ..add(_u16(8)) // bpp
    ..add(_u32(0)) // compression
    ..add(_u32(0)) // image size
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(2)) // colours used
    ..add(_u32(0))
    ..add([0, 0, 255, 0]) // palette 0: red (B, G, R, reserved)
    ..add([255, 0, 0, 0]) // palette 1: blue
    ..add([1, 0, 0, 0]) // stored first: bottom row = blue, red
    ..add([0, 1, 0, 0]) // top row = red, blue
    ..add([0, 0, 0, 0]) // mask, bottom row: nothing masked
    ..add([0x40, 0, 0, 0]); // mask, top row: second pixel masked
  final data = dib.takeBytes();
  expect(data.length, 64);

  return (BytesBuilder()
        ..add([0, 0, 2, 0, 1, 0]) // ICONDIR: type 2 (cursor), one image
        ..add([2, 2, 2, 0]) // width, height, colours, reserved
        ..add(_u16(hotX))
        ..add(_u16(hotY))
        ..add(_u32(data.length))
        ..add(_u32(22)) // offset
        ..add(data))
      .takeBytes();
}

Uint8List _chunk(String id, List<int> body) {
  final b = BytesBuilder()
    ..add(id.codeUnits)
    ..add(_u32(body.length))
    ..add(body);
  if (body.length.isOdd) b.addByte(0);
  return b.takeBytes();
}

/// An `.ani` of two frames, 6 and 12 jiffies long (100 ms and 200 ms).
Uint8List _ani({int flags = 1}) {
  final anih = BytesBuilder()
    ..add(_u32(36))
    ..add(_u32(2)) // frames
    ..add(_u32(2)) // steps
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(0))
    ..add(_u32(6)) // default rate in jiffies
    ..add(_u32(flags));
  final frames = BytesBuilder()
    ..add('fram'.codeUnits)
    ..add(_chunk('icon', _cur2x2(hotX: 0)))
    ..add(_chunk('icon', _cur2x2(hotX: 1)));
  final body = BytesBuilder()
    ..add('ACON'.codeUnits)
    ..add(_chunk('anih', anih.takeBytes()))
    ..add(_chunk('rate', [..._u32(6), ..._u32(12)]))
    ..add(_chunk('LIST', frames.takeBytes()));
  final bytes = body.takeBytes();
  return (BytesBuilder()
        ..add('RIFF'.codeUnits)
        ..add(_u32(bytes.length))
        ..add(bytes))
      .takeBytes();
}

/// Decodes the PNGs this feature writes (RGBA, filter 0) back to raw pixels.
Uint8List _pngPixels(Uint8List png, int width, int height) {
  final bd = ByteData.sublistView(png);
  final idat = BytesBuilder();
  var o = 8;
  while (o + 8 <= png.length) {
    final length = bd.getUint32(o, Endian.big);
    final type = String.fromCharCodes(png.sublist(o + 4, o + 8));
    if (type == 'IDAT') idat.add(png.sublist(o + 8, o + 8 + length));
    o += 12 + length;
  }
  final raw = zlib.decode(idat.takeBytes());
  final out = BytesBuilder();
  for (var y = 0; y < height; y++) {
    final row = y * (width * 4 + 1);
    expect(raw[row], 0, reason: 'filter byte');
    out.add(raw.sublist(row + 1, row + 1 + width * 4));
  }
  return out.takeBytes();
}

void main() {
  group('.cur', () {
    test('reads size, hotspot and pixels, with the AND mask as alpha', () {
      final parsed = parseCursorFile(_cur2x2(), 'test.cur');

      expect(parsed.animated, isFalse);
      expect(parsed.needsHotspot, isFalse);
      final frame = parsed.frames.single;
      expect(frame.width, 2);
      expect(frame.height, 2);
      expect(frame.hotX, 1);
      expect(frame.hotY, 0);

      expect(_pngPixels(frame.png, 2, 2), [
        255, 0, 0, 255, /**/ 0, 0, 255, 0, // top: red, masked blue
        0, 0, 255, 255, /**/ 255, 0, 0, 255, // bottom: blue, red
      ]);
    });

    test('keeps a 32 bpp alpha channel and ignores the mask then', () {
      final dib = BytesBuilder()
        ..add(_u32(40))
        ..add(_u32(1))
        ..add(_u32(2)) // 1x1, doubled
        ..add(_u16(1))
        ..add(_u16(32))
        ..add(_u32(0))
        ..add(_u32(0))
        ..add(_u32(0))
        ..add(_u32(0))
        ..add(_u32(0))
        ..add(_u32(0))
        ..add([10, 20, 30, 128]) // B, G, R, A
        ..add([0x80, 0, 0, 0]); // mask says transparent; alpha must win
      final data = dib.takeBytes();
      final cur = (BytesBuilder()
            ..add([0, 0, 2, 0, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0])
            ..add(_u32(data.length))
            ..add(_u32(22))
            ..add(data))
          .takeBytes();

      final frame = parseCursorFile(cur, 'alpha.cur').frames.single;
      expect(_pngPixels(frame.png, 1, 1), [30, 20, 10, 128]);
    });

    test('clamps a hotspot that lies outside the image', () {
      final frame = parseCursorFile(
        _cur2x2(hotX: 99, hotY: 99),
        'x.cur',
      ).frames.single;
      expect((frame.hotX, frame.hotY), (1, 1));
    });
  });

  group('.ani', () {
    test('keeps every frame, its hotspot and its rate', () {
      final parsed = parseCursorFile(_ani(), 'test.ani');

      expect(parsed.animated, isTrue);
      expect(parsed.frames, hasLength(2));
      expect(parsed.frames.map((f) => f.delayMs), [100, 200]);
      expect(parsed.frames.map((f) => f.hotX), [0, 1]);
    });

    test('refuses animations made of raw bitmaps', () {
      expect(
        () => parseCursorFile(_ani(flags: 0), 'raw.ani'),
        throwsA(isA<CursorFormatException>()),
      );
    });
  });

  group('.png', () {
    test('is accepted as is and asks for a hotspot', () {
      final rgba = Uint8List.fromList([1, 2, 3, 255, 4, 5, 6, 255]);
      final png = encodePng(2, 1, rgba);

      final parsed = parseCursorFile(png, 'pointer.png');

      expect(parsed.needsHotspot, isTrue);
      expect(parsed.frames.single.width, 2);
      expect(parsed.frames.single.height, 1);
      expect(_pngPixels(parsed.frames.single.png, 2, 1), rgba);
    });

    test('withHotspot clamps into the image', () {
      final frame = parseCursorFile(
        encodePng(2, 1, Uint8List(8)),
        'p.png',
      ).frames.single.withHotspot(50, -3);
      expect((frame.hotX, frame.hotY), (1, 0));
    });
  });

  group('bad input', () {
    test('rejects files that are not cursors', () {
      expect(
        () => parseCursorFile(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]), 'a'),
        throwsA(isA<CursorFormatException>()),
      );
    });

    test('rejects a truncated cursor instead of throwing a RangeError', () {
      final cur = _cur2x2();
      expect(
        () => parseCursorFile(Uint8List.sublistView(cur, 0, 30), 'cut.cur'),
        throwsA(isA<CursorFormatException>()),
      );
    });

    test('rejects oversized files', () {
      expect(
        () => parseCursorFile(Uint8List(maxCursorFileBytes + 1), 'big.cur'),
        throwsA(isA<CursorFormatException>()),
      );
    });
  });
}
