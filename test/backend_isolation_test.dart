import 'package:flutter_test/flutter_test.dart';
import 'package:wbrs/service/app_backend.dart';

void main() {
  test('sandbox rejects a live project or an external emulator host', () {
    for (final pair in [
      ('live-project', '10.0.2.2'),
      ('demo-clrs-local', 'example.com'),
      ('demo-another-project', '127.0.0.1'),
    ]) {
      expect(
        () => AppBackend.validateConfiguration(
          emulatorMode: true,
          projectId: pair.$1,
          host: pair.$2,
        ),
        throwsStateError,
      );
    }
    AppBackend.validateConfiguration(
      emulatorMode: true,
      projectId: 'demo-clrs-local',
      host: '10.0.2.2',
    );
  });

  test('production refuses an accidentally packaged demo configuration', () {
    expect(
      () => AppBackend.validateConfiguration(
        emulatorMode: false,
        projectId: 'demo-clrs-local',
        host: '10.0.2.2',
      ),
      throwsStateError,
    );
    AppBackend.validateConfiguration(
      emulatorMode: false,
      projectId: 'live-project',
      host: '10.0.2.2',
    );
  });
}
