import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_app_runtime.dart';
import 'package:wbrs/shared/clrs_screen.dart';

import 'login_screen/login_page.dart';

/// Actual native account state + pinned full DTO only. Next native destinations
/// remain unavailable until their own current services/onboarding are wired.
/// This gate never enters Firebase SessionGate/Home or hydrates legacy globals.
class TimewebSessionGate extends StatefulWidget {
  const TimewebSessionGate({super.key, required this.runtime});
  final TimewebAppRuntime runtime;
  @override
  State<TimewebSessionGate> createState() => _TimewebSessionGateState();
}

class _TimewebSessionGateState extends State<TimewebSessionGate> {
  StreamSubscription<AppSessionState>? _subscription;
  TimewebSessionProfile? _profile;
  int? _loadedEpoch;
  int _generation = 0;
  bool _loading = false;
  bool _error = false;
  bool _showLogin = false;
  bool _hasAttemptedRead = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.runtime.session.states.listen((_) => _sync());
    _sync();
  }

  void _sync() {
    final state = widget.runtime.session.state;
    if (state.authenticated) {
      _showLogin = false;
    } else if (const {
      AppSessionPhase.signedOut,
      AppSessionPhase.failed,
      AppSessionPhase.unresolved,
      AppSessionPhase.stopped,
      AppSessionPhase.closed,
    }.contains(state.phase)) {
      _showLogin = true;
    }
    if (_loadedEpoch != state.epoch) {
      _generation++;
      _profile = null;
      _loading = false;
      _error = false;
      _loadedEpoch = state.epoch;
      _hasAttemptedRead = false;
    }
    // Login changes the epoch before its identity is confirmed. Read only once
    // that same epoch becomes authenticated, even when the epoch itself stays.
    if (state.authenticated && !_hasAttemptedRead) {
      _hasAttemptedRead = true;
      unawaited(_load());
    }
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final epoch = widget.runtime.session.state.epoch;
    setState(() {
      _loading = true;
      _error = false;
      _profile = null;
    });
    try {
      final profile = await widget.runtime.readGateProfile();
      if (!mounted ||
          generation != _generation ||
          widget.runtime.session.state.epoch != epoch) {
        return;
      }
      profile.requireCurrent();
      setState(() => _profile = profile);
    } catch (_) {
      if (mounted &&
          generation == _generation &&
          widget.runtime.session.state.epoch == epoch) {
        setState(() => _error = true);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_subscription?.cancel());
    // The app owns the session. Leaving this screen is neither logout nor stop.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.runtime.session.state;
    final terminal =
        state.phase == AppSessionPhase.stopped ||
        state.phase == AppSessionPhase.closed;
    if (!terminal && _showLogin) {
      return LoginPage(nativeRuntime: widget.runtime);
    }
    if (!terminal && (!state.authenticated || _loading)) {
      return const ClrsScaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    String? stage;
    try {
      stage = _profile?.onboarding.name;
    } catch (_) {
      // A queued rebuild must not render an old A snapshot after a B intent.
    }
    return ClrsScaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ClrsPanel(
              key: ValueKey('timeweb-gate-${stage ?? 'unavailable'}'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(context.tr('Профиль недоступен')),
                  const SizedBox(height: 12),
                  Text(
                    context.tr(
                      _error
                          ? 'Не удалось загрузить профиль. Проверьте соединение и повторите попытку.'
                          : 'Сервис пока недоступен. Попробуйте позднее.',
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: terminal ? null : _load,
                    child: Text(context.tr('Повторить')),
                  ),
                  TextButton(
                    onPressed: terminal
                        ? null
                        : () async {
                            await widget.runtime.session.logout();
                            if (mounted) _sync();
                          },
                    child: Text(context.tr('Вернуться ко входу')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
