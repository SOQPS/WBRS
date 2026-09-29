import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'clrs_localizations.dart';

/// Persists language choice independently of authentication/session cleanup.
class LocaleController extends ChangeNotifier {
  LocaleController();
  static final instance = LocaleController();
  static const preferenceKey = 'clrs_ui_language';
  Locale _locale = const Locale('ru');
  Locale get locale => _locale;
  bool _initialized = false;
  bool get initialized => _initialized;
  SharedPreferences? _preferences;
  Future<void> _saveTail = Future<void>.value();

  Future<void> initialize(
      {Locale? deviceLocale, SharedPreferences? preferences}) async {
    _preferences = preferences ?? await SharedPreferences.getInstance();
    final stored =
        ClrsLocalizations.normalizeCode(_preferences!.getString(preferenceKey));
    _locale = ClrsLocalizations.codes.contains(stored)
        ? ClrsLocalizations.localeFor(stored)
        : ClrsLocalizations.resolveLocale(
            deviceLocale ?? WidgetsBinding.instance.platformDispatcher.locale);
    _initialized = true;
    notifyListeners();
  }

  Future<void> setLanguage(String code) {
    final language = ClrsLocalizations.normalizeCode(code);
    if (!ClrsLocalizations.codes.contains(language)) {
      return Future<void>.error(
          ArgumentError.value(code, 'code', 'Unsupported UI language'));
    }
    // Serialize saves so a slower earlier request cannot overwrite the latest.
    final operation = _saveTail.then((_) async {
      final preferences =
          _preferences ??= await SharedPreferences.getInstance();
      if (!await preferences.setString(preferenceKey, language)) {
        throw StateError('Could not persist UI language');
      }
      _locale = ClrsLocalizations.localeFor(language);
      _initialized = true;
      notifyListeners();
    });
    _saveTail = operation.catchError((Object _) {});
    return operation;
  }
}
