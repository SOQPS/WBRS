import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:go_router/go_router.dart';

class RootScreen extends StatelessWidget {
  const RootScreen({super.key, required this.navigationShell});

  /// Контейнер для навигационного бара.
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: BottomNavigationBar(
        items: _buildBottomNavBarItems(context),
        currentIndex: navigationShell.currentIndex,
        onTap: (index) => navigationShell.goBranch(index,
            initialLocation: index == navigationShell.currentIndex),
      ),
    );
  }

  // Возвращает лист элементов для нижнего навигационного бара.
  List<BottomNavigationBarItem> _buildBottomNavBarItems(BuildContext context) =>
      [
        BottomNavigationBarItem(
          icon: Icon(Icons.note),
          label: context.tr('Заметки'),
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.favorite),
          label: context.tr('Любимые'),
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.person),
          label: context.tr('Профиль'),
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.person),
          label: context.tr('Профиль'),
        ),
      ];
}
