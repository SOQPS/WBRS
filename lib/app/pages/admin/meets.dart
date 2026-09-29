import 'package:wbrs/shared/translatable_text.dart';
import 'package:wbrs/localization/clrs_localizations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/helper/helper_function.dart';
import 'package:wbrs/app/widgets/widgets.dart';
import 'package:wbrs/service/admin_access.dart';

import '../../widgets/bottom_nav_bar.dart';
import '../../../presentation/screens/list_of_users/show/somebody_profile.dart';
import '../../../presentation/screens/meet_chat_screen/chat_page.dart';
import '../filter_pages/cities.dart';

class Meets extends StatefulWidget {
  const Meets({super.key});

  @override
  State<Meets> createState() => _MeetsState();
}

class _MeetsState extends State<Meets> {
  TextEditingController search = TextEditingController(text: '');
  CollectionReference meets = firebaseFirestore.collection('meets');
  Stream _meetsStream = Stream.empty();
  bool _search = false;

  @override
  Widget build(BuildContext context) {
    showConfirmMessage(Function callback, String action) {
      showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: Text(
                context.tr('Удалить встречу?'),
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
            ),
            bottomNavigationBar: const MyBottomNavigationBar(),
            body: SingleChildScrollView(
              child: Column(
                children: [
                  SizedBox(
                    width: MediaQuery.of(context).size.width,
                    height: 50,
                    child: TextField(
                      controller: search,
                      onEditingComplete: () {
                        setState(() {
                          _meetsStream = meets
                              .where('name',
                                  isGreaterThanOrEqualTo: search.text)
                              .snapshots();
                          _search = true;
                        });
                      },
                      decoration: InputDecoration(
                          hintText: context.tr('Начните поиск')),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.7,
                    ),
                    child: StreamBuilder(
                        stream: _search
                            ? _meetsStream
                            : meets
                                .orderBy('timeStamp', descending: true)
                                .snapshots(),
                        builder: (context, snapshot) {
                          if (snapshot.hasData) {
                            return ListView.builder(
                              itemCount: snapshot.data!.docs.length,
                              itemBuilder: (context, index) {
                                return GestureDetector(
                                  onTap: () {
                                    nextScreen(
                                        context,
                                        EditMeet(
                                            description: snapshot.data!
                                                .docs[index]['description'],
                                            city: snapshot.data!.docs[index]
                                                ['city'],
                                            datetime: snapshot.data!.docs[index]
                                                ['datetime'],
                                            users: snapshot.data!.docs[index]
                                                ['users'],
                                            id: snapshot.data!.docs[index].id));
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(15),
                                    margin: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(
                                      color: grey,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: MediaQuery.of(context)
                                                  .size
                                                  .width /
                                              1.5,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceEvenly,
                                            children: [
                                              TranslatableText(
                                                  snapshot.data!.docs[index]
                                                      ['name'],
                                                  showAction: false),
                                              TranslatableText(
                                                  snapshot.data!.docs[index]
                                                      ['description'],
                                                  showAction: false),
                                              Text(snapshot.data!.docs[index]
                                                  ['datetime']),
                                              Text(snapshot.data!.docs[index]
                                                  ['city']),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: () {
                                            showConfirmMessage(() {
                                              firebaseFirestore
                                                  .collection('meets')
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
                                  ),
                                );
                              },
                            );
                          } else {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                        }),
                  ),
                ],
              ),
            ),
          ),
        )
      ],
    ));
  }
}

class EditMeet extends StatelessWidget {
  final String description;
  final String city;
  final String datetime;
  final String id;
  final List users;
  const EditMeet(
      {super.key,
      required this.description,
      required this.city,
      required this.datetime,
      required this.users,
      required this.id});

  @override
  Widget build(BuildContext context) {
    TextEditingController descEdit = TextEditingController();
    TextEditingController cityEdit = TextEditingController();
    TextEditingController dateAndTimeEdit = TextEditingController();
    descEdit.text = description;
    cityEdit.text = city;
    dateAndTimeEdit.text = datetime;
    return Stack(
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
            resizeToAvoidBottomInset: true,
            backgroundColor: Colors.transparent,
            appBar: AppBar(),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextField(
                    controller: descEdit,
                  ),
                  TextField(
                    controller: dateAndTimeEdit,
                  ),
                  SizedBox(
                    width: MediaQuery.of(context).size.width,
                    child: Autocomplete<String>(
                      optionsMaxHeight:
                          MediaQuery.of(context).size.height * 0.2,
                      optionsViewBuilder: (context, onSelected, options) {
                        return cityDropdown(context, options, onSelected);
                      },
                      initialValue: TextEditingValue(text: cityEdit.text),
                      optionsBuilder: (textEditingValue) {
                        if (textEditingValue.text == '') {
                          return [];
                        }
                        return cities
                            .where((city) => city.toLowerCase().startsWith(
                                textEditingValue.text.toLowerCase()))
                            .toList()
                          ..sort((a, b) => a.compareTo(b));
                      },
                      onSelected: (String val) {
                        cityEdit.text = val;
                      },
                      fieldViewBuilder:
                          (context, controller, focusNode, onSubmitted) {
                        return TextField(
                          controller: controller,
                          style: const TextStyle(color: Colors.white),
                          focusNode: focusNode,
                          decoration: InputDecoration(
                            alignLabelWithHint: false,
                            border: InputBorder.none,
                            hintText: context.tr('Введите ваш город'),
                            hintStyle: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w400,
                                fontSize: 14),
                          ),
                          onSubmitted: (String value) {
                            onSubmitted();
                          },
                          onChanged: (value) {
                            cityEdit.text = value;
                          },
                        );
                      },
                    ),
                  ),
                  StreamBuilder(
                      stream: firebaseFirestore
                          .collection('meets')
                          .doc(id)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          List usersUpdated = snapshot.data!.get('users');
                          if (usersUpdated.length != users.length) {
                            return GestureDetector(
                              onTap: () {
                                nextScreen(context,
                                    UsersEdit(id: id, users: usersUpdated));
                              },
                              child: Container(
                                  padding: const EdgeInsets.all(10),
                                  margin: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: grey,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(context
                                      .tr('Участников: {count}', args: {
                                    'count':
                                        context.l10n.number(usersUpdated.length)
                                  }))),
                            );
                          }
                        }
                        return GestureDetector(
                          onTap: () {
                            nextScreen(
                                context, UsersEdit(id: id, users: users));
                          },
                          child: Container(
                              padding: const EdgeInsets.all(10),
                              margin: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                color: grey,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(context.tr('Участников: {count}',
                                  args: {
                                    'count': context.l10n.number(users.length)
                                  }))),
                        );
                      }),
                  ElevatedButton(
                    onPressed: () {
                      firebaseFirestore.collection('meets').doc(id).update({
                        'description': descEdit.text,
                        'city': cityEdit.text,
                        'datetime': dateAndTimeEdit.text
                      });
                      Navigator.pop(context);
                    },
                    child: Text(context.tr('Сохранить')),
                  )
                ],
              ),
            ),
            bottomNavigationBar: const MyBottomNavigationBar(),
          ),
        ),
      ],
    );
  }
}

class UsersEdit extends StatefulWidget {
  final String id;
  final List users;
  const UsersEdit({super.key, required this.id, required this.users});

  @override
  State<UsersEdit> createState() => _UsersEditState();
}

class _UsersEditState extends State<UsersEdit> {
  List userInfo = [];

  Future<void> getUsers() async {
    for (int i = 0; i < widget.users.length; i++) {
      var user = await firebaseFirestore
          .collection('users')
          .doc(widget.users[i])
          .get();
      if (user.data() == null) continue;
      userInfo.add(UserInfo(
        user['fullName'],
        user['age'].toString(),
        user['city'],
        user['profilePic'],
        user['группа'],
        user['uid'],
        user.data() as Map,
      ));
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    getUsers();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
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
            appBar: AppBar(),
            body: Container(
              height: MediaQuery.of(context).size.height,
              width: MediaQuery.of(context).size.width,
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  SizedBox(
                      height: MediaQuery.of(context).size.height * 0.7,
                      width: MediaQuery.of(context).size.width,
                      child: listUsers()),
                  TextButton(
                      onPressed: () {
                        TextEditingController search = TextEditingController();
                        showModalBottomSheet(
                            context: context,
                            backgroundColor: grey,
                            builder: (context) {
                              return Theme(
                                data: ThemeData(brightness: Brightness.dark),
                                child: Scaffold(
                                  backgroundColor: Colors.transparent,
                                  body: Container(
                                    height: 500,
                                    width: MediaQuery.of(context).size.width,
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      children: [
                                        TextField(
                                          controller: search,
                                        ),
                                        SizedBox(
                                          height: 350,
                                          width:
                                              MediaQuery.of(context).size.width,
                                          child: StreamBuilder(
                                              stream: firebaseFirestore
                                                  .collection('users')
                                                  .where('fullName',
                                                      isGreaterThanOrEqualTo:
                                                          search.text)
                                                  .snapshots(),
                                              builder: (context, snapshot) {
                                                if (snapshot.connectionState ==
                                                    ConnectionState.waiting) {
                                                  return const Center(
                                                      child:
                                                          CircularProgressIndicator());
                                                } else {
                                                  return ListView.builder(
                                                      itemCount: snapshot
                                                          .data!.docs.length,
                                                      itemBuilder:
                                                          (context, index) {
                                                        return ListTile(
                                                          title: Text(snapshot
                                                                  .data!
                                                                  .docs[index]
                                                              ['fullName']),
                                                          onTap: () async {
                                                            if (widget.users
                                                                .contains(snapshot
                                                                    .data!
                                                                    .docs[index]
                                                                    .id)) {
                                                              return showSnackbar(
                                                                context,
                                                                Colors.red,
                                                                context.tr(
                                                                    'Пользователь уже добавлен'),
                                                              );
                                                            }
                                                            await firebaseFirestore
                                                                .collection(
                                                                    'meets')
                                                                .doc(widget.id)
                                                                .update({
                                                              'users': FieldValue
                                                                  .arrayUnion([
                                                                snapshot
                                                                    .data!
                                                                    .docs[index]
                                                                    .id
                                                              ])
                                                            });
                                                            userInfo.clear();
                                                            getUsers();
                                                            if (context
                                                                .mounted) {
                                                              Navigator.of(
                                                                      context)
                                                                  .pop();
                                                            }
                                                          },
                                                          trailing: Text(
                                                            snapshot.data!
                                                                    .docs[index]
                                                                ['city'],
                                                            style: TextStyle(
                                                                fontSize: 14),
                                                          ),
                                                          leading: SizedBox(
                                                            width: 50,
                                                            height: 50,
                                                            child: SizedBox(
                                                                width: 50,
                                                                height: 50,
                                                                child: ClipRRect(
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                            200),
                                                                    child: userImageWithCircle(
                                                                        snapshot.data!.docs[index]
                                                                            [
                                                                            'profilePic'],
                                                                        snapshot
                                                                            .data!
                                                                            .docs[index]['группа'],
                                                                        60.0,
                                                                        60.0))),
                                                          ),
                                                          dense: false,
                                                        );
                                                      });
                                                }
                                              }),
                                        )
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            });
                        setState(() {});
                      },
                      child: Text(
                        context.tr('Добавить пользователей'),
                        style: TextStyle(color: Colors.green),
                      ))
                ],
              ),
            ),
            bottomNavigationBar: const MyBottomNavigationBar(),
          ))
    ]);
  }

  Widget listUsers() {
    List users = userInfo;
    return StreamBuilder(
        stream:
            firebaseFirestore.collection('meets').doc(widget.id).snapshots(),
        builder: (context, snapshot) {
          return ListView.builder(
              itemCount: users.length,
              itemBuilder: (context, index) {
                return ListTile(
                  textColor: Colors.white,
                  onTap: () async {
                    UserInfo user = userInfo[index];
                    nextScreen(
                        context,
                        SomebodyProfile(
                            uid: user.uid,
                            photoUrl: user.imageUrl,
                            name: user.name,
                            userInfo: user.userInfo));
                  },
                  trailing: IconButton(
                      onPressed: () async {
                        showDialog(
                            barrierDismissible: false,
                            context: context,
                            builder: (context) {
                              return AlertDialog(
                                backgroundColor: darkGrey,
                                elevation: 0.0,
                                titleTextStyle:
                                    const TextStyle(color: Colors.white),
                                contentTextStyle:
                                    const TextStyle(color: Colors.white),
                                content: Text(context.tr(
                                    'Вы уверены, что хотите исключить этого пользователя?')),
                                actions: [
                                  TextButton(
                                    onPressed: () {
                                      Navigator.pop(context);
                                    },
                                    child: Text(
                                      context.tr('Нет'),
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      Map doc = await firebaseFirestore
                                          .collection('meets')
                                          .doc(widget.id)
                                          .get()
                                          .then((doc) => doc.data() as Map);
                                      List kicked = doc['kicked'] ?? [];
                                      String uid = users[index].uid;
                                      kicked.add(uid);
                                      userInfo.removeWhere(
                                          (element) => element.uid == uid);
                                      users.removeWhere(
                                          (element) => element.uid == uid);
                                      List newUsers = doc['users'];
                                      newUsers.removeWhere(
                                          (element) => element == uid);
                                      firebaseFirestore
                                          .collection('meets')
                                          .doc(widget.id)
                                          .update({
                                        'users': newUsers,
                                        'kicked': kicked
                                      });

                                      if (context.mounted) {
                                        Navigator.pop(context);
                                      }
                                      setState(() {});
                                    },
                                    child: Text(
                                      context.tr('Да'),
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ),
                                ],
                              );
                            });
                      },
                      icon: const Icon(
                        Icons.delete,
                        color: Colors.redAccent,
                      )),
                  title: Text(userInfo[index].name),
                  subtitle: Row(
                    children: [
                      int.parse(userInfo[index].age) % 10 == 0
                          ? Text(context.tr('{count} лет',
                              count:
                                  num.tryParse('${userInfo[index].age}') ?? 0))
                          : int.parse(userInfo[index].age) % 10 == 1
                              ? Text(context.tr('{count} лет',
                                  count:
                                      num.tryParse('${userInfo[index].age}') ??
                                          0))
                              : int.parse(userInfo[index].age) % 10 != 5
                                  ? Text(context.tr('{count} лет',
                                      count: num.tryParse(
                                              '${userInfo[index].age}') ??
                                          0))
                                  : Text(context.tr('{count} лет',
                                      count: num.tryParse(
                                              '${userInfo[index].age}') ??
                                          0)),
                      const SizedBox(
                        width: 10,
                      ),
                      SizedBox(
                        width: 120,
                        child: Text(
                          userInfo[index].city,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    ],
                  ),
                  leading: SizedBox(
                    width: 50,
                    height: 50,
                    child: SizedBox(
                        width: 50,
                        height: 50,
                        child: ClipRRect(
                            borderRadius: BorderRadius.circular(200),
                            child: userImageWithCircle(userInfo[index].imageUrl,
                                userInfo[index].group, false, 60.0, 60.0))),
                  ),
                  dense: false,
                );
              });
        });
  }
}
