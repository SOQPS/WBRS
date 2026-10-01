# Подготовка read-only экспорта Firebase

`--max-firestore-concurrency 8` разрешает до восьми параллельных задач чтения коллекций; допустимы целые значения от 1 до 8, по умолчанию остаётся 1. Все ограничения числа запросов, документов и коллекций общие для этих задач. Шифрованные кадры записываются последовательно с ожиданием завершения каждого кадра. При первой ошибке новые задачи и запросы не запускаются, активные чтения и запись дожидаются завершения до удаления неполного архива. Отсутствующие родительские документы по-прежнему обходятся ради их подколлекций. Параллельное чтение сокращает длительность выгрузки, но не добавляет согласованности снимку при продолжающихся пользовательских изменениях.

Статус: **локально проверенный инструмент; на реальном Firebase ранее подтверждён частичный экспорт `--scope metadata`, без импорта в Timeweb**. Его защищённый архив Auth+Firestore проверен на целостность: 8 202 пользователя и 70 412 типизированных документов. Байты Storage в него не входят. Последующая полная попытка прочитала 8 208 пользователей, 70 486 документов и 4 447 файлов, но завершилась ошибкой до публикации архива; полный результат этой попытки не подтверждён. Для следующей попытки подготовлен устойчивый segmented режим ниже. Инструмент не делает записей в Firebase или Timeweb. По умолчанию `export-firebase-encrypted.mjs` читает Auth metadata, типизированные Firestore документы со всеми подколлекциями (включая под отсутствующими родительскими документами) и байты/метаданные объектов Storage. Исходные UID, ID документов, пути и имена объектов сохраняются внутри зашифрованного архива. Парольные хеши и salt намеренно не включены: эта выгрузка сама по себе не переносит возможность входа по старому паролю.

Нужны Node 22, зависимости каталога `server/timeweb`, Application Default Credentials вне git и отдельные read-only права на **явно выбранные** источники: для полного режима — Firebase Auth, Firestore и Storage; для `metadata` — Auth и Firestore; для `storage` — Storage. Auth читается через официальный REST `projects.accounts:batchGet` с Google OAuth bearer token в памяти: пользовательский ADC не требует сервисного ключа, но фактические IAM-права и OAuth scope надо подтвердить живым чтением. Ответ Auth нормализуется к полям Firebase Admin `UserRecord`; хеши/соли не копируются. Для Firestore используется официальный REST `documents.list` с `showMissing=true`: он возвращает исходные `integerValue`, `doubleValue`, `timestampValue`, `referenceValue`, `bytesValue`, `geoPointValue`, вложенные map/array без преобразования в JavaScript числа или даты. Запросы страниц ограничены 25 документами. Реальное чтение может стоить денег; лимиты для выбранного режима обязательны. Прежде чем запускать инструмент на рабочем проекте, надо отдельно подтвердить объём и стоимость.

Стандартный `gcloud auth application-default login` требует широкий OAuth scope `cloud-platform` (в интерфейсе Google он описан как доступ на просмотр и изменение данных). Узкие IAM-роли ограничивают действия в проекте CLRS, но не заменяют осознанного согласия владельца на сам OAuth-доступ. Не подтверждать такой вход автоматически и не хранить полученные credentials в репозитории.

После выдачи `roles/serviceusage.serviceUsageConsumer` на исходный проект локально установить его как quota project командой `gcloud auth application-default set-quota-project chatapp-4e347`. Иначе Auth REST может считать потребителем API OAuth-проект самого gcloud и вернуть `SERVICE_DISABLED`; установка quota project не расширяет права на данные. До экспорта подтвердить доступ ограниченным `probe-firebase-access.mjs` — он не выводит содержимое ответов.

Ключ архива — **32 случайных байта** в файле за пределами репозитория, доступном только владельцу (`0600`). Он не должен попадать в чат, APK, git или ZIP исходников. Выходной архив тоже должен быть вне репозитория. Пример формы запуска с заглушками:

```sh
node export-firebase-encrypted.mjs \
  --project PROJECT_ID --confirm-project PROJECT_ID \
  --bucket BUCKET_NAME --confirm-bucket BUCKET_NAME \
  --out /private/location/firebase.clrsenc \
  --key-file /private/location/export.key \
  --max-auth-users 10000 \
  --max-auth-list-pages 20 \
  --max-firestore-collections 100000 \
  --max-firestore-references 1000000 \
  --max-firestore-list-pages 200000 \
  --max-storage-objects 100000 \
  --max-storage-list-pages 10000 \
  --max-storage-bytes 10000000000 \
  --confirm-read-cost
```

Числа в примере **не оценка CLRS**. Их выбирают после инвентаризации проекта. Отдельный лимит страниц Auth ограничивает запросы даже при пустых страницах с новыми токенами. При превышении любого лимита или ошибке чтения инструмент останавливается, удаляет неполный архив и не публикует его под конечным именем. Локальные синтетические тесты проверяют шифрование, сохранение типов, потомков отсутствующего документа, разрыв потока объекта и обнаружение повреждения архива. Полная выгрузка может быть слишком большой для одного прогона: `--scope storage --storage-prefix avatars/` экспортирует только ключи с указанным префиксом; в архиве такой набор явно помечен как **неполный**. Префиксы надо покрывать без пропусков и перекрытий и сверять с отдельной инвентаризацией; один частичный архив не заменяет полную выгрузку.

Для полного режима и `--scope storage` инструмент до подключения к Firebase проверяет свободное место на томе выходного файла: требуется `--max-storage-bytes` **плюс 2 GiB резерва**. Перед скачиванием каждого объекта он повторно проверяет резерв относительно размера этого объекта; при недостатке места прерывает выгрузку и удаляет временный зашифрованный файл. Это не удаляет существующие архивы или другие файлы. Для инвентаризации CLRS от 30.09.2026 (`6 917 630 044` байта Storage) лимит `--max-storage-bytes 7200000000` оставляет около 282 MB на изменение источника и требует минимум `9 347 483 648` свободных байт перед началом. `--max-storage-objects 10000` покрывает 6 472 известных объекта с запасом. При текущих 4,9 GiB свободного места полный запуск невозможен; после освобождения места надо заново проверить `df` и объём источника. Превышение любого лимита остановит экспорт, а не обрежет готовый архив.

Для отдельной выгрузки Auth metadata и всех типизированных Firestore документов без обращения к Storage используйте `--scope metadata`:

```sh
node export-firebase-encrypted.mjs \
  --project PROJECT_ID --confirm-project PROJECT_ID \
  --bucket BUCKET_NAME --confirm-bucket BUCKET_NAME \
  --scope metadata \
  --out /private/location/firebase-metadata.clrsenc \
  --key-file /private/location/export.key \
  --max-auth-users 10000 \
  --max-auth-list-pages 20 \
  --max-firestore-collections 100000 \
  --max-firestore-references 1000000 \
  --max-firestore-list-pages 200000 \
  --confirm-read-cost
```

Проект, bucket и оба подтверждения остаются обязательными для фиксации источника архива; bucket в этом режиме не читается. Лимиты Auth/Firestore и подтверждение стоимости чтения обязательны, лимиты Storage можно опустить. `--storage-prefix` с `metadata` запрещён. В архиве нет списка, метаданных или байтов Storage; в заголовке `scope: "metadata"`, `completeSource: false`, `storagePrefix: ""`. При свободном месте менее 7 ГБ этот режим исключает самый тяжёлый поток Storage, но объём Auth и Firestore тоже зависит от проекта: перед запуском нужен запас места для зашифрованного файла. Firestore-документы могут содержать личные данные и ссылки на файлы, поэтому архив требует той же защиты, что и полный. Это завершённый зашифрованный файл, но **частичный снимок источника**: [импортёр CLRSX2](IMPORT_PREPARATION.md) отвергает его до первой записи. Для пробного импорта и сверки файлов нужен полный архив с `--scope all` (режим по умолчанию).

Формат `CLRSX2`: независимые AES-256-GCM кадры с уникальными nonce, привязанными к порядку кадров; содержимое шифруется **до записи на диск**. Последний проверяемый кадр отмечает завершение. Экспорт создаёт временный шифрованный файл с правами `0600`, затем атомарно публикует готовый архив без перезаписи существующего. Потоковый читатель `readEncryptedArchive()` находится в `encrypted-archive.mjs`. Если процесс аварийно завершится без обработки ошибки, может остаться файл `.partial-*`: это только шифротекст, но его нельзя считать готовым архивом.

Снимок Firebase **не является согласованным срезом**, пока пользователи продолжают писать данные: Auth, Firestore и Storage читаются последовательно. Для финального переноса понадобится окно заморозки записей или инкрементальная синхронизация и повторная сверка. Объекты Storage скачиваются по зафиксированному `generation`; если они изменятся до чтения, экспорт прервётся вместо тихой подмены. Хеш SHA-256 сохраняется для каждого объекта, размер и доступный MD5 проверяются при выгрузке. Ссылки Firebase download tokens остаются только внутри шифрованных метаданных/документов и потребуют отдельного переназначения при импорте.

Для переноса входа нужны отдельно разрешённые hash/salt и параметры Firebase Scrypt либо временный Firebase Auth bridge. Инструмент не экспортирует их и не подтверждает возможность бесшовного входа. После получения доступа сначала выполнить пробный экспорт, проверить архив и сравнить с новой стороной; только потом готовить переключение приложения.

Из готового **полного** архива можно сначала создать новый HMAC-манифест локально, без повторного чтения Firebase и без записи расшифрованных документов/файлов на диск:

```sh
node manifest-from-archive.mjs \
  --archive /private/location/firebase-full.clrsenc \
  --key-file /private/location/export.key \
  --hmac-key-file /private/location/manifest.hmac.key \
  --out /private/location/firebase-full-manifest.json
```

Этот манифест описывает именно скачанный архив. Он не является независимой проверкой актуального Firebase и не превращает последовательную выгрузку в согласованный снимок. Сопоставление со старым манифестом выявляет изменения между чтениями; перед финальным переключением нужна отдельная синхронизация. Для совместимости с прежним schema-v2 манифестом типизированные значения преобразуются только в памяти так же, как их представлял Firebase Admin SDK. Точные int64-строки остаются в зашифрованном архиве; потенциальная потеря точности в HMAC-представлении отмечается агрегированным `diagnostics.unsafeIntegers`. Частичные архивы, неподдержанные типы и неверные кадры отвергаются. Новый манифест создаётся с правами `0600`, вне репозитория, без перезаписи существующего файла.

Готовый **полный** архив можно проверить локально без записи расшифрованных данных на диск и без обращения к Firebase/Timeweb:

```sh
node verify-export-manifest.mjs \
  --archive /private/location/firebase-full.clrsenc \
  --key-file /private/location/export.key \
  --manifest /private/location/firebase-manifest.json \
  --hmac-key-file /private/location/manifest.hmac.key
```

Проверка читает AES-GCM кадры, конечную отметку, порядок и счётчики записей, SHA-256 каждого объекта и сравнивает HMAC-отпечатки Auth UID, путей Firestore, ключей Storage, размеры и доступные MD5 с исходным манифестом. Вывод содержит только агрегированные различия и SHA-256 файлов. Код `2` означает, что аутентифицированный архив отличается от прежнего инвентарного снимка; при продолжающихся записях в Firebase это возможно и не доказывает повреждение. Значения полей документов Firestore этим сравнением не сверяются, поскольку инвентаризация и архив используют разные представления типов. Парольные хеши и итоговая согласованность снимка остаются отдельными ограничениями.

Локальная проверка без доступа к данным:

```sh
node --test test/export-encrypted.test.mjs
node --check encrypted-archive.mjs
node --check export-core.mjs
node --check export-paths.mjs
node --check export-firebase-encrypted.mjs
```

Первоисточники: [Auth projects.accounts:batchGet](https://docs.cloud.google.com/identity-platform/docs/reference/rest/v1/projects.accounts/batchGet), [Firestore documents.list](https://docs.cloud.google.com/firestore/docs/reference/rest/v1/projects.databases.documents/list), [Firestore listCollectionIds](https://docs.cloud.google.com/firestore/docs/reference/rest/v1/projects.databases.documents/listCollectionIds), [Cloud Storage object generation](https://docs.cloud.google.com/storage/docs/metadata), [Firebase Admin ADC](https://firebase.google.com/docs/admin/setup).

## Durable segmented export after an interrupted large download

`export-firebase-segmented.mjs` consumes an already sealed metadata export and
downloads Storage with bounded prefetch (default/max 4). Every object is a private
0600 encrypted CLRSX2 shard, with a fresh random GCM header and its own authenticated
completion marker, exact generation/metadata identity, byte count and SHA-256.
Its name contains only a keyed fingerprint. Decrypted bytes never touch disk.
Interrupted ciphertext is retained as `.incomplete-*`; it is never imported or
reused. Completed shards are re-read and verified before reuse. Changed generation,
size, checksum, metageneration or other metadata selects a new shard. Corrupt cache
files are retained with `.rejected-*`, never accepted as complete.

First seal a fresh `--scope metadata` export with the existing explicit read caps
and `--max-firestore-concurrency 8`. Then run the segmented exporter with the same
source confirmations, bounded caps and private key, adding:

```text
--metadata-archive /private/fresh-metadata.clrsenc
--out /private/bundle/full.clrsenc
--max-storage-prefetch 4
```

The existing parent directory must be outside Git. The shard directory is 0700.
The disk preflight retains the 2 GiB reserve and reserves the unread part of the
same total Storage byte cap after fully verified reuse. Concurrent jobs additionally
reserve their combined expected bytes before downloading. Do not fill that reserve
with unrelated builds. A failure stops new jobs and drains the active jobs; already
sealed shards remain reusable without another Auth/Firestore pass.

The final `full.clrsenc` is an encrypted, authenticated index of all shards. A second
Storage inventory must exactly match the generation/metadata identities captured
before downloading, or publication is refused. Retry against a fresh inventory;
unchanged sealed shards are reused. Keep the index **and its entire shard directory**
together. No second multi-gigabyte copy is created. Old standalone CLRSX2 archives
and their reader contract remain supported.

`readEncryptedArchive` and `scanImportArchive` expand a sealed index as one logical
source stream. They authenticate the index's end before exposing data, reject missing,
unsafe, duplicate, corrupt, mismatched or trailing shards, and expose the final logical
end only after every shard's GCM frames, pinned ciphertext hash and aggregate counts
match. `scanImportArchive` also checks each object's plaintext SHA and size as before.
`archiveSha256` for a bundle is the composite SHA-256 of the index ciphertext followed
by listed shard ciphertext in index order. This same value binds manifest creation,
verification, dry-run and stage proofs; it is not the hash of the small index file alone.

The metadata source remains live during the capture. The final logical source states
`snapshotConsistent:false` and `finalSyncRequired:true`. A verified full backup proves
coverage/integrity of captured data; it does not prove a consistent cutover snapshot,
successful server migration or existing-user login. A final delta/sync and real
application scenarios remain required before switching production.
