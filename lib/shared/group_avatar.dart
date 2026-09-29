import 'package:wbrs/core/utils/account_destination.dart'
    show savedAccountGroup;
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'group_badge.dart';
import 'lrs_theme.dart';

/// Thin rings are used in lists/chats; large profile badges remain unchanged.
class GroupAvatar extends StatelessWidget {
  const GroupAvatar(
      {super.key, required this.url, required this.group, this.size = 48});
  final String url, group;
  final double size;
  @override
  Widget build(BuildContext context) {
    final displayGroup = savedAccountGroup({'группа': group}) ?? group;
    final colors = groupColors(group);
    return Semantics(
        label: colors.isEmpty
            ? context.tr('Фото профиля')
            : context.tr('Группа: {group}',
                args: {'group': context.tr(displayGroup)}),
        child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
                painter: GroupRingPainter(colors),
                child: Padding(
                    padding: EdgeInsets.all(colors.isEmpty ? 0 : 3),
                    child: ClipOval(
                        child: url.isEmpty
                            ? const ColoredBox(
                                color: LrsTheme.surface,
                                child: Icon(Icons.person_outline,
                                    color: LrsTheme.peachLight))
                            : CachedNetworkImage(
                                imageUrl: url,
                                fit: BoxFit.cover,
                                memCacheWidth: (size * 3).round(),
                                maxWidthDiskCache: 320,
                                fadeInDuration:
                                    const Duration(milliseconds: 120),
                                placeholder: (_, __) => const Center(
                                    child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 1.5))),
                                errorWidget: (_, __, ___) => const ColoredBox(
                                    color: LrsTheme.surface,
                                    child: Icon(Icons.person_outline))))))));
  }
}
