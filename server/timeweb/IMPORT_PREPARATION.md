# CLRSX2: подготовка пробного импорта

Эта страница описывает PostgreSQL CLI. Для существующей `clrs_staging` на MySQL 8.4 см. [отдельный адаптер и ограничения запуска](IMPORT_MYSQL84.md).

Статус: **код подготовлен и проверен на синтетическом архиве**. Он ещё не запускался с данными Firebase и не подключался к настоящим PostgreSQL/S3 Timeweb. Это первый этап сохранения исходных записей, а не готовый backend и не перенос возможности входа по прежнему паролю.

`import-clrsx2.mjs` принимает только завершённую полную выгрузку `CLRSX2` с совпадающими явно подтверждёнными Firebase project/database/bucket. Префиксный/частичный архив, отсутствие финального кадра, лишние кадры, ошибочные размеры или SHA-256 объектов останавливают импорт **до первой записи**. Оба полных чтения сравнивают SHA-256 **всего зашифрованного архива**, а не только его счётчики: подмена между preflight и записью вызывает rollback до коммита БД. Режим `dry-run` не открывает PostgreSQL и S3. Данные расшифровываются в памяти; ключ и архив должны быть отдельными файлами `0600` за пределами репозитория.

В новой изолированной PostgreSQL базе сначала применить `db/001_initial.sql`. Он создаёт singleton `legacy_source`, чтобы нельзя было смешать два Firebase проекта, и таблицы `legacy_auth_users`, `legacy_documents`, `legacy_storage_objects`. Импорт сохраняет UID, Firestore path/ID/parent path, типизированные значения полей, время создания/обновления, Storage path, MIME/generation/metadata, размер и SHA-256. Файлы пишутся в **отдельный приватный** S3 bucket под детерминированным карантинным ключом `clrs-import-quarantine/<SHA-256>`; исходные имена и метаданные остаются в ограниченной таблице. Backend не должен подписывать URL и отдавать ключи этого префикса пользователям. Повторная операция сверяет существующие строки и реальные байты объектов, не перезаписывает отличающиеся данные. PostgreSQL записи коммитятся только после полной второй проверки архива.

Сначала проверить архив без сети (подставить фактические project/database/bucket и пути, **не** помещать секреты в команду):

```sh
node import-clrsx2.mjs \
  --archive /private/export.clrsenc --key-file /private/export.key \
  --project PROJECT_ID --database '(default)' --bucket FIREBASE_BUCKET \
  --mode dry-run
```

После отдельного решения о стоимости/ресурсах задать `DATABASE_URL` с `sslmode=verify-full`, при необходимости `DATABASE_CA_FILE`, а также `S3_ENDPOINT=https://s3.twcstorage.ru/`, `S3_REGION`, стандартные переменные AWS SDK `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` и **отдельный** `TIMEWEB_API_TOKEN` в защищённой среде вне git. Секреты не передавать через параметры процесса. Пользователю импорта нужны только DML-доступ к `legacy_*`/`legacy_source` и SELECT из `schema_migrations`; S3-пользователю нужны чтение ACL/policy, Put/Get объектов и удаление только случайного проверочного объекта. Токен Timeweb должен читать описание бакета по ID, но не управлять ресурсами. Название БД и бакета подтверждаются вторым указанием, а `--timeweb-bucket-id` связывает S3 имя с ресурсом Timeweb:

```sh
node import-clrsx2.mjs \
  --archive /private/export.clrsenc --key-file /private/export.key \
  --project PROJECT_ID --database '(default)' --bucket FIREBASE_BUCKET \
  --mode stage --confirm-target-db NEW_CLRS_DATABASE \
  --target-media-bucket PRIVATE_MEDIA_BUCKET \
  --confirm-private-bucket PRIVATE_MEDIA_BUCKET --timeweb-bucket-id BUCKET_ID
```

До пользовательских файлов инструмент программно проверяет в [Timeweb control API](https://github.com/timeweb-cloud/sdk-go/blob/main/docs/S3API.md), что точный бакет имеет `type=private`; S3 ACL должен содержать только владельца, а [bucket policy](https://timeweb.cloud/docs/s3-storage/supported-features/bucket-policies) отсутствовать. Затем он записывает 32 случайных байта под ключом того же вида, что у фотографий, проверяет отказ анонимного HTTP-запроса и удаляет пробу. После каждой загрузки или повторного использования проверяется ACL объекта; перед коммитом БД проверка типа бакета/ACL/policy повторяется. Если Timeweb API, S3 ACL/policy или анонимный запрос не дают однозначного ответа, импорт прерывается. Это соответствует [модели приватного бакета Timeweb](https://timeweb.cloud/docs/s3-storage/manage-storage/create-bucket), но изменение настроек бакета другим администратором во время длинного импорта всё ещё требует организационной блокировки.

Если после загрузки файлов не пройдёт второе чтение архива, проверка хеша или коммит БД, транзакция PostgreSQL откатится, а некоторые S3 объекты могут остаться **только в приватном карантине**. Они не считаются импортированными и не должны обслуживаться API. План cleanup: остановить импорт и дождаться завершения возможного повторного запуска; перечислить `clrs-import-quarantine/`, сравнить каждый key с `clrs.legacy_storage_objects.target_key` в закоммиченной БД, подготовить список **только неиспользуемых** ключей и удалить их вручную после повторной проверки списка. Не применять общий `sync --delete` и не удалять совпадающие ключи: операция записи S3 и commit БД не атомарны, а повтор может использовать тот же объект. Для успешного переноса в рабочее медиа-хранилище потребуется отдельная проверенная процедура promotion из карантина.

Затем отдельным процессом проверить **прочитанные из назначения** строки, количество, поля, метаданные и байты каждого объекта. `verify` выполняет только SELECT/GetObject, без добавления или исправления записей:

```sh
node import-clrsx2.mjs \
  --archive /private/export.clrsenc --key-file /private/export.key \
  --project PROJECT_ID --database '(default)' --bucket FIREBASE_BUCKET \
  --mode verify --confirm-target-db NEW_CLRS_DATABASE \
  --target-media-bucket PRIVATE_MEDIA_BUCKET \
  --confirm-private-bucket PRIVATE_MEDIA_BUCKET --timeweb-bucket-id BUCKET_ID
```

Ограничения CLI по умолчанию: 100 000 Auth users, 2 000 000 Firestore documents, 200 000 Storage objects, 100 GB всего и 64 MB на один объект. Параметры `--max-auth-users`, `--max-firestore-documents`, `--max-storage-objects`, `--max-storage-bytes`, `--max-object-bytes` меняют эти пределы **после оценки инвентаризации**. Объект больше выбранного `max-object-bytes` отвергается до записи, потому что один объект буферизуется в памяти при передаче в S3.

Важные ограничения: экспорт не содержит Firebase password hash/salt, поэтому вход по старым паролям этим импортом не обеспечен. Исходный снимок Auth/Firestore/Storage не согласован при продолжающихся записях пользователей; перед переключением нужна финальная синхронизация. **Изменённые документы и файлы нельзя повторно импортировать в эту же staging-базу:** строгие проверки намеренно отвергнут конфликт. Для нового полного снимка нужен новый чистый изолированный контур; отдельную delta-синхронизацию ещё предстоит спроектировать и проверить. Эти скрипты не переводят данные в рабочие таблицы, не меняют Firebase URL в документах, не запускают API и не переключают APK. Сверку полноты нужно независимо сопоставить с инвентаризацией Firebase; внутренний `summary` подтверждает целостность архива, но сам по себе не доказывает, что Firebase ничего не пропустил. Не выдавать API/аналитическим ролям общий SELECT на `legacy_*`: внутри могут быть email, сообщения и старые Firebase download tokens.

Локальная проверка: `node --test test/import-stage.test.mjs test/s3-privacy.test.mjs` и `npm run check`. Реальную пробную миграцию считать проверенной только после `dry-run → stage → verify` в новом изолированном Timeweb контуре и отдельных сценариев клиента/прав доступа.
