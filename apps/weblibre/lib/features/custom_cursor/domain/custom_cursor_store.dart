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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:weblibre/features/custom_cursor/domain/cursor_formats.dart';

/// User choices for the custom cursor. Kept out of the app's settings database
/// on purpose: it is a small, self-contained feature stored beside the cursor
/// files it refers to.
class CustomCursorSettings {
  /// Master switch. Off by default; nothing changes until it is turned on.
  final bool enabled;

  /// The [CursorEntry.id] in use, if any.
  final String? selectedId;

  /// 100 draws one source pixel as 0.6 dp, which is what a 32 px Windows
  /// cursor measures at 96 dpi.
  final int sizePercent;

  /// Use the cursor when not in Samsung DeX too. For testing on a device or
  /// emulator where DeX cannot be detected.
  final bool applyOutsideDex;

  /// Play `.ani` animations in the browser's own UI. Web pages always get a
  /// still frame.
  final bool animateInUi;

  const CustomCursorSettings({
    this.enabled = false,
    this.selectedId,
    this.sizePercent = 100,
    this.applyOutsideDex = false,
    this.animateInUi = true,
  });

  static const minSizePercent = 50;
  static const maxSizePercent = 400;

  CustomCursorSettings copyWith({
    bool? enabled,
    Object? selectedId = _keep,
    int? sizePercent,
    bool? applyOutsideDex,
    bool? animateInUi,
  }) => CustomCursorSettings(
    enabled: enabled ?? this.enabled,
    selectedId: identical(selectedId, _keep)
        ? this.selectedId
        : selectedId as String?,
    sizePercent: (sizePercent ?? this.sizePercent)
        .clamp(minSizePercent, maxSizePercent)
        .toInt(),
    applyOutsideDex: applyOutsideDex ?? this.applyOutsideDex,
    animateInUi: animateInUi ?? this.animateInUi,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'selectedId': selectedId,
    'sizePercent': sizePercent,
    'applyOutsideDex': applyOutsideDex,
    'animateInUi': animateInUi,
  };

  factory CustomCursorSettings.fromJson(Map<String, Object?> json) =>
      CustomCursorSettings(
        enabled: json['enabled'] == true,
        selectedId: json['selectedId'] as String?,
        sizePercent: ((json['sizePercent'] as num?)?.toInt() ?? 100)
            .clamp(minSizePercent, maxSizePercent)
            .toInt(),
        applyOutsideDex: json['applyOutsideDex'] == true,
        animateInUi: json['animateInUi'] != false,
      );

  static const _keep = Object();
}

/// An imported cursor.
class CursorEntry {
  final String id;
  final String name;
  final List<CursorFrame> frames;

  const CursorEntry({
    required this.id,
    required this.name,
    required this.frames,
  });

  CursorFrame get first => frames.first;
  bool get animated => frames.length > 1;
}

/// Reads and writes imported cursors under `<app support>/custom_cursors/`:
///
/// ```
/// settings.json
/// <id>/meta.json        name and, per frame, file/hotspot/size/delay
/// <id>/<n>.png          one file per distinct image
/// ```
class CustomCursorStore {
  /// Upper bound so a runaway import loop cannot fill the profile.
  static const maxCursors = 64;

  final Future<Directory> Function() _rootProvider;
  Future<Directory>? _root;

  CustomCursorStore({Future<Directory> Function()? rootProvider})
    : _rootProvider =
          rootProvider ??
          (() async {
            final support = await path_provider
                .getApplicationSupportDirectory();
            return Directory(p.join(support.path, 'custom_cursors'));
          });

  Future<Directory> _directory() => _root ??= _rootProvider().then((dir) async {
    await dir.create(recursive: true);
    return dir;
  });

  Future<CustomCursorSettings> readSettings() async {
    try {
      final file = File(p.join((await _directory()).path, 'settings.json'));
      if (!await file.exists()) return const CustomCursorSettings();
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, Object?>) {
        return CustomCursorSettings.fromJson(json);
      }
    } on FormatException {
      // A damaged settings file falls back to the defaults.
    } on FileSystemException {
      // Same: unreadable means "not configured".
    }
    return const CustomCursorSettings();
  }

  Future<void> writeSettings(CustomCursorSettings settings) async {
    final dir = await _directory();
    final temp = File(p.join(dir.path, 'settings.json.tmp'));
    await temp.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await temp.rename(p.join(dir.path, 'settings.json'));
  }

  Future<List<CursorEntry>> list() async {
    final root = await _directory();
    final entries = <CursorEntry>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final entry = await _readEntry(entity);
      if (entry != null) entries.add(entry);
    }
    entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return entries;
  }

  Future<CursorEntry?> _readEntry(Directory dir) async {
    try {
      final meta = File(p.join(dir.path, 'meta.json'));
      if (!await meta.exists()) return null;
      final json = jsonDecode(await meta.readAsString());
      if (json is! Map<String, Object?>) return null;

      final images = <String, Uint8List>{};
      final frames = <CursorFrame>[];
      for (final raw in (json['frames'] as List<Object?>? ?? const [])) {
        final f = raw as Map<String, Object?>;
        final fileName = f['file'] as String;
        // The names come from our own metadata, but never let one escape the
        // cursor's directory.
        if (fileName != p.basename(fileName)) return null;
        final png = images[fileName] ??= await File(
          p.join(dir.path, fileName),
        ).readAsBytes();
        frames.add(
          CursorFrame(
            png: png,
            width: (f['w'] as num).toInt(),
            height: (f['h'] as num).toInt(),
            hotX: (f['hotX'] as num).toInt(),
            hotY: (f['hotY'] as num).toInt(),
            delayMs: (f['delayMs'] as num?)?.toInt() ?? 100,
          ),
        );
      }
      if (frames.isEmpty) return null;
      return CursorEntry(
        id: p.basename(dir.path),
        name: (json['name'] as String?) ?? p.basename(dir.path),
        frames: frames,
      );
    } on Object {
      // One broken cursor must not hide the others.
      return null;
    }
  }

  Future<CursorEntry> add(String name, List<CursorFrame> frames) async {
    final root = await _directory();
    if ((await root.list().where((e) => e is Directory).length) >= maxCursors) {
      throw const CursorFormatException('Too many cursors imported');
    }
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final dir = Directory(p.join(root.path, id));
    await dir.create();
    await _writeEntry(dir, name, frames);
    return CursorEntry(id: id, name: name, frames: frames);
  }

  /// Rewrites the hotspot of every frame (they share one in practice).
  Future<CursorEntry?> updateHotspot(CursorEntry entry, int x, int y) async {
    final root = await _directory();
    final frames = [for (final f in entry.frames) f.withHotspot(x, y)];
    await _writeEntry(Directory(p.join(root.path, entry.id)), entry.name, frames);
    return CursorEntry(id: entry.id, name: entry.name, frames: frames);
  }

  Future<void> remove(String id) async {
    final root = await _directory();
    if (id != p.basename(id) || id.isEmpty) return;
    final dir = Directory(p.join(root.path, id));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> _writeEntry(
    Directory dir,
    String name,
    List<CursorFrame> frames,
  ) async {
    // Identical images (an animation reusing a frame) are written once.
    final fileFor = Map<Uint8List, String>.identity();
    final frameJson = <Map<String, Object?>>[];
    for (final frame in frames) {
      final file = fileFor.putIfAbsent(frame.png, () => '${fileFor.length}.png');
      frameJson.add({
        'file': file,
        'w': frame.width,
        'h': frame.height,
        'hotX': frame.hotX,
        'hotY': frame.hotY,
        'delayMs': frame.delayMs,
      });
    }
    for (final e in fileFor.entries) {
      await File(p.join(dir.path, e.value)).writeAsBytes(e.key, flush: true);
    }
    final temp = File(p.join(dir.path, 'meta.json.tmp'));
    await temp.writeAsString(
      jsonEncode({'name': name, 'frames': frameJson}),
      flush: true,
    );
    await temp.rename(p.join(dir.path, 'meta.json'));
  }
}
