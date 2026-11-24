/*
 * Copyright (c) 2024-2026 Fabian Freund.
 *
 * This file is part of WebLibre
 * (see https://weblibre.eu).
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
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weblibre/core/providers/app_localizations.dart';
import 'package:weblibre/l10n/generated/app_localizations.dart';

void main() {
  group('resolveAppLocale', () {
    test('matches the legacy Android code "in" to Indonesian', () {
      final locale = resolveAppLocale(const [
        Locale('in', 'ID'),
      ], AppLocalizations.supportedLocales);

      expect(locale, const Locale('id'));
    });

    test('keeps resolving current codes unchanged', () {
      final locale = resolveAppLocale(const [
        Locale('de', 'AT'),
      ], AppLocalizations.supportedLocales);

      expect(locale, const Locale('de'));
    });

    test('Arabic is a supported, explicitly selectable app locale', () {
      const arabic = Locale('ar');

      expect(AppLocalizations.supportedLocales, contains(arabic));
      expect(
        resolveAppLocale(const [arabic], AppLocalizations.supportedLocales),
        arabic,
      );
    });

    testWidgets('Arabic app localization uses right-to-left layout', (
      tester,
    ) async {
      late TextDirection direction;
      late String localizedLabel;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Builder(
            builder: (context) {
              direction = Directionality.of(context);
              localizedLabel = AppLocalizations.of(
                context,
              ).settings_appLanguageSystemDefault;
              return Text(localizedLabel);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(direction, TextDirection.rtl);
      expect(RegExp(r'[\u0600-\u06FF]').hasMatch(localizedLabel), isTrue);
    });
  });
}
