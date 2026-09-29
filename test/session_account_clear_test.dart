import 'package:flutter_test/flutter_test.dart' hide group;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wbrs/app/helper/global.dart';
import 'package:wbrs/service/session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Account cleanup removes profile, location filters and saved identity',
      () async {
    SharedPreferences.setMockInitialValues({
      'USERKEY': 'old-user',
      'USEREMAILKEY': 'old@example.test',
      'remember_me': true,
    });
    globalAbout = 'Old biography';
    group = 'красная';
    filterCountry.text = 'Россия';
    filterRegion.text = 'Москва';
    meetCountry = 'Россия';
    meetRegion = 'Москва';

    await SessionService.clearLocal();

    final prefs = await SharedPreferences.getInstance();
    expect(globalAbout, isNull);
    expect(group, isEmpty);
    expect(filterCountry.text, isEmpty);
    expect(filterRegion.text, isEmpty);
    expect(meetCountry, isEmpty);
    expect(meetRegion, isEmpty);
    expect(prefs.getString('USERKEY'), isNull);
    expect(prefs.getString('USEREMAILKEY'), isNull);
    expect(prefs.getBool('remember_me'), isTrue);
  });
}
