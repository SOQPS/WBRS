import 'package:wbrs/core/utils/account_destination.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/helper/helper_function.dart';
import 'package:wbrs/presentation/screens/auth/login_screen/login_page.dart';
import 'package:wbrs/presentation/screens/auth/writing_profile_page/writing_data_user.dart';
import 'package:wbrs/presentation/screens/profile/profile_page.dart';
import 'package:wbrs/presentation/screens/list_of_users/profiles_list.dart';
import 'package:wbrs/presentation/screens/test/red_group.dart';
import 'package:wbrs/service/auth_service.dart';
import 'package:wbrs/service/profile_draft_store.dart';
import 'package:wbrs/service/session_service.dart';

/// Server account state, never the presence of local preferences, chooses the
/// destination. Missing or partial profiles resume registration without deleting Auth.
class SessionGate extends StatefulWidget {
  const SessionGate(
      {super.key,
      this.onReady,
      this.auth,
      this.firestore,
      this.destinationBuilder,
      this.draftStore,
      this.showProfileAfterTest = false,
      this.enforceRememberMe = false});
  final VoidCallback? onReady;
  final FirebaseAuth? auth;
  final FirebaseFirestore? firestore;
  final ProfileDraftStore? draftStore;
  /// Only the transition immediately after finishing the questionnaire opens
  /// the own profile. Later logins start in search.
  final bool showProfileAfterTest;

  /// Only the app's cold-start gate enforces this. A gate opened immediately
  /// after interactive login or registration must keep that live session.
  final bool enforceRememberMe;
  final Widget Function(AccountDestination, Map<String, dynamic>?)?
      destinationBuilder;
  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  late Future<Widget> _destination;
  int _generation = 0;
  FirebaseAuth get _auth => widget.auth ?? firebaseAuth;
  FirebaseFirestore get _db => widget.firestore ?? firebaseFirestore;
  @override
  void initState() {
    super.initState();
    _destination = _load();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<Widget> _load() async {
    final generation = ++_generation;
    await SessionService.clearLocal();
    if (!mounted || generation != _generation) return const SizedBox.shrink();
    final user = _auth.currentUser;
    if (user == null) return const LoginPage();
    if (widget.enforceRememberMe) {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted ||
          generation != _generation ||
          _auth.currentUser?.uid != user.uid) return const LoginPage();
      // No saved preference means an account from an older app version; keep
      // its established session rather than unexpectedly signing it out.
      if (prefs.getBool('remember_me') == false) {
        await AuthService(auth: _auth, firestore: _db).signOut();
        return const LoginPage();
      }
    }
    bool current() =>
        mounted &&
        generation == _generation &&
        _auth.currentUser?.uid == user.uid;
    final snapshot = await _db
        .collection('users')
        .doc(user.uid)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 20));
    if (!current()) return const LoginPage();
    final data = snapshot.data();
    final destination = accountDestination(data);
    if (destination == AccountDestination.blocked ||
        destination == AccountDestination.deleted) {
      await AuthService(auth: _auth, firestore: _db).signOut();
      throw StateError(destination == AccountDestination.blocked
          ? 'Ваш аккаунт заблокирован. Обратитесь в поддержку.'
          : 'Профиль удалён. Обратитесь в поддержку.');
    }
    if (destination == AccountDestination.registration) {
      return widget.destinationBuilder?.call(destination, data) ??
          const AboutUserWriting();
    }
    await HelperFunctions.saveUserLoggedInStatus(true);
    if (!current()) return const LoginPage();
    await HelperFunctions.saveUserEmailSF(user.email ?? '');
    if (!current()) return const LoginPage();
    await HelperFunctions.saveUserNameSF(
        data?['fullName']?.toString() ?? user.displayName ?? '');
    if (!current()) return const LoginPage();
    SessionService.hydrate(data!);
    // Server confirmation takes precedence over any stale local draft after a
    // process was killed between profile commit and local acknowledgement.
    (widget.draftStore ?? ProfileDraftStore())
        .clear(user.uid)
        .catchError((_) {});
    if (destination == AccountDestination.search) {
      selectedIndex = widget.showProfileAfterTest ? 4 : 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current()) {
          SessionService.readyUserId.value = user.uid;
          widget.onReady?.call();
        }
      });
    }
    if (widget.destinationBuilder != null) {
      return widget.destinationBuilder!(destination, data);
    }
    if (destination == AccountDestination.test) return const FirstGroupRed();
    if (!widget.showProfileAfterTest) {
      return ProfilesList(startPosition: 0, group: group);
    }
    return ProfilePage(
        group: group,
        email: user.email ?? '',
        userName: data['fullName']?.toString() ?? user.displayName ?? '',
        about: data['about']?.toString() ?? '',
        age: data['age']?.toString() ?? '',
        rost: data['rost']?.toString() ?? '',
        hobbi: data['hobbi']?.toString() ?? '',
        city: data['city']?.toString() ?? data['region']?.toString() ?? '',
        deti: data['deti'] == true,
        pol: data['pol']?.toString() ?? '');
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Widget>(
      future: _destination,
      builder: (context, snapshot) {
        if (snapshot.hasData) return snapshot.data!;
        if (snapshot.hasError) {
          final message = snapshot.error is StateError
              ? (snapshot.error as StateError).message.toString()
              : 'Не удалось загрузить профиль. Проверьте соединение и повторите попытку.';
          return ClrsScaffold(
              body: SafeArea(
                  child: Center(
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 460),
                              child: ClrsPanel(
                                  child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                    Text(context.tr(message),
                                        textAlign: TextAlign.center),
                                    const SizedBox(height: 16),
                                    ElevatedButton(
                                        onPressed: () => setState(() {
                                              _destination = _load();
                                            }),
                                        child: Text(context.tr('Повторить'))),
                                    TextButton(
                                        onPressed: () async {
                                          await AuthService(
                                                  auth: _auth, firestore: _db)
                                              .signOut();
                                          if (!mounted) return;
                                          setState(() {
                                            _generation++;
                                            _destination =
                                                Future.value(const LoginPage());
                                          });
                                        },
                                        child: Text(
                                            context.tr('Вернуться ко входу'))),
                                  ])))))));
        }
        return const ClrsScaffold(
            body: Center(child: CircularProgressIndicator()));
      });
}
