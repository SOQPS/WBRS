# Android protected Timeweb token store — 2026-10-01

Подготовлено настоящее Android OS хранилище для standalone `TimewebAuthClient`: AES-256-GCM с ключом `AndroidKeyStore`, небольшой MethodChannel bridge и Dart protocol guard. Оно **не подключено к AuthService/UI**, native Auth по умолчанию выключен. Изменения не входят в ранее собранный APK 1.0.25-42. Main Flutter APK/production login этим этапом не запускались. Отдельный isolated native instrumentation APK проверен на Android API35 с искусственными данными; точные границы ниже.

## Что сохраняется

Все поля `TimewebSession` — UID, признак email verification, access/refresh tokens и два срока действия — шифруются одним payload до 32 KiB. Пароль в store не передаётся. Специальный `MODE_PRIVATE` файл `timeweb_secure_tokens_v1.xml` содержит только версию envelope, случайный operation UUID, IV и AES-GCM ciphertext. Отдельный dirty journal в `noBackupFilesDir` содержит только случайный UUID; секретов и UID в нём нет. Plaintext preferences/files, shared_preferences plugin и резервная незашифрованная реализация отсутствуют.

Ключ создаётся `KeyGenerator` в AndroidKeyStore: AES-256, GCM, NoPadding, randomized encryption required. IV выдаёт Cipher, длина проверяется; GCM tag 128 bit. AAD связывает ciphertext с версией формата, package name и operation UUID, поэтому production/sandbox envelope не взаимозаменяемы. Ключ не экспортируется. Аппаратная защита/StrongBox и стойкость при компрометации приложения/ОС не заявляются: доступность hardware backing зависит от устройства. См. [Android Keystore](https://developer.android.com/privacy-and-security/keystore) и официальный [AES-GCM пример KeyGenParameterSpec](https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec).

## Выполнение и неизвестный исход

- Native process singleton использует один worker. На main/platform UI thread нет disk/Keystore операций; туда возвращается только результат. Android отдельно рекомендует выполнять Keystore вне main thread. [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- Native CAS допускает только одну операцию; новый запрос при занятом worker получает безопасный отказ, очередь не растёт. Watchdog 5 секунд возвращает `outcome_unknown`, а не притворяется отменой OS IO. Worker остаётся занятым до настоящего завершения старой операции и cleanup. Отменённые watchdog timers удаляются из очереди.
- Dart wrapper имеет один guard на операцию и 7 секунд на каждый MethodChannel вызов. После неизвестного исхода read/write запрещены до подтверждённого `clear`. Поздний Future не запускает confirm и не меняет guard. Две фазы write/confirm имеют отдельные deadlines; это не обещание общего 7- или 10-секундного срока всей login/logout операции.
- `write` сначала fsync/проверяет dirty UUID, затем шифрует и выполняет `SharedPreferences.commit` с readback. Ciphertext остаётся нечитаемым до `confirm` того же operation UUID. Старый/чужой confirm не удаляет данные новой операции. `commit` проверяется как boolean, выполняется только на worker. [SharedPreferences.Editor](https://developer.android.com/reference/android/content/SharedPreferences.Editor)
- Незавершённые journal base/`.bak`/`.new`, повреждённый envelope, неизвестный формат, потерянный ключ, неверные GCM tag/UTF-8/shape не возвращают сессию. Native пытается удалить ciphertext и ключ; если это не подтверждено, остаётся fail-closed dirty/poisoned state. Проверка `.new` и readback после `AtomicFile.finishWrite` добавлены по установленному Android SDK source: `android-37.0/android/util/AtomicFile.java`.
- `clear` сначала сохраняет dirty intent, затем проверяет удаление ciphertext и Keystore alias, только после этого удаляет journal. Ошибка очистки не выдаётся за успешное удаление.

`createAndroidTimewebTokenStore()` возвращает один wrapper на Dart isolate; native singleton общий для процесса. Использовать два действующих AuthClient с одним store нельзя: replacement должен дождаться `await old.close() == true`, затем использовать этот же factory/store. Built-in MethodChannel гарантирует FIFO получения вызовов; это не гарантия успешной записи или доставки ответа. [Flutter MethodChannel](https://api.flutter.dev/flutter/services/MethodChannel-class.html)

Если native confirm уже завершился и удалил journal, но его последний ответ потерялся, Dart объявляет исход неизвестным и требует recovery clear. При гибели процесса в промежутке до clear следующий запуск может прочитать корректный ciphertext последней завершённой native записи. Абсолютное восстановление статуса потерянного final ACK между процессами не заявляется. Нельзя запускать B после неподтверждённого close/clear. Гарантия этого этапа — отсутствие автоматического replay/late adoption в текущем клиенте, блокирование незавершённой записи и подтверждённая очистка перед заменой аккаунта; Проверка этой native границы с искусственными данными выполнена ниже; Flutter AuthClient/UI wiring и live backend этим не подтверждены.

Byte buffers очищаются best-effort. Immutable Dart/Kotlin strings и MethodChannel buffers невозможно обещать обнулить; токены проходят через память приложения. В source нет токенов, ключей, password/UID logging или raw exception details в сообщениях ошибок.

## Backup и перезапуск

Существующее `android:allowBackup="false"` сохранено. Для dedicated ciphertext preferences добавлены явные exclusions в legacy full-backup rules и Android 12+ cloud-backup/device-transfer rules; остальные файлы приложения не переклассифицированы. `noBackupFilesDir` исключён Android из backup автоматически. OEM поведение переноса может различаться, поэтому наличие rules не объявляется доказательством device-transfer теста. [Android Auto Backup](https://developer.android.com/identity/data/autobackup)

После нормальной подтверждённой записи новый store может прочитать сессию с тем же Keystore alias. Не создаётся новый ключ для decrypt, если старый потерян. Dirty restart вместо старых токенов требует очистки/нового входа. Данные других Android пользователей/приложений и multi-process access этим adapter не обслуживаются. iOS Keychain реализация не добавлялась.

## Реальная native проверка — 2026-10-01

Отдельный APK `com.lrs.tokenstoreproof` (Android Debug signature) содержит **неизменённый** `TimewebTokenStore.kt` SHA `2328ed42e1fbcf1a17785ff32e50bd81ba4e326c4aa2b5f015024a215102f9c8`, реальные `MethodCall`/`MethodChannel.Result` классы pinned Flutter embedding и небольшой `Instrumentation`. JNI/engine/UI не запускались. Package/Android UID отдельный, network permission отсутствует; только искусственные сессии. APK собран напрямую установленными Kotlin 2.1.0, API35 `android.jar`, AAPT2/D8 36.0.0, без Gradle/pub get/main `.dart_tool`. [Android Instrumentation](https://developer.android.com/reference/android/app/Instrumentation)

Итоговый APK **2,314,643 bytes**, SHA-256 `dcb315a2137f663d69181b879b881a7ccaa1dfe0bf9e83d7e188caad1151cd1f`. Native harness SHA `54a573d4fdbac3c0472f30336c4a38f3ab74cc4cd2488f911ed0e389c7f1c766`. На dedicated Android API35 ARM64 AVD (RAM 1024 MiB, userdata 1 GiB) **6/6 instrumentation phases, 16 proof assertions PASS**:

| Phase | Проверяемое поведение | Результат |
|---|---|---|
| `seed` | Real AES key существует, `encoded == null`; preferences XML и envelope не содержат synthetic access/refresh/UID plaintext | 1 PASS |
| `restore` | После `am force-stop`/нового process payload точно восстановлен; `clear` удаляет ciphertext, alias и journal | 2 PASS |
| `dirty_seed` | Незавершённый `write` сохраняет dirty intent | 1 PASS |
| `dirty_restore` | После отдельного restart незавершённая запись не возвращает сессию; fail-closed cleanup подтверждён | 1 PASS |
| `adversarial` | Read до confirm блокируется; stale A confirm не удаляет B; GCM tamper, замена AAD UUID, потерянный ключ и `.new` sidecar отвергаются и очищаются; clean empty state восстанавливается | 8 PASS |
| `late_io` | Реальный SharedPreferences `commit` удержан тестовым barrier; watchdog даёт `outcome_unknown`, `clear` остаётся busy до настоящего IO, B запрещён; после settlement+подтверждённого clear B пишется/читается без позднего A cleanup | 3 PASS |

Late IO — точечный fault injection на `SharedPreferences.Editor.commit` через `ContextWrapper`/reflection private constructor, с реальными SharedPreferences и Keystore. Production helper не содержит test hooks и не изменялся. Первоначальный delegated Editor терял wrapper при fluent `putString`; исправлены только test-harness `putString/remove → this`, после чего **все 6 phases повторены на итоговом SHA**. Это не выдаётся за найденную ошибку production helper.

Все evidence/APK/harness/build script/config/final phase results и SHA сохранены вне Git checkout: `/Users/anaakovleva/Documents/Codex/2026-09-21/ds/artifacts/timeweb_20260930/native-tokenstore-proof-20261001/`. Result bundles содержат только phase/proof names/counts, без payload/tokens. `final-phases.json` связывает результаты с точным APK SHA. Основной APK42 повторно хеширован: `2bae972e909bf0b776ebc17842aa099c015993f624d06cbeb458513bee1952f9`, неизменён. Dedicated `emulator-5564` после проверки остановлен.

Проверка **не доказывает** Flutter MethodChannel engine registration/manifest merger/main app lifecycle, end-to-end AuthClient A→logout→B, live HTTPS/backend/credentials, OEM device transfer или hardware/StrongBox backing. Native storage A→clear→B и потерянный final confirm ACK между процессами — разные границы; ранее описанное final-ACK ограничение остаётся. После будущего подключения нужны адресные app runtime проверки и новый APK.

## Доказательства

16/16 новых pure-Dart protocol tests + 26/26 прежних AuthClient lifecycle tests = **42/42 PASS**, Dart 3.8.1. Проверены exact DTO/restart protocol, singleton-operation guard, потерянные write/confirm/clear ответы и поздний A после подтверждённой записи B, malformed ACK, шесть видов corruption, неуспешная очистка/recovery, безопасные сообщения и конечный deadline. Fixture только in-memory: это **не** доказательство Android Keystore/файловой системы.

Адресный `dart analyze` только new core/test: `No issues found!`. Три XML parse checks PASS. Два Kotlin файла (`TimewebTokenStore.kt`, `MainActivity.kt`) скомпилированы напрямую существующим Kotlin 2.1.0 compiler, Android API35 `android.jar`, pinned Flutter release embedding `dd93de6fb1776398bf586cbd477deade1391c7e4` и существующими runtime jars, JVM target 1.8: **exit 0**. Gradle/manifest merger/Flutter bridge runtime/APK этим не проверены.

Независимое адресное чтение `db_migration_preflight` по Kotlin SHA ниже и Dart/MainActivity/XML не выявило нового blocker: `.new` gap закрыт, stale confirm не очищает B, busy сохраняется до фактического IO/cleanup, clear обязателен после unknown. Правило одного active AuthClient действует также при будущем втором engine/isolate: native clear общий, межклиентский lease не реализован.

Тесты используют `/tmp/clrs-native-auth-client-tests-20261001`, существующий package config и pub-cache, без pub get. Размер fixture/cache 2,640 KiB. Прямая компиляция — `/tmp/clrs-token-kotlin-compile-20261001/compile.py` и `compile-result.txt`, 52 KiB. Основной `.dart_tool` не создан; зависимости не установлены.

```sh
# cwd: /tmp/clrs-native-auth-client-tests-20261001
DART=/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/toolchains/flutter-3.32.5/bin/cache/dart-sdk/bin/dart
"$DART" --packages=.dart_tool/package_config.json \
  /Users/anaakovleva/.pub-cache/hosted/pub.dev/test-1.25.15/bin/test.dart \
  --concurrency=1 --reporter expanded \
  test/timeweb_android_secure_token_store_test.dart test/timeweb_auth_client_test.dart
"$DART" analyze lib/service/timeweb_android_secure_token_store.dart \
  test/timeweb_android_secure_token_store_test.dart
python3 /tmp/clrs-token-kotlin-compile-20261001/compile.py
```

SHA-256 проверенного source:

| Файл | SHA-256 |
|---|---|
| `android/app/src/main/kotlin/com/lrs/TimewebTokenStore.kt` | `2328ed42e1fbcf1a17785ff32e50bd81ba4e326c4aa2b5f015024a215102f9c8` |
| `android/app/src/main/kotlin/com/lrs/MainActivity.kt` | `2c51e729b0f1d0e6b51fdac329e1af83e0f4468c4f093d70a6dc4f4b3ab110b5` |
| `android/app/src/main/AndroidManifest.xml` | `c123c30af9007bfacbf107d9125bcdcd3aca049ab98293041961fde334608fa7` |
| `android/app/src/main/res/xml/timeweb_token_backup_rules.xml` | `8f293884c7c3665f27628edec2436ac6f230a9cef10cebe0a5ae921688c2f123` |
| `android/app/src/main/res/xml/timeweb_token_extraction_rules.xml` | `08b0b9af176391065642555297e6b31cadcda2b35c564e9cfbd2efa74b927df8` |
| `lib/service/timeweb_android_secure_token_store.dart` | `11fb2b20361f74794a637103ff93252abf5b9604849c91d2e7e34d2afbbe8316` |
| `lib/service/timeweb_android_secure_channel.dart` | `94b30bf53c56be0d386f46cb3b7be7a27c51f3d651f8efc92ab18a5647b1120a` |
| `test/timeweb_android_secure_token_store_test.dart` | `ac558f8d587944bfcbd6939a0981c403e5b959f1919d00a8ef3b4dbc0e7d4069` |

До включения остаются целевая main Android build/manifest/engine registration check, Flutter AuthClient A→logout→B с обработкой unknown/clear failures, подключение к UI и новый APK. Controlled native restart/ciphertext/tamper/lost-key/dirty/late-IO/storage A→clear→B выполнены выше. Нужен также живой HTTPS native Auth backend с импортированными credentials/profile. Это подготовленная реализация, а не включённый переезд.
