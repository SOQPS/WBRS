import 'package:wbrs/localization/clrs_localizations.dart';
// ignore_for_file: camel_case_types
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wbrs/app/pages/policy/confidecialnost.dart';
import 'package:wbrs/app/pages/policy/offer.dart';
import 'package:wbrs/app/pages/policy/rules.dart';
import 'package:wbrs/app/pages/policy/soglashenie.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';

class About_App extends StatelessWidget {
  const About_App({super.key});
  @override
  Widget build(BuildContext context) {
    Widget link(IconData icon, String text, Widget page) => Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: ClrsPanel(
            padding: EdgeInsets.zero,
            child: ListTile(
                leading: Icon(icon, color: LrsTheme.peach),
                title: Text(context.tr(text)),
                trailing: Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => page)))));
    return ClrsScaffold(
        appBar: AppBar(title: Text(context.tr('О приложении'))),
        drawer: MyDrawer(),
        body: ListView(padding: EdgeInsets.all(18), children: [
          ClrsBrandHeader(),
          ClrsPanel(
              child: Text(
                  context.tr('Знакомства для серьёзных отношений и семьи'),
                  style: TextStyle(fontSize: 16, color: LrsTheme.peachLight))),
          SizedBox(height: 24),
          link(
              Icons.shield_outlined, 'Политика конфиденциальности', Politica()),
          link(Icons.description_outlined, 'Пользовательское соглашение',
              Rules()),
          link(Icons.handshake_outlined, 'Публичная оферта', Offer()),
          link(Icons.menu_book_outlined, 'Правила использования', Rule()),
          ClrsPanel(
              child: Row(children: [
            Expanded(child: Text(context.tr('Версия приложения'))),
            Text('1.0.15')
          ])),
          SizedBox(height: 10),
          ClrsPanel(
              padding: EdgeInsets.zero,
              child: ListTile(
                  leading: Icon(Icons.mail_outline),
                  title: Text(context.tr('Обратная связь')),
                  subtitle: Text('supp.lrs@ya.ru'),
                  onTap: () => openSupportEmail(context))),
          ClrsValuesFooter(),
        ]));
  }
}

Future<void> openSupportEmail(BuildContext context) async {
  var opened = false;
  try {
    opened = await launchUrl(Uri(scheme: 'mailto', path: 'supp.lrs@ya.ru'));
  } catch (_) {
    // Some platforms throw instead of returning false when no handler exists.
  }
  if (opened || !context.mounted) return;
  await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
            title: Text(context.tr('Обратная связь')),
            content: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.tr(
                    'Почтовое приложение не открылось. Напишите нам по адресу:')),
                SizedBox(height: 12),
                SelectableText('supp.lrs@ya.ru')
              ],
            )),
            actions: [
              TextButton(
                  onPressed: () async {
                    try {
                      await Clipboard.setData(
                          ClipboardData(text: 'supp.lrs@ya.ru'));
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                            SnackBar(
                                content: Text(context.tr('Адрес скопирован'))));
                      }
                    } catch (_) {
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                            SnackBar(
                                content: Text(context.tr(
                                    'Выделите и скопируйте адрес вручную.'))));
                      }
                    }
                  },
                  child: Text(context.tr('Копировать адрес'))),
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(context.tr('Закрыть')))
            ],
          ));
}
