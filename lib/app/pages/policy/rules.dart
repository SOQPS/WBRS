import 'package:flutter/material.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/localization/language_picker.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/rules_content.dart';

class Rule extends StatelessWidget {
  const Rule({super.key});
  @override
  Widget build(BuildContext context) => ClrsScaffold(
      appBar: AppBar(actions: const [LanguagePickerButton()]),
      bottomNavigationBar: const MyBottomNavigationBar(),
      body: LayoutBuilder(builder: (context, box) {
        final compact = MediaQuery.textScalerOf(context).scale(14) <= 20;
        final width =
            compact ? (box.maxWidth * .64).clamp(220.0, 620.0) : box.maxWidth;
        return SingleChildScrollView(
            key: const ValueKey('rules-scroll'),
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const ClrsBrandHeader(),
              SizedBox(
                  width: width,
                  child: ClrsPanel(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                        Text(context.tr('Правила использования'),
                            style: const TextStyle(
                                fontFamily: 'CormorantGaramond',
                                fontSize: 28,
                                fontWeight: FontWeight.w600,
                                height: 1.05)),
                        for (final chapter in rulesChapters) ...[
                          const Divider(height: 28),
                          Text(context.tr(chapter.title),
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 12),
                          for (var index = 0;
                              index < chapter.items.length;
                              index++)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                          width: 24,
                                          height: 24,
                                          alignment: Alignment.center,
                                          decoration: const BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: LrsTheme.peach),
                                          child: Text('${index + 1}',
                                              textScaler: TextScaler.noScaling,
                                              style: const TextStyle(
                                                  color: Color(0xFF302110),
                                                  fontSize: 12,
                                                  fontWeight:
                                                      FontWeight.w700))),
                                      const SizedBox(width: 9),
                                      Expanded(
                                          child: Text(
                                              context.tr(chapter.items[index]),
                                              style: const TextStyle(
                                                  fontSize: 14, height: 1.35))),
                                    ])),
                          if (chapter == rulesChapters[1])
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                child: Text(context.tr(rulesThanks),
                                    style: const TextStyle(
                                        fontSize: 13, height: 1.4))),
                        ],
                        const ClrsValuesFooter(),
                      ]))),
            ]));
      }));
}
