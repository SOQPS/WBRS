import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class _LayoutAuth extends Fake implements FirebaseAuth {
  @override
  User? get currentUser => null;

  @override
  Future<UserCredential> signInWithEmailAndPassword(
      {required String email, required String password}) async {
    throw FirebaseAuthException(code: 'invalid-credential');
  }
}

void main() {
  testWidgets(
      'Remember me defaults on, stores only email, and saves an opt-out',
      (tester) async {
    SharedPreferences.setMockInitialValues({'password': 'legacy-secret'});
    firebaseAuth = _LayoutAuth();
    await tester.pumpWidget(
        MaterialApp(theme: LrsTheme.theme, home: const LoginPage()));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('password'), isNull);

    await tester.enterText(find.byType(TextFormField).first, 'a@example.test');
    await tester.enterText(find.byType(TextFormField).last, 'good-password');
    await tester.ensureVisible(find.byType(ElevatedButton).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ElevatedButton).first);
    await tester.pumpAndSettle();
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('remember_me'), isTrue);
    expect(prefs.getString('email'), 'a@example.test');
    expect(prefs.getString('password'), isNull);

    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(prefs.getBool('remember_me'), isFalse);
    expect(prefs.getString('email'), isNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpWidget(
        MaterialApp(theme: LrsTheme.theme, home: const LoginPage()));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        isEmpty);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('Login stays usable at width $width and large text',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      firebaseAuth = _LayoutAuth();
      await (FontLoader('Lato')
            ..addFont(rootBundle.load('assets/fonts/Lato-Regular.ttf')))
          .load();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, width == 320 ? 568 : 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: LrsTheme.theme,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!),
          home: const RepaintBoundary(
              key: ValueKey('login-preview'), child: LoginPage())));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TextFormField), findsNWidgets(2));
      // The handoff archive contained no golden PNGs. Assert actual reachability;
      // do not manufacture or silently update an unreviewed visual baseline.
      expect(find.text('CLRS'), findsOneWidget);
      await tester.ensureVisible(find.byType(ElevatedButton).first);
      await tester.pumpAndSettle();
      expect(find.byType(ElevatedButton).first.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
