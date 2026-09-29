# CLRSX2 → MySQL 8.4 staging

Статус: **MySQL CLI, адаптер импорта и обратной проверки подготовлены и проверены только на синтетическом архиве**. Реальные MySQL `clrs_staging`, Firebase и S3 не использовались. Существующий `import-clrsx2.mjs` остаётся PostgreSQL CLI; для MySQL применять только `import-clrsx2-mysql84.mjs`.

`import-mysql84-adapters.mjs` реализует контракт `stageImport` / `verifyStagedImport` для уже подготовленной [схемы](db/001_initial_mysql84.sql). Он пишет только `legacy_source`, `legacy_auth_users`, `legacy_documents`, `legacy_storage_objects`. UID и Firestore/Storage пути сохраняются полностью, включая значения длиннее 191 символа. Уникальные SHA-256 индексы используются для поиска; после каждой вставки и при чтении обратно сравниваются **полные строки**, JSON, размер, SHA-256, карантинный ключ и отметка копирования. Любое различие прерывает транзакцию. Повтор того же архива безопасен; другой снимок, даже с теми же UID, намеренно вызывает конфликт.

Перед записью адаптер требует активную базу `clrs_staging`, MySQL 8.4, схему версии 1, `utf8mb4` и строгий SQL-режим. Первая транзакция фиксирует Firebase project/database/bucket в `legacy_source`; повторная сверяет их. Проверка назначения работает в транзакции `READ ONLY`, читает каждую строку и сравнивает общие счётчики. Таблицы приложения и `default_db` адаптер не меняет.

## Запуск CLI

Из `server/timeweb` сначала выполнить `npm ci` на доверенном хосте с Node 22. CLI разделяет проверку аргументов, приватных файлов и S3 с PostgreSQL импортёром. Архив, ключ и CA должны быть **отдельными завершёнными файлами `0600` вне репозитория**. Пароль и токены передавать только через защищённую среду процесса, не через командную строку, git или отчёт.

Для `stage` и `verify` нужны переменные `MYSQL_HOST` (DNS-имя из сертификата, IP не принимается), `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE=clrs_staging`, `MYSQL_CA_FILE`. CLI задаёт `rejectUnauthorized: true` **и** `verifyIdentity: true`: у текущего `mysql2` одной проверки CA недостаточно для сверки имени хоста. CA читается из приватного файла. Дополнительно нужны `S3_ENDPOINT=https://s3.twcstorage.ru/`, `S3_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `TIMEWEB_API_TOKEN`. Импортёру нужны DML-права только на `clrs_staging.legacy_*` и SELECT на `clrs_staging.schema_migrations`; отдельный S3 bucket обязан быть приватным. Не использовать пользователя/базу старого Flask-приложения или `default_db`.

Первый проход читает архив без сетевых подключений:

```sh
node import-clrsx2-mysql84.mjs \
  --archive /private/export.clrsenc --key-file /private/export.key \
  --project PROJECT_ID --database '(default)' --bucket FIREBASE_BUCKET \
  --mode dry-run
```

После подготовки отдельного MySQL-пользователя и приватного S3 выполнить запись, затем отдельное чтение обратно. Имя целевой БД и bucket повторяются в аргументах для защиты от ошибочной настройки:

```sh
node import-clrsx2-mysql84.mjs \
  --archive /private/export.clrsenc --key-file /private/export.key \
  --project PROJECT_ID --database '(default)' --bucket FIREBASE_BUCKET \
  --mode stage --confirm-target-db clrs_staging \
  --target-media-bucket PRIVATE_MEDIA_BUCKET \
  --confirm-private-bucket PRIVATE_MEDIA_BUCKET --timeweb-bucket-id BUCKET_ID

node import-clrsx2-mysql84.mjs \
  --archive /private/export.clrsenc --key-file /private/export.key \
  --project PROJECT_ID --database '(default)' --bucket FIREBASE_BUCKET \
  --mode verify --confirm-target-db clrs_staging \
  --target-media-bucket PRIVATE_MEDIA_BUCKET \
  --confirm-private-bucket PRIVATE_MEDIA_BUCKET --timeweb-bucket-id BUCKET_ID
```

Перед пользовательскими файлами `stage` проверяет приватность бакета и делает анонимную пробу доступа, как PostgreSQL CLI. Затем каждый объект загружается или сравнивается по байтам в карантине; перед коммитом приватность бакета проверяется снова. `verify` только читает БД и S3 и сверяет каждую запись и общие счётчики. Настраиваемые пределы `--max-*` совпадают с [PostgreSQL импортёром](IMPORT_PREPARATION.md). Если `stage` оборвётся после S3-записи, транзакция MySQL откатится, а файл может остаться в приватном карантине; применять описанную там сверку перед очисткой.

Пока нет отдельного MySQL-доступа и приватного S3 bucket, реальный `stage`/`verify` заблокирован. Следующий подтверждающий шаг — изолированный прогон против MySQL 8.4 и S3 Timeweb, затем независимое сравнение с Firebase-инвентаризацией. Локальные тесты не доказывают совместимость с сервером или полноту выгрузки.

Локальная проверка из `server/timeweb` (без сети): `node --test test/import-mysql84-cli.test.mjs test/import-mysql84-adapters.test.mjs test/import-stage.test.mjs` и `npm run check`.
