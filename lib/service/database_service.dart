import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:wbrs/core/utils/account_destination.dart';
import 'package:wbrs/service/app_backend.dart';
import 'package:wbrs/service/session_service.dart';

import '../app/helper/global.dart';
import '../shared/geo_catalog.dart';
import '../app/helper/helper_function.dart';

class DatabaseService {
  final String? uid;
  DatabaseService({this.uid});

  // reference for our collections
  final CollectionReference userCollection = firebaseFirestore.collection(
    'users',
  );
  final CollectionReference chatCollection = firebaseFirestore.collection(
    'chats',
  );
  final CollectionReference groupCollection = firebaseFirestore.collection(
    'meets',
  );

  /// Lets an existing owner confirm a catalog location without rewriting the
  /// historical questionnaire or inferring a region from its old city field.
  Future<void> updateUserLocation({
    required GeoCountry country,
    required String region,
  }) async {
    final owner = uid ?? firebaseAuth.currentUser?.uid;
    final ready = SessionService.readyUserId;
    final wasReady = ready.value == owner && owner != null;
    var sessionInvalidated = false;
    void readyChanged() {
      if (wasReady && ready.value != owner) sessionInvalidated = true;
    }

    bool current() =>
        !sessionInvalidated &&
        owner != null &&
        firebaseAuth.currentUser?.uid == owner;
    ready.addListener(readyChanged);
    try {
      if (!current()) throw StateError('Сеанс завершён');
      final countries = await GeoCatalog.load();
      if (!current()) throw StateError('Сеанс завершён');
      final selected = GeoCatalog.byCode(countries, country.code);
      if (selected == null || !selected.regions.contains(region)) {
        throw ArgumentError('Выберите страну и регион из списка');
      }
      final profile = userCollection.doc(owner);
      await firebaseFirestore.runTransaction((transaction) async {
        if (!current()) throw StateError('Сеанс завершён');
        final snapshot = await transaction.get(profile);
        if (!current()) throw StateError('Сеанс завершён');
        if (!snapshot.exists) throw StateError('Профиль недоступен');
        final data = Map<String, dynamic>.from(snapshot.data() as Map);
        if (data['status'] == 'blocked' ||
            data['status'] == 'deleted' ||
            data['deleted'] == true ||
            (data['uid'] != null && data['uid'] != owner)) {
          throw StateError('Профиль недоступен');
        }
        transaction.update(profile, {
          'country': selected.name,
          'countryCode': selected.code,
          'languageGroup': selected.languageGroup,
          'countrySegment': selected.segment,
          'region': region,
          'city': region, // Existing clients still display this legacy alias.
        });
      });
      if (!current()) throw StateError('Сеанс завершён');
    } finally {
      ready.removeListener(readyChanged);
    }
  }

  Future<void> savingUserDataAfterRegister({
    required String fullName,
    required String email,
    required String profilePic,
    String? profilePicThumb,
    required int age,
    required String rost,
    required String country,
    required String countryCode,
    required String region,
    required bool deti,
    required String hobbi,
    required String about,
    required String pol,
    String relationStatus = 'свободен',
    required List<String> profileImages,
    List<String?>? profileImageThumbs,
  }) async {
    final photoUrls = profileImages;
    try {
      final user = firebaseAuth.currentUser!;
      final countries = await GeoCatalog.load();
      final geo = GeoCatalog.byCode(countries, countryCode);
      if (geo == null || !geo.regions.contains(region))
        throw ArgumentError('Выберите страну и регион из списка');
      if (firebaseAuth.currentUser?.uid != user.uid)
        throw StateError('Сеанс завершён');
      final profileRef = userCollection.doc(user.uid);
      final imageRefs = [
        for (var i = 0; i < photoUrls.length; i++)
          profileRef.collection('images').doc('registration_$i'),
      ];
      await firebaseFirestore.runTransaction((transaction) async {
        final existing = await transaction.get(profileRef);
        if (firebaseAuth.currentUser?.uid != user.uid)
          throw StateError('Сеанс завершён');
        if (existing.exists) {
          final data = Map<String, dynamic>.from(existing.data() as Map);
          final destination = accountDestination(data);
          if (destination == AccountDestination.blocked ||
              destination == AccountDestination.deleted) {
            throw StateError('Профиль недоступен. Обратитесь в поддержку.');
          }
          // A retry never replaces a saved profile, result, roles or balance.
          if (destination != AccountDestination.registration) return;
          transaction.update(profileRef, {
            'fullName': fullName,
            'profilePic': profilePic,
            if (profilePicThumb != null) 'profilePicThumb': profilePicThumb,
            'uid': user.uid,
            'age': age,
            'rost': rost,
            'about': about,
            'hobbi': hobbi,
            'deti': deti,
            'city': region,
            'country': country,
            'countryCode': countryCode,
            'languageGroup': geo.languageGroup,
            'countrySegment': geo.segment,
            'region': region,
            'pol': pol,
            'relationStatus': relationStatus,
            'profileDetailsSaved': true,
          });
        } else {
          transaction.set(profileRef, {
            'fullName': fullName,
            'balance': 27,
            'profilePic': profilePic,
            if (profilePicThumb != null) 'profilePicThumb': profilePicThumb,
            'uid': user.uid,
            'age': age,
            'rost': rost,
            'about': about,
            'hobbi': hobbi,
            'deti': deti,
            'temperament': '',
            'city': region,
            'country': country,
            'countryCode': countryCode,
            'languageGroup': geo.languageGroup,
            'countrySegment': geo.segment,
            'region': region,
            'images': [],
            'pol': pol,
            'relationStatus': relationStatus,
            'группа': '',
            'isUnVisible': false,
            'lastOnlineTS': FieldValue.serverTimestamp(),
            'online': true,
            'status': 'active',
            'isRegistrationEnd': false,
            'registrationNoticePending': true,
            'profileDetailsSaved': true,
          });
        }
        for (var i = 0; i < photoUrls.length; i++) {
          transaction.set(imageRefs[i], {
            'url': photoUrls[i],
            if (profileImageThumbs != null &&
                i < profileImageThumbs.length &&
                profileImageThumbs[i] != null)
              'thumbnailUrl': profileImageThumbs[i],
          });
        }
      });
    } catch (e, stack) {
      if (!AppBackend.useEmulators) {
        try {
          FirebaseCrashlytics.instance
              .recordError(
                e.runtimeType.toString(),
                stack,
                reason:
                    'Ошибка сохранения данных пользователя после регистрации',
              )
              .catchError((_) {});
        } catch (_) {/* Diagnostics must not replace the original error. */}
      }
      rethrow;
    }
  }

  Future<void> updateUserData(
    String fullName,
    String email,
    int age,
    String about,
    String hobbi,
    String city,
    bool deti, {
    GeoCountry? country,
  }) async {
    try {
      await userCollection.doc(firebaseAuth.currentUser!.uid).update({
        'fullName': fullName,
        'age': age,
        'about': about,
        'hobbi': hobbi,
        'city': city,
        'region': city,
        if (country != null) ...{
          'country': country.name,
          'countryCode': country.code,
          'languageGroup': country.languageGroup,
          'countrySegment': country.segment,
        },
        'deti': deti,
      });
    } catch (e) {
      FirebaseCrashlytics.instance.recordError(
        e,
        StackTrace.current,
        reason: 'Ошибка обновления данных пользователя',
        information: ['имя: $fullName'],
      );
      rethrow;
    }
  }

  // getting user data
  Future gettingUserData(String email) async {
    QuerySnapshot snapshot =
        await userCollection.where('email', isEqualTo: email).get();
    return snapshot;
  }

  // get user groups
  getUserGroups() async {
    return userCollection.doc(uid).snapshots();
  }

  // getting the chats
  getChats(String chatId) async {
    return chatCollection
        .doc(chatId)
        .collection('messages')
        .orderBy('time')
        .snapshots();
  }

  // search
  searchByName(String userName) {
    return chatCollection.where('users[1]', isEqualTo: userName).get();
  }

  //function -> bool
  Future<bool> isUserJoined(
    String groupName,
    String groupId,
    String userName,
  ) async {
    DocumentReference userDocumentReference = userCollection.doc(uid);
    DocumentSnapshot documentSnapshot = await userDocumentReference.get();

    List<dynamic> groups = await documentSnapshot['groups'];
    if (groups.contains('${groupId}_$groupName')) {
      return true;
    } else {
      return false;
    }
  }

  // toggling the group join/exit
  Future toggleGroupJoin(
    String groupId,
    String userName,
    String groupName,
  ) async {
    // doc reference
    DocumentReference userDocumentReference = userCollection.doc(uid);
    DocumentReference groupDocumentReference = groupCollection.doc(groupId);

    DocumentSnapshot documentSnapshot = await userDocumentReference.get();
    List<dynamic> groups = await documentSnapshot['groups'];

    // if user has our groups -> then remove then or also in other part re join
    if (groups.contains('${groupId}_$groupName')) {
      await userDocumentReference.update({
        'groups': FieldValue.arrayRemove(['${groupId}_$groupName']),
      });
      await groupDocumentReference.update({
        'members': FieldValue.arrayRemove(['${uid}_$userName']),
      });
    } else {
      await userDocumentReference.update({
        'groups': FieldValue.arrayUnion(['${groupId}_$groupName']),
      });
      await groupDocumentReference.update({
        'members': FieldValue.arrayUnion(['${uid}_$userName']),
      });
    }
  }

  // send message
  sendMessage(String chatId, Map<String, dynamic> chatMessageData) async {
    chatCollection.doc(chatId).collection('messages').add(chatMessageData);
    chatCollection.doc(chatId).update({
      'recentMessage': chatMessageData['message'],
      'recentMessageSender': chatMessageData['sender'],
      'recentMessageTime': chatMessageData['time'].toString(),
    });
  }

  sendMessageGroup(String chatId, Map<String, dynamic> chatMessageData) async {
    await groupCollection
        .doc(chatId)
        .collection('messages')
        .add(chatMessageData);
    await groupCollection.doc(chatId).update({
      'recentMessage': chatMessageData['message'],
      'recentMessageSender': chatMessageData['name'],
      'recentMessageTime': chatMessageData['time'].toString(),
    });
  }

  Future<Stream<QuerySnapshot>> getUserByUserName(String username) async {
    return firebaseFirestore
        .collection('users')
        .where('username', isEqualTo: username)
        .snapshots();
  }

  createChatRoom(
    String chatRoomId,
    Map<String, dynamic> chatRoomInfoMap,
  ) async {
    final snapShot =
        await firebaseFirestore.collection('chats').doc(chatRoomId).get();

    if (snapShot.exists) {
      // chatroom already exists
      return true;
    } else {
      // chatroom does not exists
      return firebaseFirestore
          .collection('chats')
          .doc(chatRoomId)
          .set(chatRoomInfoMap);
    }
  }

  Future<QuerySnapshot> getUserInfo(String username) async {
    return await firebaseFirestore
        .collection('users')
        .where('username', isEqualTo: username)
        .get();
  }

  getChatRoomIdByUserID(String a, String b) {
    if (a.isNotEmpty && b.isNotEmpty) {
      if (a.substring(0, 1).codeUnitAt(0) <= b.substring(0, 1).codeUnitAt(0)) {
        return '$a\_$b';
      } else {
        return '$b\_$a';
      }
    } else {
      return 'abrakadabra';
    }
  }

  Future<Stream<QuerySnapshot>> getChatRoomMessages(chatRoomId) async {
    return firebaseFirestore
        .collection('chats')
        .doc(chatRoomId)
        .collection('chats')
        .orderBy('ts', descending: true)
        .limit(60)
        .snapshots();
  }

  Future<Stream<QuerySnapshot>> getGroupMessages(chatRoomId) async {
    return firebaseFirestore
        .collection('meets')
        .doc(chatRoomId)
        .collection('messages')
        .orderBy('time', descending: true)
        .limit(80)
        .snapshots();
  }

  Future<String> GetChatRoomId(String user1, String user2) async {
    String chatId = '';
    await firebaseFirestore
        .collection('chats')
        .where('chatId', isEqualTo: getChatRoomIdByUserID(user1, user2))
        .get()
        .then((QuerySnapshot snapshot) {
      if (snapshot.docs.isEmpty) {
        chatId = getChatRoomIdByUserID(user2, user1);
      } else {
        chatId = getChatRoomIdByUserID(user1, user2);
      }
    });
    return chatId;
  }

  Future<Stream<QuerySnapshot>> getChatRooms() async {
    String myUsername = HelperFunctions().getUserName().toString();
    return firebaseFirestore
        .collection('chats')
        //.orderBy("lastMessage", descending: true)
        .where('users', arrayContains: myUsername)
        .snapshots();
  }

  Future addMessage(String chatRoomId, String messageId, messageInfoMap) async {
    return firebaseFirestore
        .collection('chats')
        .doc(chatRoomId)
        .collection('chats')
        .doc(messageId)
        .set(messageInfoMap);
  }

  updateLastMessageSend(String chatRoomId, lastMessageInfoMap) {
    return firebaseFirestore
        .collection('chats')
        .doc(chatRoomId)
        .update(lastMessageInfoMap);
  }

  updateUnreadMessageCount(String chatRoomId) async {
    DocumentSnapshot count =
        await firebaseFirestore.collection('chats').doc(chatRoomId).get();
    int kolvo = count.get('unreadMessage') + 1;

    firebaseFirestore.collection('chats').doc(chatRoomId).update({
      'unreadMessage': kolvo,
    });
  }

  Future addChat(String uid, String chatId) {
    return firebaseFirestore.collection('users').doc(uid).update({
      'chats': FieldValue.arrayUnion([chatId]),
    });
  }

  Future addChatSecondUser(String uid, String chatId) {
    return firebaseFirestore.collection('users').doc(uid).update({
      'chats': FieldValue.arrayUnion([chatId]),
    });
  }
}
