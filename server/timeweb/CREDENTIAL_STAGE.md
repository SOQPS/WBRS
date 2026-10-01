# Зашифрованные данные паролей: подготовка импорта в clrs_staging

Этот шаг переносит сохранённые Firebase SCRYPT credentials в существующую таблицу `auth_credentials`. Он не включает вход приложения через Timeweb, выпуск сессий, смену паролей, переключение Flutter или отключение Firebase. Реальный native login ещё требует отдельной реализации, деплоя и контролируемого живого входа прежним паролем.

На 30 сентября отдельный credential bundle был полностью прочитан и проверен: 8 208 пользователей, 8 208 доступных password records, Firebase SCRYPT, версия 0. Сравнение UID с Auth-секцией прежнего незавершённого экспорта показало совпадение, однако тот full export завершился ошибкой и был удалён. Это не доказательство готовности полного переноса. Новая команда требует **завершённый full/segmented sealed index и FINAL manifest**, а не старый UID-cache или metadata-only архив.

## Порядок и ограничения

1. Завершить segmented export и проверить все sealed shards, конечный индекс и FINAL schema-v2/HMAC manifest. `readEncryptedArchive`/`scanImportArchive` должны полностью пройти источник до authenticated end. SHA полного segmented источника составной и привязан к ciphertext индекса и перечисленных shards.
2. Выполнить `credential-stage-cli.mjs --mode dry-run`. Открывать SQL до полной проверки источника нельзя. FINAL manifest заново строится из всего архива и сравнивается полностью; HMAC UID-набор, исходный проект/БД/bucket должны совпадать.
3. Ранее существующие raw `legacy_*` данные и normalized accounts/profiles/identities должны быть импортированы и независимо проверены из этого же полного источника. Credential stage сверяет их точные UID/оригинальные payloads, статус, email, provider subjects и lifecycle. Имена и email не используются для угадывания связей.
4. Только после этого выполнить `stage` с тремя подтверждёнными SHA и новым receipt-файлом. Скрипт запишет credentials одной транзакцией и проверит чтение обратно перед COMMIT.
5. Выполнить отдельный `verify` с сохранённым зашифрованным receipt. Это проверяет точные ciphertext, timestamps и bindings, сохраняя отдельную границу между успешным COMMIT и проверкой новой связи.

Лимиты по умолчанию и верхняя разрешённая граница: Auth 10 000, Firestore 100 000 документов, Storage 10 000 объектов / 7 200 000 000 байт, один объект 64 000 000 байт; совокупный сериализованный decoded metadata ограничен 256 MiB. Credential bundle ограничен 20 MiB, FINAL manifest 64 MiB. CLI может уменьшить лимиты, но не расширить их. Неизвестный scheme/version, недоступный материал или non-password record останавливают batch; автоматической замены на `bridge_only` нет. Если живая Auth-секция отличается от credential snapshot, нужен новый отдельный credential export и повторная локальная проверка.

## Секреты и права

Все входные файлы и CA — private regular files с правами 0600 вне Git. Receipt-directory — 0700. В APK/Git/выводе команд нет хеша пароля, salt, signer key, UID, email или токенов.

Нужен отдельный случайный 32-байтовый wrapping key, сохранённый владельцем в защищённом файле/secrets. Он не должен совпадать с AES/HMAC ключами экспортов. Его нельзя менять после импорта без отдельной миграции шифрования. `--config-ref` — постоянное имя серверного secret для экспортированного SCRYPT hashConfig; signerKey находится только в этом server secret, не в SQL `parameters`. Будущий native service должен получить именно эти hashConfig/wrapping key через защищённое окружение. CLI не устанавливает secrets на сервер.

`password_hash` и `password_salt` содержат AES-256-GCM ciphertext с nonce/tag. AAD точно связывает UID, таблицу, scheme config identity, исходную версию, provider/status/email verification и validSince. Поля JSON связываются в фиксированном порядке, поэтому сортировка MySQL JSON не нарушает расшифрование. Исходная base64-строка и тип версии сохраняются.

Stage принимает только прямые права `CREATE, REFERENCES, SELECT, INSERT, UPDATE` на `clrs_staging.*` плюс глобальный `USAGE`. Дополнительные права, `DELETE`, `GRANT OPTION`, доступ к `default_db`, другая БД, неверный TLS, MySQL не 8.4 или схема не 42 таблицы/66 FK/version1 останавливают запись. Соединение использует DNS-имя, CA, `rejectUnauthorized: true`, `verifyIdentity: true`, utf8mb4 и строгий session sql_mode. Повторное DDL не выполняется.

## Команды после завершения архива

Подставить реальный новый sealed index и его FINAL manifest. Удалённый `firebase-full-fast-20260930.clrsenc` и файлы `.partial` не использовать. Следующие примеры — инструкция, они не были выполнены на staging.

```bash
clrs_node='/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/toolchains/node-v22.23.2-darwin-arm64/bin/node'
clrs_private='/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/private_migration_20260930'
clrs_full_index='/ABSOLUTE/PATH/TO/COMPLETED-SEALED-INDEX.clrsenc'
clrs_final_manifest='/ABSOLUTE/PATH/TO/FINAL-MANIFEST.json'
clrs_credential_args=(
  --archive "$clrs_full_index"
  --key-file "$clrs_private/export.aes.key"
  --credentials '/Users/anaakovleva/.config/clrs/auth-credentials-20260930.clrsenc'
  --credentials-key-file '/Users/anaakovleva/.config/clrs/auth-credentials-20260930.aes.key'
  --manifest "$clrs_final_manifest"
  --hmac-key-file "$clrs_private/manifest.hmac.key"
  --wrapping-key-file '/Users/anaakovleva/.config/clrs/native-credential-wrapping.key'
  --config-ref firebase_scrypt_20260930_v0
  --project chatapp-4e347 --database '(default)' --bucket chatapp-4e347.appspot.com
)
cd '/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/wbrs_github_dev_review'
"$clrs_node" server/timeweb/credential-stage-cli.mjs "${clrs_credential_args[@]}" --mode dry-run
```

Из dry-run взять `archiveSha256`, `credentialArchiveSha256`, `planSha256`. Plan SHA не содержит случайных nonce новой AES-записи, поэтому остаётся одинаковым при повторной проверке тех же источников/secret refs/wrapping key. Нельзя копировать SHA от прежнего metadata archive или другого источника.

```bash
clrs_stage_confirmations=(
  --config-file '/Users/anaakovleva/.config/clrs/timeweb-clrs-migrate.json'
  --ca-file '/Users/anaakovleva/.config/clrs/timeweb-ca.crt'
  --confirm-target-db clrs_staging
  --confirm-archive-sha256 '<ARCHIVE_SHA_FROM_CURRENT_DRY_RUN>'
  --confirm-credentials-sha256 '<CREDENTIAL_SHA_FROM_CURRENT_DRY_RUN>'
  --confirm-plan-sha256 '<PLAN_SHA_FROM_CURRENT_DRY_RUN>'
  --receipt-file '/Users/anaakovleva/.config/clrs/credential-stage-current.clrsenc'
)
"$clrs_node" server/timeweb/credential-stage-cli.mjs "${clrs_credential_args[@]}" \
  "${clrs_stage_confirmations[@]}" --mode stage
"$clrs_node" server/timeweb/credential-stage-cli.mjs "${clrs_credential_args[@]}" \
  "${clrs_stage_confirmations[@]}" --mode verify
```

## Ошибки, повтор и неизвестный COMMIT

До COMMIT отказ INSERT/readback/receipt откатывает всю SQL транзакцию. Receipt шифруется credential-export AES key, публикуется без перезаписи и fsync файла/директории проходит до отправки COMMIT. Его `state: prepared` описывает возможный исход, а не доказывает COMMIT.

После потери ответа COMMIT не повторять stage и не удалять receipt. Выполнить `verify` с тем же receipt:

- `present_verified`: все ожидаемые ciphertext и associations на месте.
- `not_committed_verified`: сохранилось точное состояние до этой попытки; автоматический повтор всё равно не выполняется.
- Другая комбинация данных: отказ и ручная сверка, без удаления/перезаписи.

Точное уже существующее credential принимается идемпотентно и сохраняет свой timestamp/ciphertext; только отсутствующие UID вставляются после проверки всех существующих записей. Любая конфликтующая запись останавливает batch. Даже повторная проверка не запускает смену парольной схемы, не активирует blocked/deleted/disabled account и не создаёт новые аккаунты/роли. Post-COMMIT DELETE rollback не поддерживается и текущей роли не нужен.

## Проверка кода

`node --test server/timeweb/test/credential-stage.test.mjs` — 14 synthetic tests: полный источник и FINAL manifest, mismatched UID при одинаковых counts, GCM/truncation/trailing errors, неподдерживаемая версия, bindings к raw/profile/identity/status, точные grants/TLS/пакеты, encrypted parameterized batch, атомарный rollback, идемпотентность, конфликт без overwrite, lost COMMIT с обоими исходами, encrypted receipt, byte-exact UTF-8 ordering, private CLI dry-run.

Эти проверки не являются подтверждением реального credential stage или native login. До живого входа прежним паролем после деплоя полный уход с Firebase Auth не подтверждён.
