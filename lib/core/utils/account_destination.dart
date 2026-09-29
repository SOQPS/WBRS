import 'compatibility.dart';

enum AccountDestination { registration, test, search, blocked, deleted }

/// Legacy clients could persist the test result without updating the old flag.
/// Only one of the sixteen actual groups is evidence of a completed test.
String? savedAccountGroup(Map<String, dynamic> profile) {
  final value = profile['группа']?.toString().trim().toLowerCase() ?? '';
  return getListOfGroup(value).isNotEmpty ? value : null;
}

bool hasSavedProfileDetails(Map<String, dynamic> profile) {
  if (profile['profileDetailsSaved'] == true) return true;
  // Older profiles have no marker. Do not impose today's photo/country rules
  // on an already saved legacy account, but don't send an empty document to a test.
  return (profile['fullName']?.toString().trim().isNotEmpty ?? false) &&
      (profile['age'] is num || int.tryParse('${profile['age']}') != null) &&
      (profile['pol']?.toString().isNotEmpty ?? false) &&
      (profile['about']?.toString().isNotEmpty ?? false) &&
      (profile['hobbi']?.toString().isNotEmpty ?? false);
}

AccountDestination accountDestination(Map<String, dynamic>? profile) {
  if (profile == null) return AccountDestination.registration;
  if (profile['status'] == 'blocked') return AccountDestination.blocked;
  if (profile['status'] == 'deleted') return AccountDestination.deleted;
  if (profile['isRegistrationEnd'] == true ||
      savedAccountGroup(profile) != null) {
    return AccountDestination.search;
  }
  return hasSavedProfileDetails(profile)
      ? AccountDestination.test
      : AccountDestination.registration;
}
