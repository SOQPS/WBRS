# Standalone native Timeweb Auth client — 2026-10-01

Подготовлены `lib/service/timeweb_auth_client.dart` и адресные тесты. Клиент **не подключён** к `AuthService`, `AppBackend`, экранам или production configuration; текущий APK не переключается на Timeweb. `TimewebAuthConfiguration.enabled` по умолчанию `false`. Этот этап не завершает переезд пользователей и не подтверждает живой вход.

Контракт сервера: [`NATIVE_AUTH.md`](../server/timeweb/python-stand/NATIVE_AUTH.md). Используется уже установленный `package:http`; pubspec, зависимости, Firebase, платежи и основной `.dart_tool` не изменялись.

## Контракт и конфигурация

Caller передаёт публичный HTTPS origin, транспорт при необходимости и реализацию `TimewebSecureTokenStore`. Origin запрещает HTTP, userinfo, query/fragment, literal IP/private local names, нестандартный порт и path prefix. Секретные ключи/реквизиты БД не входят в конфигурацию. Проверка строки origin не заменяет проверку настоящего DNS/TLS/прокси при деплое.

| Метод клиента | HTTP | Значение |
|---|---|---|
| `login(email, password, deviceId)` | `POST /v1/auth/login` | Ровно три поля; пароль сохраняется без trim/нормализации и не кешируется |
| `refresh()` | `POST /v1/auth/refresh` | Refresh token в обязательном JSON поле; один общий Future для параллельных callers |
| `readOwnProfile()` | `GET /v1/me/profile` | Opaque access token только в `Authorization`; UID ответа сверяется с подтверждённой текущей сессией |
| `logout(allSessions: ...)` | `POST /v1/auth/logout` | Access bearer и boolean `allSessions`; немедленный выход из локальной сессии |
| `restore()` | Нет HTTP | Один startup restore из защищённого хранилища |
| `close()` | Нет HTTP | Локальная очистка; это не подтверждённый logout на сервере |

Redirect не следует автоматически. Успешный ответ требует `application/json` и `Cache-Control: no-store`; тело ограничено 16 KiB для Auth и 64 KiB для профиля. Access/refresh остаются opaque, не декодируются для определения UID/expiry. TTL берётся из строгого ответа сервера и отсчитывается консервативно от начала запроса. Пароли, токены, email и raw ответ/низкоуровневая ошибка не включаются в сообщения исключений. Логирование не добавлялось.

Добавлен ограниченный authorized GET transport для шести conversation resources и отдельный default-off клиент, без UI wiring: [`TIMEWEB_CONVERSATION_CLIENT.md`](TIMEWEB_CONVERSATION_CLIENT.md). Он делит тот же refresh/epoch/store guard. `requestDeadline` теперь не больше30 секунд; actual outstanding transfer cap4/stream cancellation и их честные границы описаны там. Новые маршруты не дают arbitrary URI, owner UID или media/write access.

## Защищённое хранилище — обязательный gate

`TimewebSecureTokenStore` — injectable interface `read/write/clear`. Теперь подготовлена отдельная Android реализация на Android Keystore, но она **не подключена и не проверена на устройстве**; точная граница и доказательства — в [`TIMEWEB_ANDROID_TOKEN_STORE.md`](TIMEWEB_ANDROID_TOKEN_STORE.md). Незашифрованные токены/UID не сохраняются в SharedPreferences, файлы или логи; специальный `MODE_PRIVATE` preferences-файл содержит только AES-GCM ciphertext. Пароль не сохраняется. Новая зависимость не устанавливалась. iOS Keychain implementation отсутствует; in-memory store существует только в synthetic тесте.

Один экземпляр клиента владеет очередью операций одного token store. Поздняя старая native запись должна реально закончиться перед последующей очисткой/записью B: `Future.timeout` сам по себе не отменяет запись ОС. Очередь намеренно не выдаёт её за отменённую. `requestDeadline` ограничивает **сетевой обмен целиком**, включая получение headers и тела; он не ограничивает вызовы OS store. Provider должен иметь проверенный ограниченный срок завершения/обработку отказа. Если provider зависнет, завершение `login/logout/close` может ждать его; это остаётся gate интеграции, а не скрытая гарантия общего 10-секундного срока.

Нельзя одновременно использовать два клиента с одним store. Для замены экземпляра нужно дождаться **`await old.close() == true`**: параллельные `close()` получают один и тот же Future до фактического завершения clear. `false` означает, что очистка не подтверждена; новый экземпляр/restore запускать нельзя до исправления provider и подтверждённого удаления сохранённых токенов. Токены старого аккаунта после ошибки clear не считаются безопасно удалёнными, особенно через перезапуск процесса.

## Смена аккаунта и неизвестный исход

- Login/logout/close меняют session epoch. Поздний login/profile/refresh или ошибка A после logout/входа B не могут вернуть данные A или перезаписать токены B.
- `restore()` разделяет один startup Future. После логической смены сессии он использует текущую память, не перечитывает старые токены с диска. После неудачной очистки разрешена только попытка clear, не скрытый возврат A.
- У профиля нет кеша значения. Два expired/401 запроса делят один refresh; поздний 401 старого access token использует уже обновлённый bearer, не запускает вторую rotation.
- Timeout, потеря сети, 503, redirect или некорректный успешный ответ начатого Auth POST считаются `TimewebUnknownOutcome`. Начатая серверная транзакция могла завершиться. Автоматического повторения нет.
- Неизвестный refresh удаляет локальную сессию и требует нового login. Повтор старого refresh на текущем сервере является replay и может отозвать другие сессии устройства.
- После неизвестного login сессия не выставляется и поздний ответ не сохраняется. Может остаться серверная сессия без полученного клиентом токена; она не объявляется отменённой. Новый вход — отдельное явное действие с учётом server rate limit.
- Logout всегда очищает локальную память и пытается очистить protected store в `finally`, в том числе для `allSessions`. `secureTokensCleared` сообщает реальный результат. Только ответ `loggedOut: true` даёт `remoteConfirmed`; 401 даёт `accessRejected`, потерянный/ошибочный ответ — `remoteUnknown`. При смене аккаунта `superseded` требует игнорировать старый результат в UI.

Сервер не имеет operation/status reconciliation endpoint. Поэтому клиент не делает вид, что потерянный ответ login/refresh/logout был восстановлен; GET с прежним bearer не доказывает удаление всех remote sessions. Нет Firebase fallback, автоматического retry или background refresh scheduler. Immutable password strings могут оставаться в памяти до завершения транспортной операции; гарантированное обнуление памяти не заявляется.

## Проверено

26/26 адресных pure-Dart synthetic тестов прошли на Dart 3.8.1: default-off/HTTPS, strict login body/password whitespace, startup restore race, shared refresh и concurrent 401, A→logout→B поздние success/error и реальные задержки store, неизвестный исход/потерянный ответ без retry/late adoption, current/all logout, ошибки secure clear, UID/oversize profile, close/replacement race, Unicode UID bound/invalid UTF-8. Транспорт искусственный, origin `.example.invalid`, сетевых обращений к пользователям/БД/Firebase нет.

Первичный двухфайловый `dart analyze` завершился `No issues found!`. После добавления GET adapter снова прошли26 Auth regression tests вместе с32 conversation tests (58/58) и адресный анализ3 файлов — доказательства текущего source в [`TIMEWEB_CONVERSATION_CLIENT.md`](TIMEWEB_CONVERSATION_CLIENT.md). Использовались байт-в-байт копии в `/tmp/clrs-native-auth-client-tests-20261001` и существующий SDK package config, без pub get; размер fixture/cache после текущего прогона — 2,768 KiB. Главный `.dart_tool` не создавался; APK/AVD/build не запускались.

```sh
# cwd: /tmp/clrs-native-auth-client-tests-20261001
DART=/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/toolchains/flutter-3.32.5/bin/cache/dart-sdk/bin/dart
"$DART" --packages=.dart_tool/package_config.json \
  /Users/anaakovleva/.pub-cache/hosted/pub.dev/test-1.25.15/bin/test.dart \
  --concurrency=1 --reporter expanded test/timeweb_auth_client_test.dart
"$DART" analyze lib/service/timeweb_auth_client.dart test/timeweb_auth_client_test.dart
```

SHA-256 проверенного source:

| Файл | SHA-256 |
|---|---|
| `lib/service/timeweb_auth_client.dart` | `03afbcefb4f3e0aad31c3c0856e8348783f7b2998e22e0fd8263e78215c67906` |
| `test/timeweb_auth_client_test.dart` | `19da1bf26c1e5e7c244a148b1c328b7908b75e08fb211de2bbaf476cb3969f3b` |

Независимое узкое чтение `db_migration_preflight` подтвердило fixes concurrent close и Unicode UID, а также epoch/store/shared-refresh/unknown-outcome участки. Это не live backend или native OS storage proof.

## До включения в APK

Нужны проверенные импортированные credentials/profile rows, отдельная ограниченная native runtime role, задеплоенные routes/публичный HTTPS и controlled old-password login/refresh/logout/blocked-account proof. Затем — runtime proof подготовленного Android OS store и provider deadline, wiring текущих session/UI flows с обработкой unknown/superseded, адресный A/B native device прогон и новый APK. Signup/reset/change-password/social/email-verification и прочие домены полного переезда не реализованы этим адаптером. Production defaults остаются прежними.
