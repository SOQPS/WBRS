import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/app_session.dart';
import 'package:wbrs/service/timeweb_profile_edit_flow.dart';
import 'package:wbrs/shared/clrs_screen.dart';

/// Existing CLRS form treatment over the real native current-profile API.
/// This editor cannot finish onboarding or navigate into Firebase destinations.
class TimewebProfileEditPage extends StatefulWidget {
  const TimewebProfileEditPage({super.key, required this.flow});
  final TimewebProfileEditFlow flow;
  @override
  State<TimewebProfileEditPage> createState() => _TimewebProfileEditPageState();
}

class _TimewebProfileEditPageState extends State<TimewebProfileEditPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _about = TextEditingController();
  final _interests = TextEditingController();
  bool _busy = false;
  bool _invalidated = false;
  String? _notice;
  StreamSubscription<AppSessionState>? _subscription;

  @override
  void initState() {
    super.initState();
    try {
      widget.flow.requireCurrent();
      _name.text = widget.flow.fullName;
      _about.text = widget.flow.about;
      _interests.text = widget.flow.hobbi;
      if (widget.flow.needsCheck) {
        _notice =
            'Результат пока не подтверждён. Нажмите «Проверить результат».';
      }
    } catch (_) {
      _invalidated = true;
    }
    _subscription = widget.flow.sessionStates.listen((_) {
      if (!_current) _invalidate();
    });
  }

  bool get _current {
    if (!mounted || _invalidated) return false;
    try {
      widget.flow.requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _name.clear();
    _about.clear();
    _interests.clear();
    setState(() {});
    // Session invalidation closes this route. It never changes the app owner.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  String? _validate(String field, String? value) {
    if (!_current) return null;
    final text = value ?? '';
    // Historical null/short values are left untouched unless the user edits
    // that field. Saving a name must not rewrite an old nullable description.
    if (!widget.flow.fieldChanged(field, text)) return null;
    if (field == 'fullName' && text.trim().isEmpty) {
      return context.tr('Имя не может быть пустым');
    }
    if (field != 'fullName' && text.trim().runes.length < 20) {
      return context.tr('Минимум 20 символов');
    }
    return null;
  }

  Future<void> _submit() async {
    if (_busy || !_current) return;
    final check = widget.flow.needsCheck;
    if (!check && !(_form.currentState?.validate() ?? false)) return;
    if (!check &&
        !widget.flow.hasChanges(
          fullName: _name.text,
          about: _about.text,
          hobbi: _interests.text,
        )) {
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final original = check
          ? widget.flow.check()
          : widget.flow.save(
              fullName: _name.text,
              about: _about.text,
              hobbi: _interests.text,
            );
      // Observe the same operation within a bounded UI interval. A timeout
      // does not clear/retry a POST; the next tap checks that original handle.
      final result = await original.timeout(widget.flow.observationTimeout);
      if (!mounted || !_current || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      switch (result) {
        case TimewebProfileEditOutcome.confirmed:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr('Профиль сохранён'))),
          );
          Navigator.of(context).pop(true);
        case TimewebProfileEditOutcome.rejected:
          setState(
            () =>
                _notice = 'Не удалось сохранить изменения. Попробуйте ещё раз.',
          );
        case TimewebProfileEditOutcome.unknown:
          setState(
            () => _notice =
                'Результат пока не подтверждён. Нажмите «Проверить результат».',
          );
      }
    } on TimeoutException {
      if (_current) {
        setState(
          () => _notice =
              'Результат пока не подтверждён. Нажмите «Проверить результат».',
        );
      }
    } catch (_) {
      if (_current) {
        setState(
          () => _notice = widget.flow.needsCheck
              ? 'Результат пока не подтверждён. Нажмите «Проверить результат».'
              : 'Не удалось сохранить изменения. Попробуйте ещё раз.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    widget.flow.close();
    unawaited(_subscription?.cancel());
    _name.dispose();
    _about.dispose();
    _interests.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final pending = current && widget.flow.needsCheck;
    final reload = current && widget.flow.requiresReload;
    return ClrsScaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(context.tr('Редактировать профиль')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ClrsPanel(
            child: current
                ? Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          key: const ValueKey('timeweb-profile-name'),
                          controller: _name,
                          enabled: !_busy && !pending && !reload,
                          maxLength: 1000,
                          decoration: InputDecoration(
                            labelText: context.tr('Имя'),
                          ),
                          validator: (v) => _validate('fullName', v),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const ValueKey('timeweb-profile-about'),
                          controller: _about,
                          enabled: !_busy && !pending && !reload,
                          minLines: 3,
                          maxLines: null,
                          maxLength: 4096,
                          decoration: InputDecoration(
                            labelText: context.tr('О себе'),
                          ),
                          validator: (v) => _validate('about', v),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const ValueKey('timeweb-profile-interests'),
                          controller: _interests,
                          enabled: !_busy && !pending && !reload,
                          minLines: 3,
                          maxLines: null,
                          maxLength: 4096,
                          decoration: InputDecoration(
                            labelText: context.tr('Интересы и увлечения'),
                          ),
                          validator: (v) => _validate('hobbi', v),
                        ),
                        if (_notice != null) ...[
                          const SizedBox(height: 12),
                          Text(context.tr(_notice!)),
                        ],
                        const SizedBox(height: 16),
                        if (reload)
                          TextButton(
                            key: const ValueKey('timeweb-profile-reload'),
                            onPressed: _busy
                                ? null
                                : () => Navigator.of(context).pop(false),
                            child: Text(context.tr('Обновить')),
                          )
                        else
                          ElevatedButton(
                            key: const ValueKey('timeweb-profile-save'),
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    context.tr(
                                      pending
                                          ? 'Проверить результат'
                                          : 'Сохранить',
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  )
                : Text(
                    context.tr('Сеанс изменился. Откройте этот экран заново.'),
                  ),
          ),
        ),
      ),
    );
  }
}
