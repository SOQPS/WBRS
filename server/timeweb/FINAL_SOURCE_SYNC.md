# Финальный source sync с повторным использованием encrypted shards

Проверен FULL от30.09.2026 с composite SHA `b21387e6493e0e2387f219909d4fec81604f4a12ead7d0997de192015bad867e`: Auth8 208, Firestore70 486, Storage6 478 /6 932 196 752 bytes. Это сохранённое состояние меняющегося источника; `snapshotConsistent=false`, `finalSyncRequired=true` не снимаются одним новым экспортом.

## Реализованный offline seed

`seed-segmented-storage.mjs` не обращается к Firebase, MySQL, Timeweb или S3. Он полностью аутентифицирует old sealed FULL, сверяет explicit source+composite SHA, затем повторно проверяет ciphertext SHA/GCM/end/plaintext SHA/MD5/source identity каждого Storage shard до hardlink. Пути canonical/private/owned/non-symlink, source/new directories разные, FS один. Destination должен отсутствовать; copy/overwrite/chmod/truncate отсутствует. До создания каталога и каждой ссылки сохраняется2GiB свободного места.

После ссылок helper снова полностью читает исходный FULL и проверяет прежний composite SHA и encrypted index SHA: original snapshot неизменён. Пишутся только directory entries нового private0700 каталога; metadata/index/ключи не копируются. Cache без нового sealed `full.clrsenc` не является завершённым источником и не импортируется. Hardlinks экономят место, но не создают независимую копию на случай отказа исходного диска.

Пример **только offline seed** из checkout на Node22; SHA составной, а не `sha256sum full.clrsenc`:

```sh
node server/timeweb/seed-segmented-storage.mjs \
  --archive /secure/firebase-segmented-original/full.clrsenc \
  --key-file /secure/export.aes.key \
  --out-dir /secure/firebase-segmented-final-cache \
  --project chatapp-4e347 --database '(default)' \
  --bucket chatapp-4e347.appspot.com \
  --confirm-archive-sha256 b21387e6493e0e2387f219909d4fec81604f4a12ead7d0997de192015bad867e
```

Заменить только private canonical пути вне Git; секреты не подставлять строками. Bundled Node22: `work/toolchains/node-v22.23.2-darwin-arm64/bin/node`. Полные локальные проверки читают ciphertext и удерживают максимум один64MB object buffer; plaintext не сохраняется. Interrupted seed сохраняет unsealed cache, existing destination новым seed не перезаписывается.

## Fresh FULL — отдельный следующий запуск

1. Сохранить recovery set/keys/receipts из [FULL_SNAPSHOT_RESTORE.md](FULL_SNAPSHOT_RESTORE.md). Старый metadata/index не менять и не удалять.
2. Отдельно получить **новый** metadata-only Auth/Firestore archive на новый private0600 путь с прежними проверенными source/caps/sparse-parent traversal/concurrency8. До source чтений проверить read-access и ограниченный бюджет; source mutations не выполнять. Baseline≈90k bounded queries требует отдельного запуска и времени.
3. Запустить существующий `export-firebase-segmented.mjs` с новым metadata, тем же AES key и `--out /secure/firebase-segmented-final-cache/full.clrsenc`. Fresh Storage inventory выбирает совпадающие name+generation+size+полная metadata identity shards, повторно проверяет и reuse. Changed/new files получают новые sealed shards, prefetch≤4. Deleted source objects не включаются в новый index; old ciphertext остаются в original/cache.
4. Storage inventories до/после должны совпасть по точным identity. Drift прекращает index publication, completed shards сохраняются. Для нового FULL заново создать HMAC manifest тем же отдельным manifest key, выполнить полный verifier всех shards и сохранить **новые** counts/timestamps/manifest SHA/composite SHA. Старый b213 SHA не подтверждает новый источник.

Headroom = cap7.2GB минус только проверенные совпадающие source bytes плюс2GiB reserve. Дополнительное место нужно для fresh metadata/index/manifest и changed-file ciphertext, а не второй полной копии7GB. При массовой смене metadata reuse может не сработать; disk guard останавливает задачу. Sealed inode вручную не редактировать: hardlink разделяет содержимое с оригиналом; exporter valid links не перезаписывает.

Адресные synthetic tests: changed generation +added/deleted object (скачиваются2 новых/изменённых, reuse1), corrupted/missing/trailing shard, signed index identity/path traversal, source/shard/parent symlink, private mode, wrong source/key/SHA,2GiB reserve/interrupted unsealed cache, source mutation during links. **Реальный seed/fresh source export этим этапом не запускался**: ongoing raw stage использует pinned b213.

## Cutover и осознанный target conflict

Fresh FULL не атомарен: Auth, Firestore и Storage читаются последовательно. Перед окончательной сверкой нужна отдельная граница source writes, при которой старые APK/серверы не меняют источник до окончания проверки и переключения. Helper не отключает source writes и не включает production routes.

Под этой границей требуется fresh Auth credential export/hashConfig и exact UID/status/providers/validSince binding с новым FULL. Одинаковые UID/counts не доказывают свежесть password hash, claims или account status. Независимая повторная source inventory/HMAC сверка должна подтвердить отсутствие поздних изменений. Readers продолжают сообщать `finalSyncRequired=true`; реальный cutover proof сохраняется отдельно.

**Current importer не является incremental updater.** Другой payload/hash по тому же UID/path вызывает конфликт; S3 quarantine key зависит от source path, а не generation. Просто применить новый FULL к старому stage нельзя. До target delta нужен отдельный план: old/new HMAC comparison, точные added/changed/deleted записи, сохранение target snapshot/receipts, transactional reconciliation либо уже подготовленное пустое назначение. Current five grants, empty-domain guards и immutable row checks не ослаблять; automatic overwrite/DELETE отсутствует.

После target delta требуются полные SQL/S3 readback, controlled login прежним паролем, проверки профиля/фото/исторического чата и встречи, isolation и rollback порядок. Firebase сохраняется до этого proof; переезд не объявляется законченным.
