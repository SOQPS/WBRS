import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/core/utils/account_destination.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/app/helper/helper_function.dart';
import 'package:wbrs/service/content_translation_service.dart';

/// Clear only account state; retain unrelated application preferences.
class SessionService {
  static final readyUserId = ValueNotifier<String?>(null);
  static Future<void> clearLocal() async {
    // Delivered notifications can remain in Android's shade after logout and
    // disclose the previous account's message to the next person using it.
    try {
      await FlutterLocalNotificationsPlugin().cancelAll();
    } catch (_) {
      // The native plugin is unavailable in pure-Dart tests and on web.
    }
    // Do not retain decoded portraits across account changes.
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {
      // A pure-Dart session test has no image cache to clear.
    }
    ContentTranslationService.instance.clear();
    readyUserId.value = null;
    globalAbout = null;
    globalAge = '';
    globalPol = null;
    globalCity = null;
    globalRost = null;
    globalHobbi = null;
    globalBalance = 0;
    globalDeti = false;
    group = '';
    brownGroup = whiteGroup = redGroup = blueGroup = 0;
    testIsComlpete = false;
    countImages = 0;
    images.clear();
    usersFromStream.clear();
    lastUpdate = DateTime(2000);
    selectedIndex = 1;
    filtrPol = '';
    ageStart = 18;
    ageEnd = 100;
    filterCity.clear();
    filterCountry.clear();
    filterRegion.clear();
    meetCity = '';
    meetCountry = '';
    meetRegion = '';
    filterByGroup = false;
    imageStream = true;
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      HelperFunctions.userIdKey,
      HelperFunctions.photoUrl,
      HelperFunctions.userLoggedInKey,
      HelperFunctions.userNameKey,
      HelperFunctions.userEmailKey,
      HelperFunctions.displayNameKey,
      HelperFunctions.userProfilePicKey,
      'password',
    ]) {
      await prefs.remove(key);
    }
  }

  static void hydrate(Map<String, dynamic> data) {
    globalAbout = data['about']?.toString();
    globalAge = data['age']?.toString() ?? '';
    globalPol = data['pol']?.toString();
    globalCity = data['city']?.toString();
    globalRost = data['rost']?.toString();
    globalHobbi = data['hobbi']?.toString();
    globalBalance = (data['balance'] as num?)?.toInt() ?? 0;
    globalDeti = data['deti'] == true;
    group = savedAccountGroup(data) ?? '';
    testIsComlpete = accountDestination(data) == AccountDestination.search;
  }
}
