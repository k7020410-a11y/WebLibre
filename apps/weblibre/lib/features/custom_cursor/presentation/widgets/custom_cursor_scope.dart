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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MouseCursor, MouseCursorSession;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:weblibre/features/custom_cursor/data/custom_cursor_channel.dart';
import 'package:weblibre/features/custom_cursor/domain/providers.dart';

/// A mouse cursor drawn from the frames the user imported.
///
/// It is a real [MouseCursor], so Flutter's own cursor arbitration applies:
/// the innermost [MouseRegion] with a cursor of its own wins, and only regions
/// that *defer* (the default) fall through to this one. Buttons keep their
/// hand, text fields their I-beam and the side rail's resize handle its
/// resize cursor; only the plain arrow is replaced.
///
/// The frames themselves live on the native side; this object only tells it
/// which one to show, and when to advance for an animated cursor.
class CustomImageMouseCursor extends MouseCursor {
  const CustomImageMouseCursor({
    required this.revision,
    required this.delaysMs,
    required this.animate,
    this.channel = const CustomCursorChannel(),
  });

  /// Identifies the imported cursor and its settings; a new one replaces the
  /// running session.
  final int revision;

  /// Per-frame display time in milliseconds.
  final List<int> delaysMs;

  /// Whether to step through [delaysMs]. Off shows the first frame only.
  final bool animate;

  final CustomCursorChannel channel;

  @override
  MouseCursorSession createSession(int device) =>
      _CustomImageCursorSession(this, device);

  @override
  String get debugDescription => 'CustomImageMouseCursor(revision: $revision)';

  @override
  bool operator ==(Object other) =>
      other is CustomImageMouseCursor &&
      other.revision == revision &&
      other.animate == animate;

  @override
  int get hashCode => Object.hash(revision, animate);
}

class _CustomImageCursorSession extends MouseCursorSession {
  _CustomImageCursorSession(CustomImageMouseCursor cursor, int device)
    : _cursor = cursor,
      super(cursor, device);

  final CustomImageMouseCursor _cursor;
  Timer? _timer;
  int _index = 0;
  bool _disposed = false;

  @override
  Future<void> activate() async {
    if (_disposed) return;
    _index = 0;
    await _cursor.channel.showFrame(0);
    if (_cursor.animate && _cursor.delaysMs.length > 1) _scheduleNext();
  }

  void _scheduleNext() {
    _timer = Timer(Duration(milliseconds: _cursor.delaysMs[_index]), () {
      if (_disposed) return;
      _index = (_index + 1) % _cursor.delaysMs.length;
      unawaited(_cursor.channel.showFrame(_index));
      _scheduleNext();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

/// Wraps the app so the custom cursor replaces the default arrow everywhere in
/// the browser's own UI. Inert, and one extra [MouseRegion], while the feature
/// is off: the region then defers, which is the same as no region at all.
class CustomCursorScope extends ConsumerWidget {
  const CustomCursorScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(customCursorControllerProvider);
    final selected = state.selected;

    final MouseCursor cursor = state.drawing && selected != null
        ? CustomImageMouseCursor(
            revision: state.revision,
            delaysMs: [for (final f in selected.frames) f.delayMs],
            animate: state.settings.animateInUi,
          )
        : MouseCursor.defer;

    return MouseRegion(cursor: cursor, child: child);
  }
}
