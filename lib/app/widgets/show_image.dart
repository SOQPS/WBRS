import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/shared/lrs_theme.dart';
import 'package:wbrs/service/profile_photo_upload.dart';
import 'package:wbrs/service/session_service.dart';

class ShowImage extends StatefulWidget {
  final int index;
  final List initList;
  final List urls;
  final AsyncSnapshot snapshot;
  const ShowImage({
    super.key,
    required this.urls,
    required this.index,
    required this.initList,
    required this.snapshot,
  });

  @override
  State<ShowImage> createState() => _ShowImageState();
}

class _ShowImageState extends State<ShowImage> {
  late final String? _owner = firebaseAuth.currentUser?.uid;
  bool _changingAvatar = false;
  bool get _sameSession =>
      _owner != null && firebaseAuth.currentUser?.uid == _owner;

  Future<void> _makeAvatar() async {
    if (_changingAvatar || !_sameSession) return;
    final user = firebaseAuth.currentUser!;
    final url = '${widget.urls[widget.index]}';
    final docs = widget.snapshot.data?.docs ?? [];
    String? thumbnailUrl;
    for (final doc in docs) {
      if (doc.data()['url'] == url) {
        thumbnailUrl = doc.data()['thumbnailUrl']?.toString();
        break;
      }
    }
    setState(() => _changingAvatar = true);
    try {
      final writeTimer = Stopwatch()..start();
      // Bind the write to the owner who opened the gallery. Retrying the same
      // URL is idempotent even when Firestore confirmation arrives late.
      await firebaseFirestore.collection('users').doc(_owner).update({
        'profilePic': url,
        'profilePicThumb': thumbnailUrl ?? FieldValue.delete(),
      }).timeout(const Duration(seconds: 15));
      profilePhotoMetric('profile_write', writeTimer.elapsed);
      if (!_sameSession) return;
      try {
        await user.updatePhotoURL(url).timeout(const Duration(seconds: 10));
      } catch (_) {
        // Firestore is authoritative for the displayed avatar; Auth metadata
        // failure must not undo or conceal the already saved profile photo.
      }
      if (mounted && _sameSession) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr('Профиль сохранён'))));
      }
    } catch (_) {
      if (mounted && _sameSession) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context
                .tr('Не удалось сохранить изменения. Попробуйте ещё раз.'))));
      }
    } finally {
      if (mounted) setState(() => _changingAvatar = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: SessionService.readyUserId,
      builder: (context, _) =>
          _sameSession ? _gallery(context) : const SizedBox.shrink());

  Widget _gallery(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          Row(
            children: [
              TextButton(
                  onPressed:
                      _changingAvatar || !_sameSession ? null : _makeAvatar,
                  child: Text(context.tr('Сделать аватаром'),
                      style: TextStyle(color: Colors.white))),
              IconButton(
                  onPressed: () {
                    deleteImage(widget.snapshot, widget.index);
                  },
                  icon: const Icon(Icons.delete)),
              IconButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.close)),
            ],
          )
        ],
      ),
      body: Dismissible(
          key: UniqueKey(),
          onDismissed: (direction) {
            if (direction == DismissDirection.endToStart) {
              moveToNext();
            } else {
              moveToPrevious();
            }
          },
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 2,
            panEnabled: false,
            scaleEnabled: true,
            boundaryMargin: const EdgeInsets.all(100),
            child: CachedNetworkImage(
              imageUrl: widget.urls[widget.index],
              imageBuilder: (context, imageProvider) => Container(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(10)),
                  image: DecorationImage(
                      image: imageProvider, fit: BoxFit.fitWidth),
                ),
              ),
              fit: BoxFit.cover,
              placeholder: (context, url) => SizedBox(
                  height: MediaQuery.of(context).size.height * .3,
                  child: const Center(child: CircularProgressIndicator())),
              errorWidget: (context, url, error) => SizedBox(
                  height: MediaQuery.of(context).size.height * .3,
                  child: const Center(child: Icon(Icons.error))),
            ),
          )),
    );
  }

  moveToNext() {
    if (widget.index == widget.urls.length - 1) {
      nextScreenReplace(
          context,
          ShowImage(
            index: 0,
            initList: widget.initList,
            urls: widget.urls,
            snapshot: widget.snapshot,
          ));
    } else {
      nextScreenReplace(
          context,
          ShowImage(
            index: widget.index + 1,
            initList: widget.initList,
            urls: widget.urls,
            snapshot: widget.snapshot,
          ));
    }
  }

  moveToPrevious() {
    if (widget.index == 0) {
      nextScreenReplace(
          context,
          ShowImage(
            index: widget.urls.length - 1,
            initList: widget.initList,
            urls: widget.urls,
            snapshot: widget.snapshot,
          ));
    } else {
      nextScreenReplace(
          context,
          ShowImage(
            index: widget.index - 1,
            initList: widget.initList,
            urls: widget.urls,
            snapshot: widget.snapshot,
          ));
    }
  }

  deleteImage(snapshot, index) {
    if (!_sameSession) return;
    showCupertinoModalPopup(
        context: context,
        builder: (context) {
          return Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white,
                width: 1,
              ),
              color: darkGrey,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DefaultTextStyle(
                  style: TextStyle(
                      decorationColor: Colors.white,
                      fontStyle: FontStyle.normal,
                      color: Colors.white,
                      fontSize: 16),
                  child: Text(
                      context.tr('Вы уверены, что хотите удалить это фото?')),
                ),
                const SizedBox(
                  height: 20,
                ),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: LrsTheme.actionGlass,
                            foregroundColor: LrsTheme.danger,
                            side: BorderSide(
                                color: LrsTheme.danger.withValues(alpha: .75))),
                        onPressed: () {
                          if (!_sameSession) return;
                          FirebaseStorage.instance
                              .refFromURL(snapshot.data!.docs[index]['url'])
                              .delete();
                          firebaseFirestore
                              .collection('users')
                              .doc(_owner)
                              .collection('images')
                              .doc(snapshot.data!.docs[index].id)
                              .delete();
                          if (index == 0) {
                            moveToNext();
                          } else {
                            moveToPrevious();
                          }
                        },
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: Text(context.tr('Удалить'))),
                    ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: LrsTheme.actionGlass,
                            foregroundColor: LrsTheme.text,
                            side:
                                const BorderSide(color: LrsTheme.actionBorder)),
                        onPressed: () {
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.close, size: 18),
                        label: Text(context.tr('Отмена'))),
                  ],
                )
              ],
            ),
          );
        });
  }
}
