import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/shared/clrs_screen.dart';

void main() {
  testWidgets('Android Back closes the open drawer without leaving the screen',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ClrsScaffold(
        appBar: AppBar(title: const Text('Profile')),
        drawer: const Drawer(child: Text('Menu')),
        body: const Text('Profile body'),
      ),
    ));

    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).last);
    scaffold.openDrawer();
    await tester.pumpAndSettle();
    expect(scaffold.isDrawerOpen, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(scaffold.isDrawerOpen, isFalse);
    expect(find.text('Profile body'), findsOneWidget);
  });
}
