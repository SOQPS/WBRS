import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/auth/register_screen/register_page.dart';
import 'package:wbrs/presentation/screens/auth/register_screen/registration_consent_page.dart';

class _ConsentTestAuth extends Fake implements FirebaseAuth {}

void main() {
  testWidgets('registration cannot start before consent is checked',
      (tester) async {
    firebaseAuth = _ConsentTestAuth();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: RegistrationConsentPage()));
    await tester.pumpAndSettle();

    final continueButton =
        find.byKey(const ValueKey('registration-consent-continue'));
    expect(tester.widget<ElevatedButton>(continueButton).onPressed, isNull);
    expect(find.byType(RegisterPage), findsNothing);

    await tester
        .tap(find.byKey(const ValueKey('registration-consent-checkbox')));
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(continueButton).onPressed, isNotNull);

    await tester.ensureVisible(continueButton);
    await tester.tap(continueButton);
    await tester.pumpAndSettle();
    expect(find.byType(RegisterPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct unconfirmed registration shows the consent screen',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterPage()));
    await tester.pumpAndSettle();
    expect(find.byType(RegistrationConsentPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
