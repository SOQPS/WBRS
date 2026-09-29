import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:wbrs/service/admin_access.dart';
import 'package:wbrs/service/social_service.dart';
import 'package:wbrs/shared/clrs_screen.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/shared/translatable_text.dart';

class RoleRequestsPage extends StatelessWidget {
  const RoleRequestsPage({super.key});

  @override
  Widget build(BuildContext context) => AdminGuard(
        child: DefaultTabController(
          length: 2,
          child: ClrsScaffold(
            appBar: AppBar(
              title: Text(context.tr('Заявки на роли')),
              bottom: TabBar(tabs: [
                Tab(text: context.tr('Авторы')),
                Tab(text: context.tr('Модераторы')),
              ]),
            ),
            body: const TabBarView(children: [
              _RoleRequestList(role: 'author'),
              _RoleRequestList(role: 'moderator'),
            ]),
          ),
        ),
      );
}

class _RoleRequestList extends StatefulWidget {
  const _RoleRequestList({required this.role});
  final String role;

  @override
  State<_RoleRequestList> createState() => _RoleRequestListState();
}

class _RoleRequestListState extends State<_RoleRequestList> {
  late final SocialService _social = SocialService();
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _requests =
      _social.roleRequests(widget.role);
  final _busy = <String>{};

  Future<void> _review(String uid, bool approve) async {
    if (!_busy.add(uid)) return;
    setState(() {});
    try {
      await _social
          .reviewRoleRequest(
              role: widget.role, applicantUid: uid, approve: approve)
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              context.tr(approve ? 'Заявка одобрена' : 'Заявка отклонена'))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('Не удалось обработать заявку.'))));
    } finally {
      if (mounted) setState(() => _busy.remove(uid));
    }
  }

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _requests,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
                child: Text(context.tr('Не удалось загрузить заявки.')));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final requests = snapshot.data!.docs;
          if (requests.isEmpty) {
            return Center(child: Text(context.tr('Новых заявок нет')));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: requests.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final request = requests[index];
              final data = request.data();
              final name = data['fullName']?.toString() ?? '';
              final waiting = _busy.contains(request.id);
              return ClrsPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name.isEmpty ? request.id : name,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (widget.role == 'author') RoleRequestPreview(data: data),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, children: [
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: LrsTheme.actionGlass,
                          foregroundColor: LrsTheme.text,
                        ),
                        onPressed:
                            waiting ? null : () => _review(request.id, true),
                        child: Text(context.tr('Принять')),
                      ),
                      OutlinedButton(
                        onPressed:
                            waiting ? null : () => _review(request.id, false),
                        child: Text(context.tr('Отклонить')),
                      ),
                    ]),
                  ],
                ),
              );
            },
          );
        },
      );
}

class RoleRequestPreview extends StatelessWidget {
  const RoleRequestPreview({super.key, required this.data});
  final Map<String, dynamic> data;
  @override
  Widget build(BuildContext context) {
    final text = data['proposedText']?.toString() ?? '';
    final image = data['proposedImageUrl']?.toString() ?? '';
    if (text.isEmpty && image.isEmpty) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(context.tr('Предлагаемая публикация'),
            style: const TextStyle(color: LrsTheme.peachLight)),
        const SizedBox(height: 6),
        if (text.isNotEmpty) TranslatableText(text),
        if (image.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
          child: CachedNetworkImage(imageUrl: image, height: 180,
            fit: BoxFit.contain,
            placeholder: (_, __) => const Center(child: CircularProgressIndicator()),
            errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined))),
      ]));
  }
}
