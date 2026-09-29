import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/group_avatar.dart';

class MyVisitersPage extends StatefulWidget {
  const MyVisitersPage({super.key, required this.visiters});
  final Stream? visiters;
  @override
  State<MyVisitersPage> createState() => _MyVisitersPageState();
}

class _MyVisitersPageState extends State<MyVisitersPage> {
  late final String? _owner = firebaseAuth.currentUser?.uid;
  late Stream<QuerySnapshot> _visitors = _source();
  bool _opening = false;
  int _attempt = 0;
  Stream<QuerySnapshot> _source() =>
      widget.visiters?.map((x) => x as QuerySnapshot) ??
      (_owner == null
          ? Stream.error(StateError('Сеанс завершён'))
          : firebaseFirestore
              .collection('users')
              .doc(_owner)
              .collection('visiters')
              .orderBy('lastVisitTs', descending: true)
              .snapshots());
  @override
  void didUpdateWidget(covariant MyVisitersPage old) {
    super.didUpdateWidget(old);
    if (old.visiters != widget.visiters) _visitors = _source();
  }

  Future<void> _open(Map<String, dynamic> visitor) async {
    if (_opening || firebaseAuth.currentUser?.uid != _owner) return;
    final uid = '${visitor['uid'] ?? ''}';
    if (uid.isEmpty) return;
    setState(() => _opening = true);
    try {
      final doc = await firebaseFirestore
          .collection('users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 15));
      if (!mounted || firebaseAuth.currentUser?.uid != _owner) return;
      if (!doc.exists || doc.data()?['status'] == 'deleted') {
        throw StateError('Профиль недоступен');
      }
      final data = doc.data()!;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SomebodyProfile(
              uid: uid,
              photoUrl: '${data['profilePic'] ?? ''}',
              name: '${data['fullName'] ?? ''}',
              userInfo: data)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context
                .tr('Не удалось открыть профиль. Попробуйте ещё раз.'))));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => ClrsScaffold(
      appBar: AppBar(title: Text(context.tr('Мои гости'))),
      body: StreamBuilder<QuerySnapshot>(
          key: ValueKey(_attempt),
          stream: _visitors,
          builder: (context, snapshot) =>
              ListView(padding: const EdgeInsets.all(14), children: [
                const ClrsBrandHeader(),
                if (_opening) const LinearProgressIndicator(),
                if (snapshot.hasError)
                  ClrsPanel(
                      child: Column(children: [
                    Text(context.tr('Не удалось загрузить список.')),
                    TextButton(
                        onPressed: () => setState(() {
                              _attempt++;
                              _visitors = _source();
                            }),
                        child: Text(context.tr('Повторить')))
                  ]))
                else if (!snapshot.hasData)
                  const Center(child: CircularProgressIndicator())
                else if (snapshot.data!.docs.isEmpty)
                  ClrsPanel(
                      child: Text(
                          context.tr('Пока на вашей странице не было гостей.')))
                else
                  for (final doc in snapshot.data!.docs)
                    _tile(Map<String, dynamic>.from(doc.data() as Map)),
              ])));
  Widget _tile(Map<String, dynamic> d) {
    final rawDate = d['lastVisitTs'];
    final date = rawDate is Timestamp
        ? rawDate.toDate()
        : rawDate is DateTime
            ? rawDate
            : null;
    final age = num.tryParse('${d['age'] ?? ''}');
    return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: ClrsPanel(
            padding: EdgeInsets.zero,
            child: ListTile(
                contentPadding: const EdgeInsets.all(12),
                leading: GroupAvatar(
                    url: '${d['photoUrl'] ?? ''}',
                    group: '${d['group'] ?? ''}',
                    size: 46),
                title: Text('${d['fullName'] ?? ''}'),
                subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (age != null)
                        Text(context.tr('{count} лет', count: age)),
                      if (date != null)
                        Text(context.tr('Последнее посещение: {date}',
                            args: {'date': context.l10n.dateTime(date)})),
                    ]),
                onTap: _opening ? null : () => _open(d),
                trailing: const Icon(Icons.chevron_right, size: 18))));
  }
}
