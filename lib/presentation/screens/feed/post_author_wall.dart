import 'package:flutter/material.dart';
import 'profile_wall_page.dart';

String postAuthorUid(Map<String, dynamic> post) {
  for (final field in ['authorUid', 'authorId']) {
    final uid = post[field]?.toString().trim() ?? '';
    if (uid.isNotEmpty) return uid;
  }
  return '';
}

void openPostAuthorWall(BuildContext context, Map<String, dynamic> post) {
  final uid = postAuthorUid(post);
  if (uid.isEmpty) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ProfileWallPage(
        userUid: uid,
        userName: post['authorName']?.toString(),
      ),
    ),
  );
}
