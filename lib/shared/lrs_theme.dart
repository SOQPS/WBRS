import 'package:flutter/material.dart';

class LrsTheme {
  static const background = Color(0xFF120D0A);
  static const backgroundSoft = Color(0xFF1B120E);
  static const surface = Color(0xFF211813);
  static const surfaceSoft = Color(0xC72B201A);
  static const surfaceGlass = Color(0xA631241D);
  static const peach = Color(0xFFE7B092);
  static const peachDark = Color(0xFFC88766);
  static const peachLight = Color(0xFFFFD4B7);
  static const text = Color(0xFFFFF7EB);
  static const muted = Color(0xFFB9AAA1);
  static const success = Color(0xFF65C77A);
  static const warning = Color(0xFFFF2B36);
  static const danger = Color(0xFFE47B75);
  static const actionGlass = Color(0x6631241D);
  static const actionDisabled = Color(0x33211813);
  static const actionBorder = Color(0x66E7B092);

  static ThemeData get theme => ThemeData(
        useMaterial3: true,
        fontFamily: 'Lato',
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        canvasColor: background,
        dialogBackgroundColor: surface,
        cardColor: surfaceGlass,
        primaryColor: peach,
        splashColor: peach.withOpacity(.12),
        highlightColor: peach.withOpacity(.06),
        dividerColor: const Color(0x33E7B092),
        colorScheme: const ColorScheme.dark(
          primary: peach,
          secondary: peachLight,
          surface: surface,
          error: danger,
          onPrimary: Color(0xFF21130D),
          onSecondary: Color(0xFF21130D),
          onSurface: text,
          onError: Colors.white,
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(color: text),
          displayMedium: TextStyle(color: text),
          displaySmall: TextStyle(color: text),
          headlineLarge: TextStyle(color: text),
          headlineMedium: TextStyle(color: text),
          headlineSmall: TextStyle(color: text),
          titleLarge: TextStyle(color: text, fontWeight: FontWeight.w700),
          titleMedium: TextStyle(color: text, fontWeight: FontWeight.w600),
          titleSmall: TextStyle(color: text, fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(color: text),
          bodyMedium: TextStyle(color: text),
          bodySmall: TextStyle(color: muted),
          labelLarge: TextStyle(color: text, fontWeight: FontWeight.w600),
          labelMedium: TextStyle(color: text),
          labelSmall: TextStyle(color: muted),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          foregroundColor: text,
          iconTheme: IconThemeData(color: text),
          actionsIconTheme: IconThemeData(color: text),
          titleTextStyle: TextStyle(
            color: text,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: text),
        listTileTheme: const ListTileThemeData(
          iconColor: peachLight,
          textColor: text,
          titleTextStyle: TextStyle(color: text, fontSize: 16),
          subtitleTextStyle: TextStyle(color: muted, fontSize: 13),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: surface.withOpacity(.98),
          contentTextStyle: const TextStyle(color: text, fontSize: 15),
          actionTextColor: peachLight,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          behavior: SnackBarBehavior.floating,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: surfaceSoft,
          labelStyle: TextStyle(color: peachLight),
          hintStyle: TextStyle(color: muted),
          prefixIconColor: peach,
          suffixIconColor: peachLight,
          contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: Color(0x55E7B092)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: peach, width: 1.4),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: danger),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: danger, width: 1.2),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: actionGlass,
            foregroundColor: text,
            disabledBackgroundColor: actionDisabled,
            disabledForegroundColor: muted,
            side: const BorderSide(color: actionBorder),
            minimumSize: const Size.fromHeight(44),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: actionGlass,
            foregroundColor: text,
            disabledBackgroundColor: actionDisabled,
            disabledForegroundColor: muted,
            side: const BorderSide(color: actionBorder),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: peachLight,
            side: const BorderSide(color: Color(0x88E7B092)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          ),
        ),
        cardTheme: CardThemeData(
          color: surfaceGlass,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0x33E7B092)),
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xF21A120F),
          selectedItemColor: peach,
          unselectedItemColor: muted,
          selectedIconTheme: IconThemeData(color: peach),
          unselectedIconTheme: IconThemeData(color: muted),
          type: BottomNavigationBarType.fixed,
          elevation: 0,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xF21A120F),
          indicatorColor: Color(0x33E7B092),
          iconTheme: MaterialStatePropertyAll(IconThemeData(color: peachLight)),
          labelTextStyle: MaterialStatePropertyAll(TextStyle(color: text)),
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: MaterialStateProperty.resolveWith((states) {
            return states.contains(MaterialState.selected)
                ? peach
                : Colors.white24;
          }),
          checkColor: const MaterialStatePropertyAll(Color(0xFF21130D)),
          side: const BorderSide(color: peachLight),
        ),
        radioTheme: RadioThemeData(
          fillColor: MaterialStateProperty.resolveWith((states) {
            return states.contains(MaterialState.selected) ? peach : muted;
          }),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: MaterialStateProperty.resolveWith((states) {
            return states.contains(MaterialState.selected) ? peachLight : muted;
          }),
          trackColor: MaterialStateProperty.resolveWith((states) {
            return states.contains(MaterialState.selected)
                ? peachDark.withOpacity(.55)
                : surfaceSoft;
          }),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(color: peach),
      );
}

class ClrsBrand {
  static const shortName = 'CLRS';
  static const fullName = 'Christian Lasting Relationships';
  static const ruTagline = 'Знакомства для серьёзных отношений и семьи';
  static const values = 'Семья • доверие • развитие • будущее';
}
