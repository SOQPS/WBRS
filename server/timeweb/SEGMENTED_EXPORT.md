# Защищённый полный экспорт с повторным использованием скачанных файлов

Это только чтение Firebase и локальная зашифрованная копия. Импорт в Timeweb,
переключение приложения и проверка входа существующих пользователей — отдельные
шаги. Парольные хеши в эту выгрузку не входят; для них используется отдельный
защищённый credential bundle.

Все пути ниже — примеры вне Git. Ключ содержит 32 случайных байта и имеет права
`0600`; родительский приватный каталог и каталог shards — `0700`. Значения
`PROJECT_ID` и `BUCKET_NAME` заменяются явно подтверждённым источником. Нужны
Node 22, зависимости `server/timeweb` и ранее подтверждённый ADC-доступ.

| Артефакт | Назначение |
| --- | --- |
| `/private/fresh-metadata.clrsenc` | Завершённый Auth/Firestore metadata shard |
| `/private/bundle/metadata.clrsenc` | Его hard link; второго экземпляра данных не создаётся |
| `/private/bundle/storage-<HMAC>.clrsenc` | Отдельный завершённый encrypted Storage shard |
| `/private/bundle/full.clrsenc` | Финальный encrypted index, связывающий все shards |
| `/private/export.key`, `/private/manifest.hmac.key` | Приватные ключи; отдельно от исходников/APK/ZIP |
| `/private/full-manifest.json` | Манифест количества, HMAC-идентичностей и связей |

Сначала создайте и завершите свежий metadata shard:

```sh
node export-firebase-encrypted.mjs \
  --project PROJECT_ID --bucket BUCKET_NAME --scope metadata \
  --out /private/fresh-metadata.clrsenc --key-file /private/export.key \
  --max-auth-users 10000 --max-auth-list-pages 20 \
  --max-firestore-collections 30000 --max-firestore-references 150000 \
  --max-firestore-list-pages 110000 --max-firestore-concurrency 8 \
  --confirm-project PROJECT_ID --confirm-bucket BUCKET_NAME --confirm-read-cost
```

Затем скачайте файлы и создайте полный sealed index:

```sh
node export-firebase-segmented.mjs \
  --project PROJECT_ID --bucket BUCKET_NAME \
  --metadata-archive /private/fresh-metadata.clrsenc \
  --out /private/bundle/full.clrsenc --key-file /private/export.key \
  --max-auth-users 10000 --max-auth-list-pages 20 \
  --max-firestore-collections 30000 --max-firestore-references 150000 \
  --max-firestore-list-pages 110000 --max-firestore-concurrency 8 \
  --max-storage-objects 10000 --max-storage-list-pages 10000 \
  --max-storage-bytes 7200000000 --max-storage-prefetch 4 \
  --confirm-project PROJECT_ID --confirm-bucket BUCKET_NAME --confirm-read-cost
```

После прерывания повторяется только вторая команда с теми же ключом, metadata
и shard-каталогом. Уже завершённые shards перечитываются с проверкой GCM, размера,
SHA/MD5 и полной metadata-идентичности. Generation, size, checksum, metageneration
или изменившиеся metadata требуют нового shard. `.incomplete-*` никогда не
используются как завершённые данные; `.rejected-*` сохраняют повреждённые файлы
для диагностики. Новые jobs после ошибки не запускаются, активные завершаются.
Успешно созданный финальный index не перезаписывается: его проверяют отдельно.

До скачивания нужен свободный unread byte cap плюс **2 GiB резерва**; после
проверенного reuse из cap вычитаются уже сохранённые исходные байты. Перед каждым
из четырёх jobs проверяется совместный размер активных downloads. Не занимайте
резерв параллельными сборками. Второй копии всех гигабайтов при final seal нет:
index и уже sealed shards вместе составляют архив.

Storage inventory перечитывается перед seal. Если набор объектов или их полные
generation/metadata identities изменились, index не публикуется. Повторная
попытка берёт свежий inventory и переиспользует неизменившиеся shards. Auth и
Firestore при этом не читаются повторно. Живой источник всё равно требует
финальной синхронизации: `snapshotConsistent:false`, `finalSyncRequired:true`.

Проверьте полный архив локально, без нового чтения Firebase и без writes в Timeweb:

```sh
node manifest-from-archive.mjs \
  --archive /private/bundle/full.clrsenc --key-file /private/export.key \
  --hmac-key-file /private/manifest.hmac.key --out /private/full-manifest.json

node verify-export-manifest.mjs \
  --archive /private/bundle/full.clrsenc --key-file /private/export.key \
  --manifest /private/full-manifest.json --hmac-key-file /private/manifest.hmac.key
```

Reader сначала аутентифицирует завершённый index, затем каждый shard; missing,
corrupt, unsafe, duplicate, неправильный source или trailing data отклоняются.
Полный логический `end` выдаётся только после проверки всех ciphertext hashes,
GCM frames, размеров shards и их общих счётчиков. Общий scanner/verifier также
проверяет фактические размеры, plaintext SHA объектов и количество записей.
`archiveSha256`
для segmented архива — SHA-256 index ciphertext и всех listed shard ciphertext
в закреплённом порядке; это общий proof для manifest/dry-run/stage, а не SHA
маленького index-файла отдельно. Храните весь shard-каталог вместе с index.

Манифест, построенный из архива, описывает захваченную копию; он не является
независимым актуальным inventory Firebase. Verified backup не означает, что
миграция завершена или прежние пользователи уже могут войти через Timeweb.

Offline повторное использование Storage ciphertext в новом bundle и граница
финального source sync: [FINAL_SOURCE_SYNC.md](FINAL_SOURCE_SYNC.md).
Порядок восстановления текущего pinned FULL: [FULL_SNAPSHOT_RESTORE.md](FULL_SNAPSHOT_RESTORE.md).
