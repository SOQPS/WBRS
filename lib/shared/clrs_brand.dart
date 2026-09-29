import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'lrs_theme.dart';

/// Live typography, including the coloured R and heart, from the approved logo.
class ClrsLogo extends StatelessWidget {
  const ClrsLogo(
      {super.key,
      this.size = 42,
      this.centered = false,
      this.subtitle = true,
      this.subtitleSans = false});
  final double size;
  final bool centered, subtitle;
  final bool subtitleSans;
  @override
  Widget build(BuildContext context) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            FittedBox(
                fit: BoxFit.scaleDown,
                alignment: centered ? Alignment.center : Alignment.centerLeft,
                child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                          TextSpan(
                              style: TextStyle(
                                  fontFamily: 'CormorantGaramond',
                                  fontWeight: FontWeight.w600,
                                  fontSize: size,
                                  height: .94,
                                  color: const Color(0xFFFFE4C8)),
                              children: const [
                                TextSpan(text: 'CL'),
                                TextSpan(
                                    text: 'R',
                                    style: TextStyle(color: Color(0xFFFFA06C))),
                                TextSpan(text: 'S'),
                              ]),
                          semanticsLabel: 'CLRS'),
                      Padding(
                          padding: EdgeInsets.only(top: size * .02, left: 1),
                          child: Icon(Icons.favorite,
                              size: size * .23,
                              color: const Color(0xFFFFA06C))),
                    ])),
            if (subtitle)
              Text('Christian Lasting Relationships',
                  style: TextStyle(
                      fontFamily: subtitleSans ? 'Lato' : 'CormorantGaramond',
                      color: const Color(0xFFFFE4C8),
                      fontSize: size * (subtitleSans ? .19 : .22),
                      letterSpacing: subtitleSans ? .35 : 0,
                      height: 1.1)),
          ]);
}

class ClrsMotto extends StatelessWidget {
  const ClrsMotto({super.key, this.size = 21});
  final double size;
  @override
  Widget build(BuildContext context) =>
      Text(context.tr('Больше, чем знакомства'),
          textAlign: TextAlign.center,
          style: TextStyle(
              fontFamily: 'Caveat',
              fontSize: size,
              color: LrsTheme.peach,
              height: 1.05));
}
