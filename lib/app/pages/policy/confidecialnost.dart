import 'package:flutter/material.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/localization/clrs_localizations.dart';

/// The supplied policy.txt is a public offer, not an approved privacy policy.
/// Never present that document as consent to a privacy policy.
class Politica extends StatelessWidget {
  const Politica({super.key});
  @override
  Widget build(BuildContext context) => ClrsScaffold(
        appBar: AppBar(
            toolbarHeight:
                64 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
            title:
                Text(context.tr('Политика конфиденциальности'), maxLines: 2)),
        body: ListView(padding: const EdgeInsets.all(18), children: [
          const ClrsBrandHeader(),
          ClrsPanel(
              child: Text(context.tr(
                  'Утверждённая политика конфиденциальности пока недоступна. Обратитесь в поддержку: supp.lrs@ya.ru.'))),
        ]),
      );
}
