import 'dart:async';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/presentation/screens/list_of_users/show/somebody_profile.dart';
import 'package:wbrs/app/widgets/circle_user_image.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/service/admin_access.dart';
import 'package:wbrs/service/admin_private_directory.dart';

import '../../widgets/bottom_nav_bar.dart';

class Users extends StatefulWidget {
  const Users({super.key, this.privateEmail = adminPrivateEmailEnabled});
  final bool privateEmail;

  @override
  State<Users> createState() => _UsersState();
}

class _UsersState extends State<Users> {
  AdminPrivateDirectory? _privateDirectory;
  TextEditingController search = TextEditingController();
  Stream users = firebaseFirestore
      .collection('users')
      .orderBy('fullName', descending: false)
      .snapshots();

  @override
  void initState() {
    super.initState();
    if (widget.privateEmail)
      _privateDirectory = AdminPrivateDirectory(enabled: true);
  }

  @override
  void dispose() {
    unawaited(_privateDirectory?.dispose());
    search.dispose();
    super.dispose();
  }

  Widget _privateSessionView(Widget child) => !widget.privateEmail
      ? child
      : AnimatedBuilder(
          animation: _privateDirectory!.visibility,
          builder: (context, _) => _privateDirectory!.isCurrentSession
              ? child
              : Center(
                  child:
                      Text(context.tr('Не удалось загрузить пользователей'))));

  @override
  Widget build(BuildContext context) {
    showConfirmMessage(Function callback, String action) {
      showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(
                context.tr(action == 'удалить'
                    ? 'Удалить пользователя?'
                    : 'Заблокировать пользователя?'),
                style: const TextStyle(fontSize: 20),
              ),
              actions: [
                TextButton(
                    onPressed: () {
                      callback();
                      Navigator.pop(context);
                    },
                    child: Text(context.tr('Да'))),
                TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    child: Text(context.tr('Нет'))),
              ],
            );
          });
    }

    return AdminGuard(
        child: Stack(
      children: [
        Container(
          decoration: const BoxDecoration(boxShadow: []),
          child: Image.asset(
            'assets/final_design/family_right.png',
            height: MediaQuery.of(context).size.height,
            width: MediaQuery.of(context).size.width,
            fit: BoxFit.cover,
            scale: 0.6,
          ),
        ),
        Theme(
          data: ThemeData(brightness: Brightness.dark),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              iconTheme: const IconThemeData(color: Colors.white),
              backgroundColor: Colors.transparent,
              title: TextField(
                controller: search,
                onSubmitted: (value) {
                  setState(() {
                    if (value.contains('@')) {
                      users = widget.privateEmail
                          ? _privateDirectory!.searchEmail(value)
                          : firebaseFirestore
                              .collection('users')
                              .where('email', isGreaterThanOrEqualTo: value)
                              .snapshots();
                    } else {
                      users = firebaseFirestore
                          .collection('users')
                          .where('fullName', isGreaterThanOrEqualTo: value)
                          .snapshots();
                    }
                  });
                },
              ),
            ),
            bottomNavigationBar: const MyBottomNavigationBar(),
            body: Container(
              padding: const EdgeInsets.all(5),
              child: _privateSessionView(StreamBuilder(
                  stream: users,
                  builder: (context, snapshot) {
                    if (widget.privateEmail &&
                        (snapshot.hasError ||
                            !_privateDirectory!.isCurrentSession)) {
                      return Center(
                          child: Text(context
                              .tr('Не удалось загрузить пользователей')));
                    }
                    if (snapshot.hasData) {
                      return ListView.builder(
                        itemCount: snapshot.data!.docs.length,
                        itemBuilder: (context, index) {
                          TextEditingController controller =
                              TextEditingController(
                                  text: snapshot.data!.docs[index]['balance']
                                      .toString());
                          return GestureDetector(
                            onTap: () => nextScreen(
                                context,
                                SomebodyProfile(
                                  privateEmail: widget.privateEmail,
                                  uid: snapshot.data!.docs[index].id,
                                  photoUrl: snapshot.data!.docs[index]
                                      ['profilePic'],
                                  name: snapshot.data!.docs[index]['fullName'],
                                  userInfo: snapshot.data!.docs[index].data(),
                                )),
                            child: Container(
                              padding: const EdgeInsets.all(5),
                              margin: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                color: grey,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                                      SizedBox(
                                        width: 50,
                                        child: TextField(
                                            textAlign: TextAlign.center,
                                            controller: controller,
                                            onSubmitted: (value) {
                                              firebaseFirestore
                                                  .collection('users')
                                                  .doc(snapshot
                                                      .data!.docs[index].id)
                                                  .update({
                                                'balance': int.parse(value)
                                              });
                                            }),
                                      ),
                                      snapshot.data!.docs[index]['status'] ==
                                              'blocked'
                                          ? const Icon(
                                              Icons.block,
                                              color: Colors.green,
                                              size: 40,
                                            )
                                          : IconButton(
                                              onPressed: () {
                                                showConfirmMessage(() {
                                                  firebaseFirestore
                                                      .collection('users')
                                                      .doc(snapshot
                                                          .data!.docs[index].id)
                                                      .update({
                                                    'status': 'blocked'
                                                  });
                                                }, 'заблокировать');
                                              },
                                              icon: const Icon(
                                                Icons.block,
                                                color: Colors.redAccent,
                                                size: 40,
                                              ),
                                            ),
                                      UserImage(
                                        userPhotoUrl: snapshot.data!.docs[index]
                                            ['profilePic'],
                                        group: snapshot.data!.docs[index]
                                            ['группа'],
                                        width: 50,
                                        height: 50,
                                        online: snapshot.data!.docs[index]
                                            ['online'],
                                      ),
                                      IconButton(
                                        onPressed: () {
                                          showConfirmMessage(() {
                                            firebaseFirestore
                                                .collection('TOKENS')
                                                .doc(snapshot
                                                    .data!.docs[index].id)
                                                .delete();
                                            firebaseFirestore
                                                .collection('users')
                                                .doc(snapshot
                                                    .data!.docs[index].id)
                                                .delete();
                                          }, 'удалить');
                                        },
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          color: Colors.red,
                                          size: 40,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                                      Text(snapshot.data!.docs[index]
                                          ['fullName']),
                                      if (widget.privateEmail)
                                        AdminPrivateEmail(
                                            directory: _privateDirectory!,
                                            uid: snapshot.data!.docs[index].id,
                                            builder: (email) => Text(email))
                                      else
                                        Text(
                                            '${(snapshot.data!.docs[index].data() as Map)['email'] ?? ''}'),
                                      Text(snapshot.data!.docs[index]['city']),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    } else {
                      return const Center(child: CircularProgressIndicator());
                    }
                  })),
            ),
          ),
        )
      ],
    ));
  }
}
