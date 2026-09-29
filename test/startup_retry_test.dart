import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/locale_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:wbrs/main.dart' as application;

class UnavailableFirebaseCore extends MockFirebaseApp {
  int attempts = 0;
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async {
    attempts++;
    throw PlatformException(
        code: 'unavailable', message: 'Test startup failure');
  }
}

void main() {
  testWidgets('startup error can retry without setState returning a Future',
      (tester) async {
    SharedPreferences.setMockInitialValues({'clrs_ui_language': 'ru'});
    final platform = UnavailableFirebaseCore();
    TestFirebaseCoreHostApi.setUp(platform);
    addTearDown(() => TestFirebaseCoreHostApi.setUp(null));
    // Real catalog decoding uses an isolate above AssetBundle's 50 KB threshold.
    // Await it outside the fake clock before exercising Firebase retry behavior.
    await tester.runAsync(() async {
      await LocaleController.instance.initialize();
      await ClrsLocalizations.load(const Locale('ru'));
    });
    await tester.runAsync(() async {
      application.main();
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();
    expect(find.text('Повторить'), findsOneWidget);
    expect(platform.attempts, 1);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(platform.attempts, 2);
    expect(find.text('Повторить').hitTestable(), findsOneWidget);
  });
}
