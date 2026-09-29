import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/service/pending_write.dart';
import 'lrs_theme.dart';
import 'package:wbrs/localization/clrs_localizations.dart';

class PasswordResetSheet extends StatefulWidget {
  const PasswordResetSheet({super.key, required this.send});
  final Future<void> Function(String email) send;

  @override
  State<PasswordResetSheet> createState() => _PasswordResetSheetState();
}

class _PasswordResetSheetState extends State<PasswordResetSheet> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  PendingWrite? _operation;
  bool _busy = false;
  bool _sent = false;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _sent) return;
    if (_operation == null && !(_form.currentState?.validate() ?? false))
      return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final email = _email.text.trim();
      _operation ??= PendingWrite(() => widget.send(email));
      final confirmed = await _operation!.wait();
      if (!mounted) return;
      setState(() {
        _sent = confirmed;
        _notice = confirmed
            ? 'Если для этого адреса есть аккаунт, на почту придёт письмо для сброса пароля.'
            : 'Ответ сервера ещё не получен. Проверьте соединение. Повторное нажатие проверяет тот же запрос.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _operation = null;
        _notice = error is FirebaseAuthException &&
                error.code == 'invalid-email'
            ? 'Проверьте email.'
            : error is FirebaseAuthException &&
                    error.code == 'too-many-requests'
                ? 'Слишком много попыток. Попробуйте позднее.'
                : 'Не удалось отправить письмо. Проверьте соединение и повторите попытку.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
          child: Form(
              key: _form,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(
                    controller: _email,
                    readOnly: _operation != null,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(labelText: context.tr('Email')),
                    validator: (value) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                            .hasMatch(value?.trim() ?? '')
                        ? null
                        : context.tr('Введите корректный email')),
                if (_notice != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(context.tr(_notice!),
                          style: const TextStyle(color: LrsTheme.peachLight))),
                if (_busy)
                  const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator()),
                TextButton(
                    onPressed: _busy || _sent ? null : _submit,
                    child: Text(context.tr(_operation != null && !_sent
                        ? 'Проверить результат'
                        : 'Сбросить пароль'))),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(context.tr('Закрыть'))),
              ])),
        ),
      );
}
