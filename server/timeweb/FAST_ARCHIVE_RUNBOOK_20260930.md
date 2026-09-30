# Полный fast-архив: последовательность проверок и staging

Эти команды подготовлены, **запись в MySQL/S3 не запускалась**.
Существующая схема `clrs_staging` уже создана: 42 таблицы / 66 FK / version 1.
`apply-mysql84-schema.mjs` повторно не запускать: он предназначен только
для однократного создания структуры в пустой базе.

Использовать только завершённый `firebase-full-fast-20260930.clrsenc`,
после успешного полного AES/GCM/SHA/HMAC прохода экспортёра. Файл `.partial`,
metadata-архив на 8202 аккаунта и HMAC cache одной Auth-секции не разрешают
полный импорт. Два текущих UID-набора из Auth-секции и отдельного credential
архива уже совпали: 8208 / missing 0 / extra 0; это нужно ещё подтвердить
по окончательному manifest. Снимок не атомарный, финальная синхронизация
новых/изменённых аккаунтов, данных и admin claims остаётся отдельным шагом.

## Пути и границы

Все команды ниже выполняются из `server/timeweb`. Значения переменных здесь
не секретны. Ключи AES/HMAC в аргументах представлены **только путями**.

```sh
CLRS_MIGRATION_NODE=/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/toolchains/node-v22.23.2-darwin-arm64/bin/node
CLRS_PRIVATE_DIR=/Users/anaakovleva/Documents/Codex/2026-09-21/ds/work/private_migration_20260930
CLRS_ARCHIVE="$CLRS_PRIVATE_DIR/firebase-full-fast-20260930.clrsenc"
CLRS_ARCHIVE_KEY="$CLRS_PRIVATE_DIR/export.aes.key"
CLRS_MANIFEST="$CLRS_PRIVATE_DIR/firebase-full-fast-manifest-20260930.json"
CLRS_HMAC_KEY="$CLRS_PRIVATE_DIR/manifest.hmac.key"
CLRS_PROJECTION_RECEIPT="$CLRS_PRIVATE_DIR/profile-projection-full-fast-20260930.clrsenc"
umask 077
```

До этапа записи оператор загружает в защищённую среду процесса реквизиты
из приватных файлов `0600`, без печати, командных аргументов или Git:

- `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`,
  `MYSQL_DATABASE=clrs_staging`,
  `MYSQL_CA_FILE=/Users/anaakovleva/.config/clrs/timeweb-ca.crt`.
  Существующий `clrs_migrate` имеет ровно CREATE/REFERENCES/SELECT/INSERT/UPDATE
  только в `clrs_staging`; доступ `default_db` запрещён.
- `S3_ENDPOINT=https://s3.twcstorage.ru/`, фактический `S3_REGION`,
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `TIMEWEB_API_TOKEN`.
  Только существующий подтверждённый приватный bucket, без новых платных услуг.
- `CLRS_TARGET_BUCKET` — точное имя этого bucket;
  `CLRS_TIMEWEB_BUCKET_ID` — его числовой ID в Timeweb. Пока эти значения
  и ограниченный S3-доступ не подтверждены, этап записи не выполнять.

Для локальных этапов environment MySQL/S3 не требуется. Текущая Storage
инвентаризация содержит максимальный объект 17 547 413 bytes и 0 объектов
свыше 64 MB; предел импорта остаётся 64 000 000 bytes на объект.
Если новый снимок превысит предел, процесс остановится; лимит автоматически
не повышать, поскольку S3 callback буферизует целый объект.

## 1. Полный архив ↔ окончательный manifest, без сети

```sh
"$CLRS_MIGRATION_NODE" verify-export-manifest.mjs \
  --archive "$CLRS_ARCHIVE" --key-file "$CLRS_ARCHIVE_KEY" \
  --manifest "$CLRS_MANIFEST" --hmac-key-file "$CLRS_HMAC_KEY" \
  > "$CLRS_PRIVATE_DIR/full-fast-import-manifest-preflight-20260930.json"
```

Требуется exit 0, `equalToInventory:true`, все comparison counters 0.
`archiveSha256` из этого отчёта — подтверждение ровно того архива, который
будет использован для проекции. Не принимать одно совпадение счётчиков
без этой проверки наборов и каждой Storage checksum/size.

## 2. Bounded dry-run raw-импорта, без сети

```sh
"$CLRS_MIGRATION_NODE" import-clrsx2-mysql84.mjs \
  --archive "$CLRS_ARCHIVE" --key-file "$CLRS_ARCHIVE_KEY" \
  --project chatapp-4e347 --database '(default)' --bucket chatapp-4e347.appspot.com \
  --mode dry-run --max-auth-users 10000 --max-firestore-documents 100000 \
  --max-storage-objects 10000 --max-storage-bytes 7200000000 --max-object-bytes 64000000 \
  > "$CLRS_PRIVATE_DIR/full-fast-import-dry-run-20260930.json"
```

Требуется exit 0 и совпадение четырёх counts с завершённой выгрузкой.
Оригинальные UID, поля и все document/object пути остаются в `legacy_*`;
это ещё не готовые рабочие таблицы всех функций приложения.

## 3. Dry-run проекции accounts/profiles, без сети

```sh
"$CLRS_MIGRATION_NODE" project-profiles-cli.mjs \
  --archive "$CLRS_ARCHIVE" --key-file "$CLRS_ARCHIVE_KEY" \
  --project chatapp-4e347 --database '(default)' --bucket chatapp-4e347.appspot.com \
  --mode dry-run --max-auth-users 10000 --max-firestore-documents 100000 \
  > "$CLRS_PRIVATE_DIR/full-fast-profile-projection-dry-run-20260930.json"
```

Из **этого полного** плана взять `archiveSha256`, `counts.orphanProfiles`,
`counts.accountsWithoutProfile`; сравнить SHA с этапом 1. Записать эти
не секретные подтверждения в `CLRS_ARCHIVE_SHA256`, `CLRS_ORPHAN_PROFILES`,
`CLRS_ACCOUNTS_WITHOUT_PROFILE`. Значения 72/2177 из старого metadata-снимка
не переносить автоматически: источник уже изменился.
В этом этапе также должны совпасть окончательные Auth UID с credential
bundle. Отдельный проверенный credential archive пока не импортируется.

## 4. Raw-импорт в существующие MySQL и приватный S3

Этап разрешён только после 1–3 и подтверждения защищённой среды/назначения.
Первая полная проверка архива внутри CLI выполняется до транзакции и S3
пользовательских записей. S3 приватность проверяется до и перед COMMIT.

```sh
"$CLRS_MIGRATION_NODE" import-clrsx2-mysql84.mjs \
  --archive "$CLRS_ARCHIVE" --key-file "$CLRS_ARCHIVE_KEY" \
  --project chatapp-4e347 --database '(default)' --bucket chatapp-4e347.appspot.com \
  --mode stage --confirm-target-db clrs_staging \
  --target-media-bucket "$CLRS_TARGET_BUCKET" --confirm-private-bucket "$CLRS_TARGET_BUCKET" \
  --timeweb-bucket-id "$CLRS_TIMEWEB_BUCKET_ID" \
  --max-auth-users 10000 --max-firestore-documents 100000 \
  --max-storage-objects 10000 --max-storage-bytes 7200000000 --max-object-bytes 64000000 \
  > "$CLRS_PRIVATE_DIR/full-fast-import-stage-20260930.json"
```

При ошибке транзакция MySQL откатывается; часть файлов может остаться в
приватном `clrs-import-quarantine/`. Не выдавать их клиенту и не удалять
автоматически. После потери соединения сначала verify фактического
результата; повтор допустим только для того же подтверждённого архива,
поскольку adapter сравнивает полный сохранённый payload/путь/bytes/hash
и не перезаписывает конфликтующий снимок.

## 5. Отдельный raw readback MySQL + S3

```sh
"$CLRS_MIGRATION_NODE" import-clrsx2-mysql84.mjs \
  --archive "$CLRS_ARCHIVE" --key-file "$CLRS_ARCHIVE_KEY" \
  --project chatapp-4e347 --database '(default)' --bucket chatapp-4e347.appspot.com \
  --mode verify --confirm-target-db clrs_staging \
  --target-media-bucket "$CLRS_TARGET_BUCKET" --confirm-private-bucket "$CLRS_TARGET_BUCKET" \
  --timeweb-bucket-id "$CLRS_TIMEWEB_BUCKET_ID" \
  --max-auth-users 10000 --max-firestore-documents 100000 \
  --max-storage-objects 10000 --max-storage-bytes 7200000000 --max-object-bytes 64000000 \
  > "$CLRS_PRIVATE_DIR/full-fast-import-readback-20260930.json"
```

Требуется exit 0: каждая Auth/document/Storage запись и каждый S3 объект
проверены обратно, итоговые counts совпали. Verify не пишет в БД или S3.

## 6. Однократная проекция accounts/profiles

Только после успешного raw readback, в пустые accounts/profiles/identities.
План, legacy raw rows и подтверждения должны описывать один и тот же архив.
До первого INSERT проверяется размер всех пакетов относительно фактического
`max_allowed_packet`. Receipt должен быть новым приватным файлом; его
публикация/синхронизация происходит до COMMIT.

```sh
"$CLRS_MIGRATION_NODE" project-profiles-cli.mjs \
  --archive "$CLRS_ARCHIVE" --key-file "$CLRS_ARCHIVE_KEY" \
  --project chatapp-4e347 --database '(default)' --bucket chatapp-4e347.appspot.com \
  --mode stage --confirm-target-db clrs_staging --confirm-archive-sha256 "$CLRS_ARCHIVE_SHA256" \
  --ack-orphan-profiles "$CLRS_ORPHAN_PROFILES" \
  --ack-accounts-without-profile "$CLRS_ACCOUNTS_WITHOUT_PROFILE" \
  --receipt-file "$CLRS_PROJECTION_RECEIPT" \
  --max-auth-users 10000 --max-firestore-documents 100000 \
  > "$CLRS_PRIVATE_DIR/full-fast-profile-projection-stage-20260930.json"
```

При сбое receipt или COMMIT не повторять stage: сначала этап 7 с тем же
receipt. Обнаружение уже существующих normalized rows специально блокирует
повторный INSERT.

## 7. Отдельный readback проекции с receipt

```sh
"$CLRS_MIGRATION_NODE" project-profiles-cli.mjs \
  --archive "$CLRS_ARCHIVE" --key-file "$CLRS_ARCHIVE_KEY" \
  --project chatapp-4e347 --database '(default)' --bucket chatapp-4e347.appspot.com \
  --mode verify --confirm-target-db clrs_staging --confirm-archive-sha256 "$CLRS_ARCHIVE_SHA256" \
  --receipt-file "$CLRS_PROJECTION_RECEIPT" \
  --max-auth-users 10000 --max-firestore-documents 100000 \
  > "$CLRS_PRIVATE_DIR/full-fast-profile-projection-readback-20260930.json"
```

Требуется exit 0, точные counts, UID/поля/claims и timestamps из receipt.
Post-COMMIT rollback использует DELETE на трёх normalized таблицах и
**недоступен текущим пяти правам clrs_migrate**; новый preflight остановит его
после SHOW GRANTS. Права не расширялись. До отдельного восстановления/отката
переключение production не выполнять; Firebase остаётся operational fallback.

Даже успех 1–7 подтверждает raw-копию и узкую проекцию, а не полный переезд
приложения. Ещё нужны отдельный credential import и живой собственный вход,
права и рабочие операции остальных функций, безопасная выдача S3 media,
финальная дельта и пользовательские проверки до production cutover.
