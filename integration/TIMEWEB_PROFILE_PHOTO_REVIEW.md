# Native public profile photo: association review preparation

Сейчас это **pure review plan**, не native media route и не показ фотографий в
приложении. Никаких SQL/S3/cloud запросов, записей, DDL, grants, deploy или включения
флагов нет. `runtime_people.py`, `runtime_read_http.py` и `RUNTIME_READS.md` не изменены.

## Подтверждённый пробел

`server/timeweb/MEDIA_PROMOTION.md` прямо отделяет ready `media_objects` от связей
`profile_photos`. Promotion сохраняет owner/purpose/source path/hash, но не роль
аватара, image ID или порядок. `purpose='profile'` объединяет точные profile и
gallery references, Auth.photoURL и старые chat/author snapshots. Поэтому первый
готовый файл владельца, похожее имя, дата создания или Auth.photoURL не доказывают
его главное фото. В текущем source нет projector/writer `profile_photos`, кроме
schema и smoke fixture; live содержимое таблицы здесь не проверялось.

Existing legacy `/v1/media` использует разрешённый own-profile либо conversation
context и immutable snapshot authority. Он не проверяет native public-directory
visibility и не является публичным native разрешением на другую анкету.

## Новый ограниченный план

`server/timeweb/python-stand/profile_photo_review.py` принимает только private
server-side evidence: exact active account, retained canonical raw, pinned source
root/gallery documents с SHA256, bounded ready-media/storage rows, доказанно полный
gallery input, явные existing associations и при необходимости reviewed ID order.
Все входы только проверяются; они не становятся HTTP authority.

Original avatar выбирается **только** из typed `users/{uid}.profilePic`.
`profilePicThumb`, Auth.photoURL, сторонний URL или готовый файл того же владельца
его не заменяют. Root payload digest должен совпасть с canonical retained raw,
а source document — с exact `users/{uid}`. Existing native raw `{}`, missing/null/
empty original, неполный gallery input или неизвестные existing associations
дают `unchanged`, без кандидатов на запись.

Gallery originals берутся только из точных `users/{uid}/images/{id}.url`.
Каждый source payload/digest проверяется; target image ID обязан помещаться в
существующий `VARCHAR(191)`. Все source URL разбираются целиком только для pinned
Firebase/gs bucket. Query/download token не сохраняется. External/S3 URL,
traversal, wrong bucket, malformed types, дубликаты/конфликты и частичное ready
mapping дают отказ целого плана; basename/substring guessing отсутствует.

Для каждого original требуются exact ready `media_objects` owner UID,
`purpose='profile'`, media ID, immutable imported key, legacy path, MIME, size и
content SHA. Они сравниваются с copied `legacy_storage_objects` source bucket/path,
source/target SHA, size, metadata MIME и copy marker. Дополнительные неподтверждённые
objects не допускаются. Контракт ограничен 50 фотографиями; превышение не обрезается.

Schema `profile_photos` уже представляет original avatar через `is_primary=1`,
`ordinal=0`, optional exact `firebase_image_id` и FK `(media_id,uid)` на media owner.
Если current original существует без отдельного images child, image ID остаётся
NULL. Source child documents не хранят числовой ordinal. Для нескольких gallery
documents требуется явно reviewed последовательность exact image IDs; без неё
план остаётся `unchanged:gallery_order_unreviewed`. Primary всегда идёт первым,
но хронология остальных не придумывается. Duplicate photo paths не объединяются
молча. Already matching existing rows — NOOP, конфликтующие rows не перезаписываются.

План содержит immutable association rows, source/media digest pins и fingerprint.
`summary()` безопасен для логов: только state/reason/counts, без UID/URL/raw/object
key. Полный план приватный, `repr` не раскрывает evidence. **Reviewable не означает
applied, current public eligibility, gallery readiness или разрешение скачать файл.**

Thumbnail pairing пока не проектируется: promotion хранит самостоятельные thumbnail
objects как ready rows и оставляет `thumbnail_key=NULL`; schema не содержит отдельный
thumbnail content hash. Нельзя вписать один лишь соседний key или выбрать thumbnail
по имени. Следующий thumbnail контракт должен связывать exact root/image fields и
полные проверенные ready original/thumbnail records.

## Следующий конкретный кодовый шаг

Подготовить отдельный bounded apply/readback projector вокруг этого плана:
из существующего authenticated completed source извлечь **все** gallery records
одного пользователя, подтвердить source pin/completion/order, reread нужные ready
rows и canonical retained raw, затем private reviewed plan/receipt. В одной
SERIALIZABLE transaction проверить exact UID, account/source hashes, media bindings
и empty/already-matching `profile_photos`; только approved association INSERT,
полный bounded readback и durable receipt. Не overwrite/upsert неизвестные rows.
Lost COMMIT требует receipt-bound reconcile на свежем соединении, без повторного
INSERT. Этот apply этап здесь не реализован и не запущен. Требование трёх фото для
новой регистрации не заменяется count кандидатов или source avatar.

## Минимальный предлагаемый native media read контракт

Existing native `strict-tables-v1` runtime principal не имеет media/source table
rights; existing five-table legacy media principal не читает `profiles` и
`device_sessions`. Его нельзя использовать как proof native public visibility.
До интеграции нужен явно reviewed **read-only** media transaction contract с
SELECT на ровно `accounts`, `device_sessions`, `profiles`, `profile_photos`,
`media_objects`, `legacy_storage_objects`, `legacy_source` и native token verifier.
Это предложение, не grant template/новый permission flag и не выданные права.
Existing provider database privileges сами по себе не заменяют этот review.

В одной bounded READ ONLY transaction: current token/session/account proof до и
после; byte-exact actor/target; existing strict `profile_visibility.py`; exact
primary `profile_photos` association и ready profile object того же владельца.
JOIN использует indexed equality плюс binary identity comparison. Primary query
ограничена LIMIT 2: отсутствие/неоднозначность fail closed. Key и hashes проверяются
через exact legacy storage/source provenance. Никаких client UID как identity,
client object key или raw URL в response. Native uploads/new object prefixes
этим immutable-import contract не поддерживаются.

После SQL разрешён только existing GET-only `PrivateMediaS3` adapter с отдельными
read credentials, свежими private bucket/type/ACL/policy checks, bounded spool,
полной size/SHA verification. До первых response bytes повторить native session,
account, public visibility и тот же association/object context в новой transaction.
Предлагаемый opaque descriptor — actor/target/association/context/purpose-bound,
с отдельным cursor subkey и сроком **не более 60 секунд**, без S3/Firebase URL или
download token. Private no-store byte lease, закрытие при cancel/disconnect и
ограничение времени/числа downloads обязательны; никакого public bucket/presign.
Mid-stream immediate logout/visibility revocation нельзя заявлять до отдельного
проверяемого streaming policy. HTTP/DTO wiring согласуется после projector и этого
permission/query контракта; текущий `avatar:null/mediaReady:false` сохраняется.

## Адресная проверка

`test_profile_photo_review.py`: 8 pure synthetic cases прошли. Они проверяют
original-only выбор, null/native/unknown NOOP, source/current hash и A/B UID,
source/account unavailable, whole URL/type refusal, ownership/purpose/MIME/size/
hash/copy marker, reviewed gallery ordering, ambiguous/unmapped/bounded inputs,
existing-row conflict и отсутствие изменения входов. Это не SQL apply, S3 bytes,
actual user mapping, live API privacy, promotion activation или device proof.
