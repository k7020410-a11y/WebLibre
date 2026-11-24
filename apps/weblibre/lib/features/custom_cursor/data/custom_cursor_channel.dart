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

import 'package:flutter/services.dart';
import 'package:weblibre/core/logger.dart';
import 'package:weblibre/features/custom_cursor/domain/cursor_formats.dart';

/// Dart side of `eu.weblibre.gecko/custom_cursor`, implemented in
/// `MainActivity` and `CustomPointerIcons` on Android.
///
/// Every call is best effort: on a platform or build without the native half
/// (tests, an older host app) the feature simply stays inactive.
class CustomCursorChannel {
  const CustomCursorChannel();

  static const _channel = MethodChannel('eu.weblibre.gecko/custom_cursor');

  /// Whether Samsung DeX (or Android's desktop UI mode) is active right now.
  Future<bool> isDesktopMode() async {
    try {
      return await _channel.invokeMethod<bool>('isDesktopMode') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      logger.w('Custom cursor: desktop mode query failed: ${e.message}');
      return false;
    }
  }

  /// Hands the native side the frames to draw. The first frame is also what
  /// web pages get; the rest are only played in the browser UI.
  ///
  /// Returns whether the native side accepted them.
  Future<bool> configure({
    required List<CursorFrame> frames,
    required int sizePercent,
  }) async {
    try {
      await _channel.invokeMethod<void>('configure', {
        'sizePercent': sizePercent,
        'frames': [
          for (final f in frames)
            {'png': f.png, 'hotX': f.hotX, 'hotY': f.hotY},
        ],
      });
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      logger.w('Custom cursor: native configure failed: ${e.message}');
      return false;
    }
  }

  /// Stops overriding web page cursors and forgets the frames.
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      // No native half: nothing to clear.
    } on PlatformException catch (e) {
      logger.w('Custom cursor: native clear failed: ${e.message}');
    }
  }

  /// Shows frame [index] as the cursor of the browser UI.
  Future<void> showFrame(int index) async {
    try {
      await _channel.invokeMethod<void>('showFrame', {'index': index});
    } on MissingPluginException {
      // See [clear].
    } on PlatformException {
      // A frame that cannot be shown is not worth a log line per tick.
    }
  }
}
