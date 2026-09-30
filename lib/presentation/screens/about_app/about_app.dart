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
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/localization/language_picker.dart';

class About_App extends StatelessWidget {
  const About_App({super.key});
  @override
  Widget build(BuildContext context) {
    Widget link(IconData icon, String text, Widget page) => Padding(
      padding: EdgeInsets.only(bottom: 10),
      child: ClrsPanel(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => page)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: LrsTheme.peach),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.tr(text),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
    return ClrsScaffold(
      appBar: AppBar(title: Text(context.tr('О приложении'))),
      drawer: MyDrawer(),
      bottomNavigationBar: const MyBottomNavigationBar(),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = (constraints.maxWidth - 36).clamp(
            0.0,
            double.infinity,
          );
          final panelWidth = availableWidth < 245
              ? availableWidth
              : (availableWidth * .72).clamp(245.0, availableWidth);
          return ListView(
            padding: const EdgeInsets.all(18),
            children: [
              const ClrsBrandHeader(),
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: panelWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('О приложении'),
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      ClrsPanel(
                        child: Text(
                          context.tr(
                            'Знакомства для серьёзных отношений и семьи',
                          ),
                          style: const TextStyle(
                            fontSize: 16,
                            color: LrsTheme.peachLight,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      link(
                        Icons.shield_outlined,
                        'Политика конфиденциальности',
                        Politica(),
                      ),
                      link(
                        Icons.description_outlined,
                        'Пользовательское соглашение',
                        Rules(),
                      ),
                      link(
                        Icons.handshake_outlined,
                        'Публичная оферта',
                        Offer(),
                      ),
                      link(
                        Icons.menu_book_outlined,
                        'Правила использования',
                        Rule(),
                      ),
                      ClrsPanel(
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(context.tr('Версия приложения')),
                            ),
                            const Text('1.0.25'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      ClrsPanel(
                        child: Row(
                          children: [
                            const Icon(Icons.language, color: LrsTheme.peach),
                            const SizedBox(width: 8),
                            Expanded(child: Text(context.tr('Язык'))),
                            const LanguagePickerButton(compact: true),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      ClrsPanel(
                        padding: EdgeInsets.zero,
                        child: ListTile(
                          leading: const Icon(Icons.mail_outline),
                          title: Text(context.tr('Обратная связь')),
                          subtitle: const Text('supp.lrs@ya.ru'),
                          onTap: () => openSupportEmail(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const ClrsValuesFooter(),
            ],
          );
        },
      ),
    );
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
            Text(
              context.tr(
                'Почтовое приложение не открылось. Напишите нам по адресу:',
              ),
            ),
            SizedBox(height: 12),
            SelectableText('supp.lrs@ya.ru'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              await Clipboard.setData(ClipboardData(text: 'supp.lrs@ya.ru'));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(content: Text(context.tr('Адрес скопирован'))),
                );
              }
            } catch (_) {
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      context.tr('Выделите и скопируйте адрес вручную.'),
                    ),
                  ),
                );
              }
            }
          },
          child: Text(context.tr('Копировать адрес')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(context.tr('Закрыть')),
        ),
      ],
    ),
  );
}
