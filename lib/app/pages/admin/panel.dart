import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/pages/admin/meets.dart';
import 'package:wbrs/app/pages/admin/users.dart';
import 'package:wbrs/app/pages/admin/role_requests.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';
import 'package:wbrs/app/widgets/drawer.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/service/admin_access.dart';

class AdminPanel extends StatelessWidget {
  const AdminPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return AdminGuard(
        child: Stack(
      children: [
        Container(
          decoration: const BoxDecoration(boxShadow: []),
          child: Image.asset(
            'assets/final_design/family_right.png',
            height: MediaQuery.of(context).size.height,
            width: MediaQuery.of(context).size.width,
            fit: BoxFit.cover,
            scale: 0.6,
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          drawer: MyDrawer(),
          appBar: AppBar(
            iconTheme: const IconThemeData(color: Colors.white),
            backgroundColor: Colors.transparent,
          ),
          bottomNavigationBar: const MyBottomNavigationBar(),
          body: adminPanelPage(context),
        ),
      ],
    ));
  }

  Widget adminPanelPage(BuildContext context) {
    return Column(
      children: [
        ListTile(
          onTap: () => nextScreen(context, const Users()),
          title: Text(
            context.tr('Пользователи'),
            style: TextStyle(color: Colors.white),
          ),
          leading: const Icon(
            Icons.account_circle,
            color: Colors.white,
          ),
          trailing: const Icon(
            Icons.arrow_forward_ios,
            color: Colors.white,
          ),
        ),
        ListTile(
          onTap: () => nextScreen(context, const Meets()),
          title: Text(
            context.tr('Встречи'),
            style: TextStyle(color: Colors.white),
          ),
          leading: const Icon(
            Icons.account_circle,
            color: Colors.white,
          ),
          trailing: const Icon(
            Icons.arrow_forward_ios,
            color: Colors.white,
          ),
        ),
        ListTile(
          onTap: () => nextScreen(context, const RoleRequestsPage()),
          title: Text(context.tr('Заявки на роли'),
              style: const TextStyle(color: Colors.white)),
          leading: const Icon(Icons.how_to_reg_outlined, color: Colors.white),
          trailing:
              const Icon(Icons.arrow_forward_ios, color: Colors.white),
        ),
      ],
    );
  }
}
