# Standalone Timeweb conversation reads — 2026-10-01

Подготовлен `TimewebConversationClient` и ограниченный authorized GET transport внутри `TimewebAuthClient`. Оба adapter по умолчанию выключены, к UI/AuthService/AppBackend не подключены. Текущий APK 1.0.25-42 не изменён. Live HTTPS, backend flags, импортированный runtime и Android/native session proof этим этапом **не подтверждены**. Это чтение проверенного immutable import snapshot, а не законченный перенос всех возможностей приложения.

## Разрешённый контракт

| Метод | Единственный маршрут GET | Query |
|---|---|---|
| `readChats` | `/v1/chats` | `limit`, optional `cursor` |
| `readChatMessages(id)` | `/v1/chats/{id}/messages` | `limit`, optional `cursor` |
| `readMeetings` | `/v1/meetings` | `limit`, optional `cursor` |
| `readMeeting(id)` | `/v1/meetings/{id}` | Нет |
| `readMeetingMessages(id)` | `/v1/meetings/{id}/messages` | `limit`, optional `cursor`; `own_removed=1` только при явном `ownRemoved:true` |
| `readMeetingParticipants(id)` | `/v1/meetings/{id}/participants` | `limit`, optional `cursor` |

`TimewebConversationReadRequest` — final class с закрытым конструктором и шестью factories; arbitrary URI, HTTP method, body, owner UID и bearer caller не принимает. Origin наследуется из публичной HTTPS-only Auth configuration. IDs непустые, корректный UTF-8 до 1,500 bytes, без slash/NUL/`.`/`..`; URI строится через `pathSegments` и `queryParameters`, не string concatenation/resolve пользовательского path. Размер страницы 1–50. Правила HTTP `own_removed` согласованы с app wire: `1` при true; false в клиенте omitted. Владелец архива никогда не передаётся в query.

Серверные DTO сверены с `legacy_conversation_read.py`, `legacy_conversation_payload.py` и согласованным `LegacyConversationDiscoveryService` (`legacy_conversation_discovery.py`). Успешный ответ требует JSON/no-store. Для всех conversation response максимум **262,144 bytes**, strict UTF-8, object, ограниченная вложенность и immutable JSON. Profile остаётся ограничен 65,536 bytes, Auth — 16,384 bytes. Redirect не выполняется; error body не читается/не раскрывается. Ошибки безопасны и не содержат token, UID, email, path, сырой JSON или connector exception.

## Session и транспорт

GET пользуется тем же `_refreshFlight`, session epoch и защищённым store, что standalone Auth. Перед истёкшим access выполняется один shared refresh. После GET401 можно выполнить один refresh и повторить **этот GET один раз**, только при той же epoch. Если другой caller уже сменил access token, поздний401 использует новый bearer без второй rotation. Второй401 актуального bearer инвалидирует сессию; третьего GET нет. После logout/login B ни результат, ни поздняя ошибка A, ни retry A не становятся ответом B. POST login/refresh/logout по-прежнему не повторяются при неизвестном исходе; новый GET transport не создаёт retry server mutation.

Access token передаётся исключительно в `Authorization`; response/proof/cursor API не раскрывает credentials. `TimewebAuthorizedRead`, `TimewebConversationPage` и `TimewebMeetingDetail` повторно проверяют epoch/current UID при получении body/items/metadata. После B старые getters/cursors A отклоняются. Уже выданные consumer references/строки невозможно стереть из чужой памяти: будущий UI обязан очищать показанные A данные на смене аккаунта. Adapter не устанавливает cache/polling/fallback.

`nextCursor` — opaque `TimewebReadCursor`, final capability, до4,096 base64url chars; значение не декодируется и не выводится `toString()`. Cursor привязан к AuthClient, epoch, resource ID, виду страницы и `ownRemoved`. Его нельзя отправить от B, другого клиента, для другой встречи/чата или текущего root history вместо removed history. При этом сервер сам проверяет свой AEAD cursor/source/membership; клиентская проверка его не заменяет. Пустая видимая страница с nextCursor остаётся продолжением: скрытые сообщения могут продвигать underlying cursor.

`requestDeadline` ограничен 0 < value <=30 секунд, default10. Deadline охватывает headers/body одного transfer, но не secure store или всю цепочку refresh+GET+retry. Response stream при timeout/oversize закрывается. Одновременно допускаются максимум четыре настоящих transport операции. Установленный `http1.3.0` не предоставляет cancellable Request до получения headers: зависший `send` или injected `StreamIterator.cancel` продолжает держать один из четырёх slots до фактического завершения. Поздние headers сразу отменяются, без body/adoption. Caller получает конечный deadline; ложная отмена исходной операции и бесконечное добавление запросов не заявляются. При заполнении четырёх slots новый запрос получает безопасный unavailable; нужно исправить транспорт/закрыть принадлежащий client, без автоматической повторной отправки Auth POST.

## Сохранённые ограничения данных

Декодер возвращает только точный whitelist и сохраняет nullable/unavailable source поля:

- Messages сохраняют timestamp string с девятью дробными цифрами, исходный sender label, text, legacy read flag, gift notice/name, bundled asset, quote и shared-content metadata. Historical sender UID не создаёт identity/member. Quote без исходного ID остаётся `messageId:null`, shared link `false`.
- Chat discovery сохраняет peer/profileState/interactive, preview, last activity/unread count. Deleted/disabled/legacy/missing/unavailable peer не интерактивен. Preview максимум4,096 chars; source отсутствие даты/счётчика не заполняется выдуманным значением.
- Meeting discovery/detail сохраняет local scheduled string и `scheduledTimezone:null`; timezone не угадывается. Organizer и membership проверяются; не создаются приглашения/участники. Оба membership flags false недопустимы для доступного server metadata.
- Participants сохраняют organizer/member и profile states. Missing profile не получает придуманного возраста/аккаунта; deleted/неактивный профиль не становится интерактивным. Сортировка snapshot обозначена явно, это не live online/recent recipient list.
- Media — только bounded bundled/quarantined/unavailable descriptor. `mediaReady:false` и `readReceiptsWritten:false` обязательны там, где предусмотрены серверным envelope. Download, Firebase/S3 URL, подпись/доступ к quarantine, запись read receipts и платежи отсутствуют.

`sourceSnapshot` проверяется как hex64, `membershipAuthority` — ровно `immutable-reviewed-snapshot`. Это не доказательство актуального membership после production join/leave/block: включение write flows требует отдельного current-authority cutover. Wall, gifts/send, payment/admin/media/write routes и прочие домены полного переезда этим adapter не реализованы.

## Проверено

**32/32 новых conversation synthetic tests +26/26 существующих Auth lifecycle regression tests =58/58 PASS** на Dart3.8.1. Проверены все6 exact routes/UTF-8 encoding/header-only bearer/default-off, лимиты IDs/page/body/deadline, strict DTO и источник без fake links/profile values, empty page continuation, cursor resource/client/account/archive binding, late A после B, shared401 refresh/одинretry/second401, stream cancellation, четыре hanging headers с поздним освобождением, GET302/404/429/503 без replay/body leak, corruption/unknown fields/duplicate rows/calendar, отсутствие cache, impossible membership и oversized preview, expired unknown refresh без старого GET. Только искусственный HTTP/store и `.example.invalid`; сетевых обращений к пользователям/БД/Firebase нет.

Адресный analyze только `timeweb_auth_client.dart`, `timeweb_conversation_client.dart` и новый test: `No issues found!`. Независимое read-only review `db_migration_preflight` не выявило blocker по DTO, epoch/refresh/cursor и cap/actual settlement; предложенные точные server field limits и невозможный membership уточнены. Native/HTTP deployment proof этим не заменяется.

```sh
# cwd: /tmp/clrs-native-auth-client-tests-20261001
DART=/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/toolchains/flutter-3.32.5/bin/cache/dart-sdk/bin/dart
"$DART" --packages=.dart_tool/package_config.json \
  /Users/anaakovleva/.pub-cache/hosted/pub.dev/test-1.25.15/bin/test.dart \
  --concurrency=1 --reporter expanded \
  test/timeweb_conversation_client_test.dart test/timeweb_auth_client_test.dart
"$DART" analyze lib/service/timeweb_auth_client.dart \
  lib/service/timeweb_conversation_client.dart test/timeweb_conversation_client_test.dart
```

Тестировались отдельные byte-identical copies в существующем tiny fixture (2,768 KiB), без pub get/build/APK/AVD/основного `.dart_tool`. SHA-256 source:

| Файл | SHA-256 |
|---|---|
| `lib/service/timeweb_auth_client.dart` | `03afbcefb4f3e0aad31c3c0856e8348783f7b2998e22e0fd8263e78215c67906` |
| `lib/service/timeweb_conversation_client.dart` | `654097524eb2af92478a2de85ed6f48a6254536c7b7953f84e99a766bbfa1d21` |
| `test/timeweb_conversation_client_test.dart` | `af933fc6e558dae071f528a5cd0df6485f311c2854b9347a803c99f912985b49` |

До включения нужны live reviewed read role/grants+source pin+HTTP flags, controlled identity/membership/old-password Auth proof, Android secure store proof, обработка stale/unknown/blocked в UI и новый bound APK. Клиентские production defaults остаются прежними.
