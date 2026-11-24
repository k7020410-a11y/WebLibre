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

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:weblibre/core/logger.dart';
import 'package:weblibre/features/custom_cursor/data/custom_cursor_channel.dart';
import 'package:weblibre/features/custom_cursor/domain/cursor_formats.dart';
import 'package:weblibre/features/custom_cursor/domain/custom_cursor_store.dart';

final customCursorStoreProvider = Provider<CustomCursorStore>(
  (ref) => CustomCursorStore(),
);

final customCursorChannelProvider = Provider<CustomCursorChannel>(
  (ref) => const CustomCursorChannel(),
);

@immutable
class CustomCursorState {
  final bool loaded;
  final CustomCursorSettings settings;
  final List<CursorEntry> entries;

  /// Whether Samsung DeX is active, as last asked of the platform.
  final bool desktopMode;

  /// Bumped whenever what the cursor looks like changes, so the Flutter
  /// cursor object is replaced and its session restarts.
  final int revision;

  /// Whether the native side accepted the frames and is overriding the
  /// cursor. [active] says it is wanted; this says it is really happening,
  /// and is what the UI follows, so a refusal falls back to the system cursor.
  final bool drawing;

  const CustomCursorState({
    this.loaded = false,
    this.settings = const CustomCursorSettings(),
    this.entries = const [],
    this.desktopMode = false,
    this.revision = 0,
    this.drawing = false,
  });

  CursorEntry? get selected {
    final id = settings.selectedId;
    if (id == null) return null;
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// Whether the custom cursor is drawn at all right now.
  bool get active =>
      loaded &&
      settings.enabled &&
      selected != null &&
      (desktopMode || settings.applyOutsideDex);

  CustomCursorState copyWith({
    bool? loaded,
    CustomCursorSettings? settings,
    List<CursorEntry>? entries,
    bool? desktopMode,
    int? revision,
    bool? drawing,
  }) => CustomCursorState(
    loaded: loaded ?? this.loaded,
    settings: settings ?? this.settings,
    entries: entries ?? this.entries,
    desktopMode: desktopMode ?? this.desktopMode,
    revision: revision ?? this.revision,
    drawing: drawing ?? this.drawing,
  );
}

/// Owns the imported cursors, the user's choices and the hand-off to the
/// native side.
///
/// Watches window metrics (which change when DeX starts or stops) and app
/// resume to keep [CustomCursorState.desktopMode] current. Metrics change on
/// every frame of a window resize, so the query is debounced.
class CustomCursorController extends Notifier<CustomCursorState>
    with WidgetsBindingObserver {
  Timer? _desktopDebounce;

  CustomCursorStore get _store => ref.read(customCursorStoreProvider);
  CustomCursorChannel get _channel => ref.read(customCursorChannelProvider);

  @override
  CustomCursorState build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _desktopDebounce?.cancel();
    });
    unawaited(_load());
    return const CustomCursorState();
  }

  @override
  void didChangeMetrics() => _scheduleDesktopRefresh();

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.resumed) _scheduleDesktopRefresh();
  }

  void _scheduleDesktopRefresh() {
    _desktopDebounce?.cancel();
    _desktopDebounce = Timer(const Duration(milliseconds: 400), () async {
      final desktop = await _channel.isDesktopMode();
      if (desktop != state.desktopMode) {
        state = state.copyWith(desktopMode: desktop);
        await _applyToNative();
      }
    });
  }

  Future<void> _load() async {
    try {
      final settings = await _store.readSettings();
      final entries = await _store.list();
      final desktop = await _channel.isDesktopMode();
      state = state.copyWith(
        loaded: true,
        settings: settings,
        entries: entries,
        desktopMode: desktop,
      );
      await _applyToNative();
    } on Object catch (e, s) {
      // A broken store must never take the browser down; the feature just
      // stays off.
      logger.w('Custom cursor: loading failed', error: e, stackTrace: s);
      state = state.copyWith(loaded: true);
    }
  }

  /// Pushes the current choice to Android and bumps [CustomCursorState.revision]
  /// so the Flutter cursor object is replaced.
  Future<void> _applyToNative() async {
    final selected = state.selected;
    var drawing = false;

    if (state.active && selected != null) {
      drawing = await _channel.configure(
        frames: selected.frames,
        sizePercent: state.settings.sizePercent,
      );
    }
    if (!drawing) await _channel.clear();

    state = state.copyWith(drawing: drawing, revision: state.revision + 1);
  }

  Future<void> _saveSettings(CustomCursorSettings settings) async {
    state = state.copyWith(settings: settings);
    await _store.writeSettings(settings);
    await _applyToNative();
  }

  Future<void> setEnabled(bool value) =>
      _saveSettings(state.settings.copyWith(enabled: value));

  Future<void> setApplyOutsideDex(bool value) =>
      _saveSettings(state.settings.copyWith(applyOutsideDex: value));

  Future<void> setAnimateInUi(bool value) =>
      _saveSettings(state.settings.copyWith(animateInUi: value));

  Future<void> setSizePercent(int value) =>
      _saveSettings(state.settings.copyWith(sizePercent: value));

  Future<void> select(String? id) =>
      _saveSettings(state.settings.copyWith(selectedId: id));

  /// Parses [bytes] and stores them as a new cursor, selecting it.
  ///
  /// [hotspot] overrides the hotspot of every frame, which is how a PNG gets
  /// its (x, y). Throws [CursorFormatException] for unusable files.
  Future<CursorEntry> importCursor({
    required String name,
    required Uint8List bytes,
    required String fileName,
    ({int x, int y})? hotspot,
  }) async {
    final parsed = parseCursorFile(bytes, fileName);
    final frames = hotspot == null
        ? parsed.frames
        : [for (final f in parsed.frames) f.withHotspot(hotspot.x, hotspot.y)];
    final entry = await _store.add(name, frames);
    state = state.copyWith(entries: await _store.list());
    await _saveSettings(state.settings.copyWith(selectedId: entry.id));
    return entry;
  }

  Future<void> updateHotspot(CursorEntry entry, int x, int y) async {
    await _store.updateHotspot(entry, x, y);
    state = state.copyWith(entries: await _store.list());
    await _applyToNative();
  }

  Future<void> remove(CursorEntry entry) async {
    await _store.remove(entry.id);
    final entries = await _store.list();
    final wasSelected = state.settings.selectedId == entry.id;
    state = state.copyWith(entries: entries);
    if (wasSelected) {
      await _saveSettings(state.settings.copyWith(selectedId: null));
    } else {
      await _applyToNative();
    }
  }
}

final customCursorControllerProvider =
    NotifierProvider<CustomCursorController, CustomCursorState>(
      CustomCursorController.new,
    );
