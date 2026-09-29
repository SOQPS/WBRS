import 'dart:async';
import 'package:wbrs/shared/password_reset_sheet.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/presentation/screens/auth/register_screen/register_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class ResetFailAuth extends Fake implements FirebaseAuth {
  @override
  Future<void> sendPasswordResetEmail(
      {required String email, ActionCodeSettings? actionCodeSettings}) async {
    throw FirebaseAuthException(code: 'network-request-failed');
  }
}

void main() {
  testWidgets('reset network error stays in usable sheet', (tester) async {
    SharedPreferences.setMockInitialValues({});
    firebaseAuth = ResetFailAuth();
    await tester.pumpWidget(
        MaterialApp(theme: LrsTheme.theme, home: const LoginPage()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Забыли пароль?'));
    await tester.tap(find.text('Забыли пароль?'));
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    await tester.enterText(
        find.descendant(of: sheet, matching: find.byType(TextFormField)),
        'qa@example.invalid');
    await tester.tap(find.text('Сбросить пароль'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('соединени'), findsWidgets);
  });
  testWidgets('pending reset waits the same request and tolerates disposal',
      (tester) async {
    final completion = Completer<void>();
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        home: Scaffold(body: PasswordResetSheet(send: (_) {
          sends++;
          return completion.future;
        }))));
    await tester.enterText(find.byType(TextFormField), 'qa@example.invalid');
    await tester.tap(find.text('Сбросить пароль'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('Проверить результат'), findsOneWidget);
    await tester.tap(find.text('Проверить результат'));
    await tester.pump();
    expect(sends, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    completion.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'reset controls remain reachable with keyboard and 2x text in landscape',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 320);
    tester.view.viewInsets = const FakeViewPadding(bottom: 140);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: LrsTheme.theme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(body: PasswordResetSheet(send: (_) async {}))));
    await tester.ensureVisible(find.text('Сбросить пароль'));
    await tester.pumpAndSettle();
    expect(find.text('Сбросить пароль').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final entry in <String, Widget>{
    'login': const LoginPage(),
    'register': const RegisterPage(consentConfirmed: true)
  }.entries) {
    testWidgets('${entry.key} initially hides password', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester
          .pumpWidget(MaterialApp(theme: LrsTheme.theme, home: entry.value));
      await tester.pumpAndSettle();
      final fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.last.obscureText, isTrue);
    });
    for (final size in [
      const Size(320, 640),
      const Size(390, 844),
      const Size(640, 320)
    ]) {
      for (final scale in [1.3, 2.0]) {
        testWidgets('${entry.key} usable at $size text $scale with keyboard',
            (tester) async {
          SharedPreferences.setMockInitialValues({});
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
              theme: LrsTheme.theme,
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!),
              home: entry.value));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final button = find.byType(ElevatedButton).first;
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          expect(button.hitTestable(), findsOneWidget);
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final fields = find.byType(TextFormField);
          await tester.ensureVisible(fields.last);
          await tester.showKeyboard(fields.last);
          tester.view.viewInsets = FakeViewPadding(bottom: size.height * .4);
          await tester.pumpAndSettle();
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(button.hitTestable(), findsOneWidget);
        });
      }
    }
  }
}
