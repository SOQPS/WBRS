import '../lib/core/utils/temperament.dart';
import '../lib/core/utils/account_destination.dart';

void main() {
  var checks = 0;
  void expectEqual(Object? actual, Object? expected, String scenario) {
    if (actual != expected)
      throw StateError('$scenario: expected $expected, got $actual');
    checks++;
  }

  void expectInvalid(List<int> scores) {
    try {
      classifyTemperament(scores);
    } on ArgumentError {
      checks++;
      return;
    }
    throw StateError('Invalid scores accepted: $scores');
  }

  final groups = <List<int>, String>{
    [20, 0, 0, 0]: 'коричневая',
    [0, 20, 0, 0]: 'красная',
    [0, 0, 20, 0]: 'синяя',
    [0, 0, 0, 20]: 'белая',
    [15, 5, 0, 0]: 'коричнево-красная',
    [15, 0, 5, 0]: 'коричнево-синяя',
    [15, 0, 0, 5]: 'коричнево-белая',
    [5, 15, 0, 0]: 'красно-коричневая',
    [0, 15, 5, 0]: 'красно-синяя',
    [0, 15, 0, 5]: 'красно-белая',
    [5, 0, 15, 0]: 'сине-коричневая',
    [0, 5, 15, 0]: 'сине-красная',
    [0, 0, 15, 5]: 'сине-белая',
    [5, 0, 0, 15]: 'бело-коричневая',
    [0, 5, 0, 15]: 'бело-красная',
    [0, 0, 5, 15]: 'бело-синяя',
  };
  for (final example in groups.entries) {
    expectEqual(
      classifyTemperament(example.key),
      example.value,
      'Group ${example.key}',
    );
  }
  expectEqual(
    classifyTemperament([10, 10, 0, 0]),
    'красная',
    'Legacy tie handling',
  );
  expectEqual(
    classifyTemperament([5, 5, 5, 5]),
    'белая',
    'Legacy four-way tie',
  );
  expectInvalid([19, 0, 0, 0]);
  expectInvalid([21, 0, 0, 0]);
  expectInvalid([-1, 20, 1, 0]);
  expectInvalid([20, 0, 0]);
  expectEqual(
    accountDestination(null),
    AccountDestination.registration,
    'Interrupted registration must survive',
  );
  expectEqual(
    accountDestination({}),
    AccountDestination.registration,
    'Partial profile must resume questionnaire',
  );
  expectEqual(
    accountDestination({'isRegistrationEnd': false, 'группа': 'белая'}),
    AccountDestination.search,
    'Valid legacy result survives an obsolete incomplete flag',
  );
  expectEqual(
    accountDestination({'isRegistrationEnd': true}),
    AccountDestination.search,
    'Completed registration cold start',
  );
  expectEqual(
    accountDestination({'группа': 'белая'}),
    AccountDestination.search,
    'Legacy account compatibility',
  );
  expectEqual(
    accountDestination({'status': 'blocked', 'isRegistrationEnd': true}),
    AccountDestination.blocked,
    'Blocked account',
  );
  expectEqual(
    accountDestination({'status': 'deleted', 'isRegistrationEnd': true}),
    AccountDestination.deleted,
    'Deleted account',
  );
  print('PASS: $checks core regression scenarios');
}
