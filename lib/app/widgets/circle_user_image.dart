import 'package:flutter/material.dart';
import 'package:wbrs/shared/group_avatar.dart';

class UserImage extends StatelessWidget {
  const UserImage(
      {super.key,
      this.uid,
      required this.userPhotoUrl,
      required this.group,
      this.width = 100,
      this.height = 100,
      required this.online});
  final String? userPhotoUrl;
  final String group;
  final double width, height;
  final String? uid;
  final bool online;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: width,
      height: height,
      child: Stack(children: [
        Positioned.fill(
            child: GroupAvatar(
                url: userPhotoUrl ?? '', group: group, size: width)),
        if (online)
          Positioned(
              right: 4,
              top: 4,
              child: Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                      color: Color(0xFF65C77A), shape: BoxShape.circle))),
      ]));
}
