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
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:weblibre/features/custom_cursor/domain/cursor_formats.dart';
import 'package:weblibre/features/custom_cursor/domain/custom_cursor_store.dart';
import 'package:weblibre/features/custom_cursor/domain/providers.dart';

// The strings live here rather than in the generated l10n files so this
// feature adds no generated code. English and Arabic only; any other locale
// shows English.
String _t(BuildContext context, String en, String ar) =>
    Localizations.localeOf(context).languageCode == 'ar' ? ar : en;

String customCursorSettingsTitle(BuildContext context) =>
    _t(context, 'Custom cursor', 'المؤشر المخصص');

String customCursorSettingsSubtitle(BuildContext context) => _t(
  context,
  'Mouse cursor for Samsung DeX (.cur, .ani, .png)',
  'مؤشر ماوس لوضع DeX (‏.cur ‏.ani ‏.png)',
);

/// Settings for the custom mouse cursor: on/off, which cursor, its size, and
/// importing Windows cursors.
class CustomCursorSettingsScreen extends ConsumerWidget {
  const CustomCursorSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(customCursorControllerProvider);
    final controller = ref.read(customCursorControllerProvider.notifier);
    final settings = state.settings;

    return Scaffold(
      appBar: AppBar(title: Text(customCursorSettingsTitle(context))),
      body: ListView(
        children: [
          SwitchListTile.adaptive(
            title: Text(_t(context, 'Use custom cursor', 'استخدام مؤشر مخصص')),
            subtitle: Text(
              _t(
                context,
                'Only while using a mouse in DeX. The system cursor and other '
                    'apps are not changed.',
                'فقط عند استخدام الماوس في DeX. لا يتغير مؤشر النظام '
                    'ولا التطبيقات الأخرى.',
              ),
            ),
            value: settings.enabled,
            onChanged: (value) => unawaited(controller.setEnabled(value)),
          ),
          ListTile(
            leading: Icon(
              state.desktopMode ? Icons.desktop_windows : Icons.smartphone,
            ),
            title: Text(
              state.desktopMode
                  ? _t(context, 'DeX detected', 'تم رصد وضع DeX')
                  : _t(context, 'DeX not detected', 'لم يتم رصد وضع DeX'),
            ),
            subtitle: Text(
              state.drawing
                  ? _t(context, 'Cursor is active', 'المؤشر المخصص مفعّل')
                  : _t(context, 'Cursor is not active', 'المؤشر المخصص غير مفعّل'),
            ),
          ),
          SwitchListTile.adaptive(
            title: Text(
              _t(context, 'Also outside DeX', 'استخدامه خارج DeX أيضاً'),
            ),
            subtitle: Text(
              _t(
                context,
                'For testing with a mouse on a phone or tablet.',
                'للتجربة بماوس على الهاتف أو التابلت.',
              ),
            ),
            value: settings.applyOutsideDex,
            onChanged: (value) =>
                unawaited(controller.setApplyOutsideDex(value)),
          ),
          SwitchListTile.adaptive(
            title: Text(
              _t(context, 'Animate in the browser UI', 'تحريك المؤشر في الواجهة'),
            ),
            subtitle: Text(
              _t(
                context,
                'Web pages always show a still frame; Android cannot animate '
                    'a page cursor.',
                'صفحات المواقع تعرض إطاراً ثابتاً دائماً؛ أندرويد لا يدعم '
                    'تحريك مؤشر الصفحة.',
              ),
            ),
            value: settings.animateInUi,
            onChanged: (value) => unawaited(controller.setAnimateInUi(value)),
          ),
          _SizeTile(
            percent: settings.sizePercent,
            onCommit: (value) => unawaited(controller.setSizePercent(value)),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _t(context, 'Cursors', 'المؤشرات'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (state.entries.isEmpty)
            ListTile(
              title: Text(
                _t(
                  context,
                  'No cursors yet. Import a .cur, .ani or .png file.',
                  'لا توجد مؤشرات بعد. استورد ملف ‏.cur أو ‏.ani أو ‏.png.',
                ),
              ),
            ),
          for (final entry in state.entries)
            _CursorTile(
              entry: entry,
              selected: entry.id == settings.selectedId,
              onSelect: () => unawaited(controller.select(entry.id)),
              onEditHotspot: () => _editHotspot(context, controller, entry),
              onDelete: () => unawaited(controller.remove(entry)),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                icon: const Icon(Icons.file_open_outlined),
                label: Text(_t(context, 'Import cursor', 'استيراد مؤشر')),
                onPressed: () => _import(context, controller),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _import(
    BuildContext context,
    CustomCursorController controller,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await FilePicker.pickFiles();
      if (result.isEmpty) return;
      final path = result.single.path;
      if (path == null) return;

      final file = File(path);
      if (await file.length() > maxCursorFileBytes) {
        throw const CursorFormatException('File is too large');
      }
      final bytes = await file.readAsBytes();
      final parsed = parseCursorFile(bytes, p.basename(path));

      ({int x, int y})? hotspot;
      if (parsed.needsHotspot) {
        if (!context.mounted) return;
        hotspot = await showDialog<({int x, int y})>(
          context: context,
          builder: (_) =>
              _HotspotDialog(frame: parsed.frames.first, x: 0, y: 0),
        );
        if (hotspot == null) return; // cancelled
      }

      await controller.importCursor(
        name: p.basenameWithoutExtension(path),
        bytes: bytes,
        fileName: p.basename(path),
        hotspot: hotspot,
      );
    } on CursorFormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on FileSystemException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editHotspot(
    BuildContext context,
    CustomCursorController controller,
    CursorEntry entry,
  ) async {
    final hotspot = await showDialog<({int x, int y})>(
      context: context,
      builder: (_) => _HotspotDialog(
        frame: entry.first,
        x: entry.first.hotX,
        y: entry.first.hotY,
      ),
    );
    if (hotspot != null) {
      await controller.updateHotspot(entry, hotspot.x, hotspot.y);
    }
  }
}

class _SizeTile extends StatefulWidget {
  const _SizeTile({required this.percent, required this.onCommit});

  final int percent;
  final ValueChanged<int> onCommit;

  @override
  State<_SizeTile> createState() => _SizeTileState();
}

class _SizeTileState extends State<_SizeTile> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final value = _dragging ?? widget.percent.toDouble();
    return ListTile(
      title: Text(
        '${_t(context, 'Size', 'الحجم')}: ${value.round()}%',
      ),
      subtitle: Slider(
        min: CustomCursorSettings.minSizePercent.toDouble(),
        max: CustomCursorSettings.maxSizePercent.toDouble(),
        divisions:
            (CustomCursorSettings.maxSizePercent -
                CustomCursorSettings.minSizePercent) ~/
            10,
        value: value.clamp(
          CustomCursorSettings.minSizePercent.toDouble(),
          CustomCursorSettings.maxSizePercent.toDouble(),
        ),
        // The native icons are rebuilt on commit only, not on every tick.
        onChanged: (v) => setState(() => _dragging = v),
        onChangeEnd: (v) {
          setState(() => _dragging = null);
          widget.onCommit(v.round());
        },
      ),
    );
  }
}

class _CursorTile extends StatelessWidget {
  const _CursorTile({
    required this.entry,
    required this.selected,
    required this.onSelect,
    required this.onEditHotspot,
    required this.onDelete,
  });

  final CursorEntry entry;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onEditHotspot;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final first = entry.first;
    final details = [
      '${first.width}×${first.height}',
      if (entry.animated)
        _t(
          context,
          '${entry.frames.length} frames',
          '${entry.frames.length} إطار',
        ),
      _t(
        context,
        'hotspot ${first.hotX}, ${first.hotY}',
        'نقطة التأشير ${first.hotX}, ${first.hotY}',
      ),
    ].join(' · ');

    return ListTile(
      selected: selected,
      leading: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: _CursorPreview(entry: entry),
          ),
        ),
      ),
      title: Text(entry.name),
      subtitle: Text(details),
      onTap: onSelect,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) const Icon(Icons.check_circle),
          PopupMenuButton<String>(
            onSelected: (value) =>
                value == 'hotspot' ? onEditHotspot() : onDelete(),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'hotspot',
                child: Text(_t(context, 'Edit hotspot', 'تعديل نقطة التأشير')),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text(_t(context, 'Delete', 'حذف')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shows a cursor, stepping through its frames when it is animated.
class _CursorPreview extends StatefulWidget {
  const _CursorPreview({required this.entry});

  final CursorEntry entry;

  @override
  State<_CursorPreview> createState() => _CursorPreviewState();
}

class _CursorPreviewState extends State<_CursorPreview> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(_CursorPreview old) {
    super.didUpdateWidget(old);
    if (old.entry.id != widget.entry.id) {
      _timer?.cancel();
      _index = 0;
      _schedule();
    }
  }

  void _schedule() {
    if (!widget.entry.animated) return;
    _timer = Timer(
      Duration(milliseconds: widget.entry.frames[_index].delayMs),
      () {
        if (!mounted) return;
        setState(() => _index = (_index + 1) % widget.entry.frames.length);
        _schedule();
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.entry.frames[_index % widget.entry.frames.length];
    return Image.memory(
      frame.png,
      width: frame.width.toDouble(),
      height: frame.height.toDouble(),
      filterQuality: FilterQuality.none,
      // Keeps the previous frame on screen while the next one decodes, so an
      // animated preview does not flicker.
      gaplessPlayback: true,
      fit: BoxFit.contain,
    );
  }
}

/// Picks the hotspot: the pixel of the image that is the tip of the pointer.
class _HotspotDialog extends StatefulWidget {
  const _HotspotDialog({required this.frame, required this.x, required this.y});

  final CursorFrame frame;
  final int x;
  final int y;

  @override
  State<_HotspotDialog> createState() => _HotspotDialogState();
}

class _HotspotDialogState extends State<_HotspotDialog> {
  late final TextEditingController _x = TextEditingController(
    text: '${widget.x}',
  );
  late final TextEditingController _y = TextEditingController(
    text: '${widget.y}',
  );

  static const _zoom = 4.0;

  int _parse(TextEditingController c, int max) =>
      (int.tryParse(c.text) ?? 0).clamp(0, max - 1).toInt();

  @override
  void dispose() {
    _x.dispose();
    _y.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final hx = _parse(_x, frame.width);
    final hy = _parse(_y, frame.height);

    return AlertDialog(
      title: Text(_t(context, 'Hotspot', 'نقطة التأشير')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _t(
                context,
                'The pixel that does the clicking, counted from the top-left.',
                'البكسل الذي يحدد مكان النقر، يُحسب من الزاوية العلوية اليسرى.',
              ),
            ),
            const SizedBox(height: 12),
            Stack(
              children: [
                Image.memory(
                  frame.png,
                  width: frame.width * _zoom,
                  height: frame.height * _zoom,
                  filterQuality: FilterQuality.none,
                ),
                Positioned(
                  left: hx * _zoom,
                  top: hy * _zoom,
                  width: _zoom,
                  height: _zoom,
                  child: const ColoredBox(color: Colors.red),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _x,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'X'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _y,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Y'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_t(context, 'Cancel', 'إلغاء')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((x: hx, y: hy)),
          child: Text(_t(context, 'OK', 'موافق')),
        ),
      ],
    );
  }
}
