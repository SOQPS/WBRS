# Подготовка read-only экспорта Firebase

Статус: **локально проверенный инструмент, без запуска на реальном Firebase и без импорта в Timeweb**. Он не делает записей в Firebase или Timeweb. По умолчанию `export-firebase-encrypted.mjs` читает Auth metadata, типизированные Firestore документы со всеми подколлекциями (включая под отсутствующими родительскими документами) и байты/метаданные объектов Storage. Исходные UID, ID документов, пути и имена объектов сохраняются внутри зашифрованного архива. Парольные хеши и salt намеренно не включены: эта выгрузка сама по себе не переносит возможность входа по старому паролю.

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

Локальная проверка без доступа к данным:

```sh
node --test test/export-encrypted.test.mjs
node --check encrypted-archive.mjs
node --check export-core.mjs
node --check export-paths.mjs
node --check export-firebase-encrypted.mjs
```

Первоисточники: [Auth projects.accounts:batchGet](https://docs.cloud.google.com/identity-platform/docs/reference/rest/v1/projects.accounts/batchGet), [Firestore documents.list](https://docs.cloud.google.com/firestore/docs/reference/rest/v1/projects.databases.documents/list), [Firestore listCollectionIds](https://docs.cloud.google.com/firestore/docs/reference/rest/v1/projects.databases.documents/listCollectionIds), [Cloud Storage object generation](https://docs.cloud.google.com/storage/docs/metadata), [Firebase Admin ADC](https://firebase.google.com/docs/admin/setup).
