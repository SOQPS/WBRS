import 'package:flutter/material.dart';
import 'package:wbrs/app/widgets/splash.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/clrs_screen.dart';

class CheckInternetPage extends StatelessWidget {
  const CheckInternetPage({super.key});
  @override
  Widget build(BuildContext context) => ClrsScaffold(body: Center(
      child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ClrsPanel(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.wifi_off, size: 38), const SizedBox(height: 14),
          Text(context.tr('Отсутсвует подключение к интернету'), textAlign: TextAlign.center),
          const SizedBox(height: 14),
          ElevatedButton(onPressed: () => nextScreenReplace(context, const SplashScreen()),
              child: Text(context.tr('Повторить попытку'))),
        ])))));
}
