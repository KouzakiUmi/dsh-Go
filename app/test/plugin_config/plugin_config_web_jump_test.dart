// A plugin's native configuration page carries no card to DSH Web any more
// (f335e20): the form is drawn whenever it can be, and a data refresh after a
// save does not push it out for a button. The ways to DSH Web that remain are
// a form row of its own (「在网页版编辑此项」, asking before it drops held edits)
// and an entry id from elsewhere in the app (网页模式): both land on the
// plugin's card rather than on an entry id no card has.

import 'dart:async';

import 'package:dsh_app/state/plugin_config/plugin_config_memory.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart';
import 'package:dsh_app/state/plugins_state.dart' show installedPluginsProvider;
import 'package:dsh_app/state/ui_mode_state.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/plugins/seats/seat_links.dart' show seatWebOpenerProvider;
import 'package:dsh_app/ui/web/dsh_web_launcher.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine_settings/support.dart';
import 'support.dart';

const _primary = ValueKey('plugin-config-primary');
const _status = ValueKey('plugin-config-status');

/// The weather plugin's card on DSH Web's Plugins page.
const _card = ['天气', 'Weather', '@acme/dsh-weather'];

/// 天气 with one more field the app can't draw (a number or a word): DSH
/// Web edits it.
MemoryPluginEntry _weatherWithWebField() => MemoryPluginEntry(
  ns: 'weather',
  autoGenerate: false,
  schema: fields({
    'city': str(zh: '城市', en: 'City', required: true),
    'units': choice(['metric', 'imperial'], def: 'metric', zh: '单位', en: 'Units'),
    'refresh': {
      'type': 'union',
      'list': [
        {'type': 'number'},
        {'type': 'const', 'value': 'auto'},
      ],
      'meta': {
        'description': {'zh': '刷新间隔', 'en': 'Refresh'},
      },
    },
  }),
  base: {'units': 'metric'},
);

Future<List<DshWebTarget>> _open(WidgetTester tester, MemoryPluginConfigApi api) async {
  final opened = <DshWebTarget>[];
  await pumpPage(
    tester,
    const PluginConfigPage(ns: 'weather'),
    height: 1400,
    overrides: [
      ...configOverrides(api),
      seatWebOpenerProvider.overrideWithValue((context, ref, target) => opened.add(target)),
    ],
  );
  return opened;
}

/// A held edit: 单位 → imperial (applies on a reload).
Future<void> _holdEdit(WidgetTester tester) async {
  await tester.tap(find.text('单位'));
  await settle(tester);
  await tester.tap(find.text('imperial').last);
  await settle(tester);
  expect(find.text('未保存'), findsOneWidget);
}

/// The page's fields are the settings themselves: no card of its own leads
/// off to DSH Web.
void _noWebCard() =>
    expect(find.text('在网页版设置'), findsNothing, reason: 'the form is the page; no card leads off it');

PluginConfigState _state(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(PluginConfigPage))).read(pluginConfigProvider).value!;

void main() {
  testWidgets('a plugin that ships its own web page: its fields drawn, no card to DSH Web', (tester) async {
    final api = sampleConfigApi();
    final opened = await _open(tester, api);

    expect(find.text('城市'), findsOneWidget);
    expect(find.text('单位'), findsOneWidget);
    _noWebCard();
    expect(opened, isEmpty, reason: 'nothing leaves the page by itself');
  });

  testWidgets('while a save reloads the plugin the form stays: no card takes its place', (tester) async {
    final api = sampleConfigApi()..gate = Completer<void>();
    final opened = await _open(tester, api);
    await _holdEdit(tester);
    await tester.tap(find.byKey(_primary));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(_status)).data, '正在保存…');
    expect(find.text('城市'), findsOneWidget, reason: 'the form is still the page while it saves');
    _noWebCard();
    expect(opened, isEmpty);

    // The reload draws the page again from fresh data: still the form.
    final first = api.gate!;
    api.gate = Completer<void>();
    first.complete();
    await settle(tester);
    expect(find.text('城市'), findsOneWidget, reason: 'still reloading, still the form');
    _noWebCard();
    api.gate!.complete();
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(_status)).data, '已生效');
    expect(find.text('城市'), findsOneWidget, reason: 'the refreshed data does not push the form out');
    expect(find.text('单位'), findsOneWidget);
    _noWebCard();
    expect(opened, isEmpty);
  });

  testWidgets('a field only DSH Web edits goes the page\'s way: asks, then the plugin\'s card', (tester) async {
    final api = MemoryPluginConfigApi([voiceEntry(), translatorEntry(), _weatherWithWebField()]);
    final opened = await _open(tester, api);
    final row = find.text('在网页版编辑此项');
    expect(row, findsOneWidget);

    await tester.tap(row);
    await settle(tester);
    expect(opened.single.pluginItem, _card, reason: 'its entry id alone matches no card');

    await _holdEdit(tester);
    await tester.tap(row);
    await settle(tester);
    expect(find.text('放弃修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await settle(tester);
    expect(opened, hasLength(1), reason: 'nothing else opened');
    expect(_state(tester).hasDraft('weather'), isTrue, reason: 'the edit is still held');
  });

  testWidgets('elsewhere, an entry id still lands on its plugin\'s card (网页模式)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(
      tester,
      Consumer(
        builder: (context, ref, _) {
          // The plugin list the launcher names cards from.
          ref.watch(installedPluginsProvider);
          return Center(
            child: TextButton(
              onPressed: () => openDshWeb(context, ref, target: const DshWebTarget(pluginItem: ['weather'])),
              child: const Text('go'),
            ),
          );
        },
      ),
      overrides: configOverrides(sampleConfigApi()),
    );
    final c = ProviderScope.containerOf(tester.element(find.text('go')));
    await tester.runAsync(() => c.read(uiModeProvider.notifier).set(UiMode.web));
    await tester.tap(find.text('go'));
    await settle(tester);
    expect(c.read(webOpenProvider)!.target.pluginItem, ['weather', ..._card]);
  });
}
