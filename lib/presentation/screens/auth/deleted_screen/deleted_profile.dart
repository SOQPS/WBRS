import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/widgets/bottom_nav_bar.dart';

class DeletedProfile extends StatelessWidget {
  const DeletedProfile({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Image.asset(
          'assets/final_design/family_right.png',
          height: MediaQuery.of(context).size.height,
          width: MediaQuery.of(context).size.width,
          fit: BoxFit.cover,
          scale: 0.6,
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            iconTheme: const IconThemeData(color: Colors.white),
            backgroundColor: Colors.transparent,
          ),
          bottomNavigationBar: const MyBottomNavigationBar(),
          body: Center(
            child: Text(
              context.tr('Профиль был удален'),
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}
