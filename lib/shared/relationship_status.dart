import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';

class RelationshipStatus extends StatefulWidget {
  const RelationshipStatus(
      {super.key, required this.uid, this.editable = false});
  final String uid;
  final bool editable;
  @override
  State<RelationshipStatus> createState() => _RelationshipStatusState();
}

class _RelationshipStatusState extends State<RelationshipStatus> {
  bool _saving = false;
  Future<void> _set(String status) async {
    if (_saving || FirebaseAuth.instance.currentUser?.uid != widget.uid) return;
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .update({'relationStatus': status}).timeout(
              const Duration(seconds: 15));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context
                .tr('Не удалось сохранить статус. Проверьте подключение.'))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(widget.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const SizedBox.shrink();
          final raw = snapshot.data?.data()?['relationStatus']?.toString();
          final label = raw?.startsWith('занят') == true
              ? 'Занят'
              : raw?.startsWith('свобод') == true
                  ? 'Свободен'
                  : 'Статус не указан';
          if (!widget.editable)
            return Text(context.tr(label),
                style: const TextStyle(color: Color(0xFFFFD4B7)));
          return PopupMenuButton<String>(
              enabled: !_saving,
              onSelected: _set,
              itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'свободен', child: Text(context.tr('Свободен'))),
                    PopupMenuItem(
                        value: 'занят', child: Text(context.tr('Занят')))
                  ],
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(context.tr(_saving ? 'Сохранение…' : label)),
                    const SizedBox(width: 6),
                    const Icon(Icons.expand_more, size: 20)
                  ])));
        },
      );
}
