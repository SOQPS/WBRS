# План переноса чатов и встреч

`project-conversations-core.mjs` готовит проверяемый план для существующих MySQL 8.4 таблиц `chats`, `chat_members`, `chat_messages`, `meetings`, `meeting_members`, `meeting_messages`, `removed_meeting_messages`. Добавлены отдельные SQL adapter/CLI с закрытыми по умолчанию проверками источника и записью в одну транзакцию. Настоящих MySQL/Firebase/S3 изменений, DDL или деплоя этим этапом **не выполнялось**. Gift/payment/wall projection остаются вне этого этапа.

План читает завершённый authenticated CLRSX2 metadata archive либо completed FULL archive через существующий `readEncryptedArchive`. Проверяются source project/database/bucket, порядок записей, уникальность исходных UID/path, completion counters и AES authentication. Лимиты: до 10 000 Auth, 100 000 Firestore документов, 10 000 Storage объектов / 7 200 000 000 bytes, 64 000 000 bytes на объект, 256 MiB суммарного encoded JSON; их можно только уменьшать. При FULL проходе scanner держит один ограниченный объект для сверки checksum; plan оставляет только metadata/hash/key, без decrypted bytes. Частичный, повреждённый или trailing архив не даёт accepted plan.

Metadata разрешён **только для планирования**: `assertPreparedConversationPlan(plan)` по умолчанию требует `scope=all/completeSource=true` и отклоняет metadata. `conversationProjectionSummary(plan)` явно выводит только aggregate counts и fingerprints. Полный объект plan содержит исходные UID/сообщения/пути в памяти и не предназначен для вывода/публикации. Source hashes/salts/password keys не читаются.

## Исходные коллекции и покрытие

Локально прочитан sealed shard `firebase-segmented-metadata-20261001.clrsenc`: **8 208 Auth, 70 486 Firestore документов**. Сверка не подтверждает завершение Storage/full bundle. Aggregate-only результат сохранён вне Git в приватном `conversation-projection-metadata-summary-20261001.json` (0600), рядом с archive.

| Источник | Записей | Normalized в плане | Только raw с явной причиной |
|---|---:|---:|---:|
| `chats/*` | 6 102 | 5 449 | 653 |
| `chats/*/chats/*` | 8 884 | 6 737 | 2 147 |
| `meets/*` | 201 | 155 | 46 |
| `meets/*/messages/*` | 364 | 159 | 205 |
| `users/*/removed_meets/*/messages/*` | 98 | 67 | 31 |
| `meets/*/membership_requests/*` | 6 | 0 | 6 |
| `removedChats/*` | 3 | 0 | 3 |

Сохранены все **15 658** документов этого scope; **3 091** имеют disposition `raw_only`. Оставшиеся **54 828** документов принадлежат другим разделам и остаются в общем raw importer. Normalized rows: 5 449 chats, 10 898 chat members, 6 737 chat messages, 155 meetings, 525 meeting members, 159 meeting messages, 67 removed-message copies. Это вычисленный план, а не записанные данные/работающий API.

Остальные source patterns точно учтены: `TOKENS/*` 7 495, `transaction/*` 173, `users/*` 6 103, `users/*/images/*` 10 162, `users/*/visiters/*` 30 879, `users/*/notifications/*` 7, `users/*/wall/*` 1, `posts/*` 3, `posts/*/comments/*` 2, `posts/*/likes/*` 2, `moderator_requests/*` 1. Эти значения не включают UID/email/content/photo data. Неизвестные collection names в публичной сводке заменяются `<other>`.

В source `users` arrays встреч объявлены **839** участий; 525 нормализуются, 314 остаются raw: 296 принадлежат unresolved meeting parents, 18 ссылаются на отсутствующий Auth account. В `kicked` arrays ещё 19 исторических entries; они не превращаются в активных участников и не получают придуманные даты.

## Mapping по существующим Flutter сценариям

| Source | Поля и типы | Решение |
|---|---|---|
| Chat root | `user1/user2/chatId` string, `lastMessageSendTs` timestamp, `unreadMessage` integer | Document path ID авторитетен. Две разные реальные Auth UID дают explicit pair/members. UTF-8 byte ordering совпадает с бинарным target ordering; исходные строки не lower-case/normalize. Source counters и preview остаются `legacy_raw`. |
| Personal message | `sendByID` string; `message` string; `ts` timestamp или integer; optional `sender/isRead/replyMessage/image/deleteFor` | UID должен принадлежать explicit parent pair и существовать в Auth. Body сохраняется точно. Source order → positive sequence, стабильный ID tie break. |
| Meeting root | `admin/type/name/description/datetime` string; `timeStamp` timestamp; `users` string array | Organizer — реальный Auth UID. Source `групповая/индивидуальная` → `group/individual`. Existing `users` — единственный источник текущего membership; organizer автоматически не добавляется. |
| Meeting message | `sender` string, `message` string, `time` timestamp | Реальный parent и explicit current member обязательны. Исторический sender вне текущих users не становится активным участником. |
| Removed meeting message copy | Owner UID/meeting ID/message ID из path | Только реальные owner account + normalized meeting. `archived_at` — фактический document createTime. `source_sequence` только при exact совпадении fields с original message; иначе NULL с warning. |

Проверены текущие call sites `database_service.dart`, `chat_submission.dart`, `meeting_write_service.dart`, `meeting_membership_service.dart`, `message_tile.dart`, `shared/meeting_form.dart`. UI personal history использует `chats/{id}/chats`, meeting history — `meets/{id}/messages`, после выхода — personal removed-meets copy. Эти пути не объединяются без source proof.

Для исходных personal messages: 8 850 `ts` timestampValue и 34 integerValue. Все 34 в millisecond range; преобразуется именно integer milliseconds, не seconds по догадке. Малые/неоднозначные integers остаются raw. Сортировка timestamp сохраняет nanoseconds; MySQL DATETIME сохраняет microseconds, оригинал остаётся в raw. В projected набор вошёл 31 legacy integer timestamp, остальные записи отклонены по более раннему unresolved-parent/другому основанию.

Source `datetime` всех 201 встреч — локальная строка `dd.MM.yyyy HH:mm` без timezone. Календарь проверяется, **UTC не угадывается**: `starts_at=NULL`, полный source datetime в raw + warning. Для typed UTC datetime mapping уже предусмотрен. Старый local ISO `timeStamp` без offset использует реальный document createTime с отдельным warning. API должен поддержать source local display до определения timezone contract.

## Не скрываем unresolved записи

Бизнес-несогласованность не прерывает весь план: каждый source document получает `normalized` либо `raw_only`, точную причину и warnings. Coverage всегда считает исходную запись; raw payload не меняется. Ошибка archive envelope/authentication/completion по-прежнему прекращает весь план.

В свежем источнике есть 634 chats с отсутствующим Auth одной из сторон, 5 self-pairs и 9 duplicated unordered pairs (19 source chat IDs). Normalized candidates с duplicated pair не получают winner/merge; 14 таких candidates помечены отдельно, ещё 5 уже rejected по отсутствующему Auth. 1 personal message и 50 meeting messages не имеют root parent. Остальные parent failures также включают rejected parent source records — поэтому причины normalized coverage шире прямых orphan counts.

159 встреч group / 42 individual, **invitedUid отсутствует во всех старых root records**. MySQL individual CHECK требует реального отличающегося invited UID. Не назначается произвольный участник: все 42 individual остаются raw, включая 5 с отсутствующим organizer Auth; дополнительно raw 4 group meetings с отсутствующим organizer. Итог 46 unresolved parents. Это обязательный compatibility вопрос перед полным cutover, а не разрешение менять тип старой встречи на group.

Отсутствующий profile при существующем Auth отмечается warning и не приводит к созданию profile или потере исторического отношения: текущие target FK требуют `accounts`. Source email/name/avatar не используются для поиска «похожего» аккаунта. Identity mismatch, malformed typed scalar/array, unsupported kinds/oversized values, sender вне explicit membership и дубли normalized IDs классифицируются raw-only.

138 source `replyMessage` содержат quoted map, **без message ID**. Quote сохраняется verbatim в `legacy_raw`; `reply_to_id=NULL`, никакого FK по совпадению текста/имени. 68 quoted replies попали в normalized candidates; остальные сохранены raw по более ранним причинам. Image/gift/shared notices сохранены raw-only для отдельного последующего scope, без вымышленных media/gift rows.

`read_through_sequence` пока 0 с явным warning: общий source unread counter/отдельные `isRead` нельзя честно заменить одним monotonic cutoff без отдельной проверки. Original `isRead`, `unreadMessage`, per-user deletion (`deleteFor/deletedFor`) и mute/preferences сохраняются raw. Chat notifications берутся только из explicit `usersWOutNotifications`. Meeting mute list остаётся parent raw, поскольку в текущем `meeting_members` нет такого столбца. `deleted_at` не ставится по personal hide-флагу. Отсутствующие joined/left/kicked times остаются NULL; receipts не переигрывают membership actions.

## Следующие границы

1. Дождаться authenticated completed FULL bundle/FINAL manifest, повторить prepare по нему и сверить новое покрытие. Metadata summary не заменяет этот gate.
2. Подготовленные SQL adapter/CLI нужно проверить и затем выполнить только после raw import+полного raw/S3 readback и account/profile projection. SQL fake tests не подтверждают реальные MySQL constraints, TLS connection или live user сценарии.
3. Для полного пользовательского переноса нужны совместимые API views для unresolved historical records, old individual meetings, quotes, receipts, local dates и removed histories. До этих routes/cutover checks normalized subset не объявляется полным переносом истории.

Адресные offline проверки: `node --test test/project-conversations.test.mjs test/project-conversations-mysql84.test.mjs` — **29/29**. Только искусственные fixtures, без source UID/email/message/photo values. Проверены mapping/raw coverage, source и account binding, все семь empty-target guards, JSON/byte-exact full readback, packet bounds, transaction rollback, receipt durability failure, committed/not-committed lost-COMMIT cases, receipt tamper/truncation, FULL-only CLI и отсутствие source values в выводе. Настоящих SQL/Firestore/S3 writes нет.

## SQL и команды после завершения полного архива

`project-conversations-mysql84.mjs` требует ровно глобальный `USAGE` и `CREATE, REFERENCES, SELECT, INSERT, UPDATE` на `clrs_staging.*`, без GRANT OPTION/DELETE/других scopes. `USE default_db` обязан вернуть именно 1044. CLI читает private config/CA, разрешает только DNS host + `rejectUnauthorized=true/verifyIdentity=true`; затем проверяется активный TLS cipher, MySQL 8.4, page16k, utf8mb4/strict mode, schema v1 / 42 InnoDB Dynamic binary-collation tables / 66 FK. DDL и расширение прав отсутствуют.

Перед INSERT одна SERIALIZABLE транзакция сверяет source project/database/bucket и **все** raw Auth/Firestore/Storage counts, затем каждые UID/path/typed JSON/hash; для документов также exact parent/collection/document ID, для Storage — bucket/path/metadata/size/source hash/target key/hash и copied marker. Это SQL binding, а не повторная проверка содержимого S3: полный raw importer S3 readback обязателен отдельно. Все account/identity/profile rows обязаны совпадать с существующим profile projection contract, включая disabled/lifecycle/tokenVersion/claims, nullable fields и retained raw; accounts/profiles не создаются и не перезаписываются. Несовместимый источник даёт `dependencyReady=false`, SQL останавливается до подключения.

Все семь canonical tables проверяются пустыми под блокировкой; существующие данные требуют `verify`, автоматической перезаписи нет. Партии не больше 100 и половины фактического `max_allowed_packet` с запасом на UTF-8/escaping/params. Каждая исходная/целевая строка проверяется на этот лимит до первого INSERT. Сначала parents, затем members/messages/copies. После записи сравниваются полные keys/columns/JSON/timestamps каждой строки и общие counts, включая extra/missing rows.

Команда ниже — **локальный dry-run** завершённого FULL index/archive, без подключения к БД. `${FULL}` должен указывать на проверенный sealed FULL index; metadata shard не принимается CLI. `${ARCHIVE_KEY}` — уже существующий private key, `${NODE}` — поддерживаемый Node 22, `${PRIVATE}` — каталог 0700 вне Git.

```sh
"${NODE}" server/timeweb/project-conversations-cli.mjs \
  --archive "${FULL}" --key-file "${ARCHIVE_KEY}" \
  --project chatapp-4e347 --database '(default)' --bucket chatapp-4e347.appspot.com
```

Dry-run выводит aggregate counts, `archiveSha256`, `projectionSha256`, `dependencySha256` и `rawOnlyAcknowledgement` с точными document/participant counts и reason digest. Для stage/verify эти значения передаются **явно**; прежняя metadata сводка не разрешает новую FULL запись. Отдельный random 32-byte receipt key заранее сохраняется private, не в Git/APK и не совпадает с export key.

```sh
"${NODE}" server/timeweb/project-conversations-cli.mjs \
  --mode stage --archive "${FULL}" --key-file "${ARCHIVE_KEY}" \
  --project chatapp-4e347 --database '(default)' --bucket chatapp-4e347.appspot.com \
  --config-file "${MYSQL_CONFIG}" --ca-file "${MYSQL_CA}" \
  --confirm-target-db clrs_staging \
  --confirm-archive-sha256 "${ARCHIVE_SHA}" \
  --confirm-projection-sha256 "${PROJECTION_SHA}" \
  --confirm-dependency-sha256 "${DEPENDENCY_SHA}" \
  --ack-raw-only-documents "${RAW_ONLY_DOCUMENTS}" \
  --ack-raw-only-participant-entries "${RAW_ONLY_PARTICIPANTS}" \
  --ack-raw-only-reason-digest "${RAW_ONLY_REASON_SHA}" \
  --receipt-key-file "${RECEIPT_KEY}" --receipt-file "${PRIVATE}/conversation-stage.clrsenc"
```

Перед COMMIT создаётся exclusive encrypted receipt (0600): source/plan/dependency binding, raw-only acknowledgement, aggregate counts и full target rows digest. Сначала writer fsync и exclusive публикация complete file через hard link, затем fsync каталога, только потом COMMIT. Ошибка receipt/write/readback приводит к обычному transaction ROLLBACK. Никакие raw tokens/UID/content не печатаются. При потерянном ответе COMMIT возвращается `CONVERSATION_COMMIT_OUTCOME_UNKNOWN`, connection больше не разрешает stage; receipt обязательно сохраняется. Его существование запрещает CLI stage до подключения.

Для сверки выполните ту же команду с `--mode verify` и **тем же receipt/key/hash/acknowledgements** через новое соединение. READ ONLY snapshot заново сверяет сырой источник/dependencies и все canonical rows: `present_verified` означает exact matching rows, `not_committed_verified` — все семь пусты при непустом плане; частичный/изменённый/лишний набор завершается ошибкой. Для полностью пустого плана результат `empty_no_row_effect_verified` не доказывает факт COMMIT. После `not_committed_verified` новую попытку отдельно готовит оператор с новым receipt path; автоматически CLI ничего не удаляет/не повторяет. Текущая migration роль не имеет DELETE, поэтому post-commit удаление/rollback не реализованы; operational fallback — существующий Firebase до отдельного cutover.

Нормализованное хранение этого subset **не означает готовность chat/meeting API или полного ухода с Firebase**. До переключения нужны compatibility reads старых individual meetings без invitedUid, duplicated/missing-parent pairs, исторических senders/removed copies, медиа/gift/shared notices, local datetime, `isRead/unreadMessage`, per-user deletion/notifications и legacy replies. `compatibilityApiReady=false` выдаётся во всех отчётах. Ограниченная read-only API роль не получает новые права автоматически; runtime разрешения для соответствующих reads/writes остаются отдельным блокером.

После FINAL exporter proof выполнен **один локальный FULL dry-run** sealed index `firebase-segmented-20261001/full.clrsenc`, без SQL/S3 connections. Composite archive SHA совпал с exporter: `b21387e6493e0e2387f219909d4fec81604f4a12ead7d0997de192015bad867e`. Подтверждены 8 208 Auth / 70 486 документов / 6 478 файлов / 6 932 196 752 bytes. Покрытие normalized/raw-only из таблицы выше сохранилось; dependencies ready: 8 208 accounts/identities, **6 031** profiles из 6 103 root user docs, 72 orphan profiles и 2 177 Auth без profile. Это обновление шести Auth/profile records к прежней metadata projection, а не поиск аккаунтов по имени/email.

Актуальные подтверждения FULL плана: projection SHA `dc729302e7530b085b9690972fd5efe5585bdb870ee9b29501ac128e6e5604e4`, dependency SHA `c0965e075e6f00bd238921f34e6356e11f5763d913e757b2a9122f32b8d2e6ab`; raw-only 3 091 документов / 314 participant entries, reason digest `d354add32157d3ebfa1fc0fb4c3ca11a295394a2b398c43b045e229a4561ac60`. Aggregate-only FULL summary хранится private/0600 вне Git: `conversation-projection-full-summary-20261001.json`. Snapshot исходного Firebase не является атомарным: final source delta/sync обязателен перед cutover, hashes этого snapshot не разрешают незаметно заменить источник новым.
