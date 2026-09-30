# CLRS: безопасное включение нового функционала

Основа — CLRS 1.0.25+39 с последними подготовленными изменениями; release-сборка APK выполнена. Этот документ описывает последовательность включения; сборка не подтверждает публикацию функций или успешную production-проверку.

Обновление на 2026-09-30: read-only проверка подтвердила, что индексы ленты
`posts(status ASC, createdAt DESC)` и регионального поиска уже `READY`.
Ниже сохранён исторический снимок состояния на 2026-09-28; создавать эти
индексы повторно не нужно. Действующие Firestore rules требуют отдельной
проверки приватности перед выпуском: готовые strict/fragment-файлы нельзя
публиковать вместо полного совместимого набора правил.

## Подтверждённое состояние на 2026-09-28

- Проект `chatapp-4e347` / WBRS; доступ `zahardmitriev41@gmail.com` — только `roles/viewer`.
- Данные читаются, но `firebaserules.rulesets.get` и `serviceusage.services.use` запрещены. Права создания/обновления функций, сборки, `iam.serviceAccounts.actAs` и создания индексов отсутствуют.
- `translate.googleapis.com` выключен. Реальный Google перевод через backend не подтверждён.
- В Firestore 22 существующих composite indexes `READY`. `posts(status ASC, createdAt DESC)` отсутствует: безопасный запрос ленты вернул `400 FAILED_PRECONDITION: requires an index`. `tool/security/social.required.indexes.json` — только fragment требований ленты и регионального запроса `users(country, region, __name__)`; он не заменяет эти 22 индекса.
- Две существующие extension-функции активны: `europe-central2/ext-back-up-firestore-to-storage-backupTransaction` и `us-central1/ext-export-user-data-exportUserData`. Не менять их код, конфигурацию, права, триггеры или состояние.
- В существующем Firebase проекте биллинг уже включён. Подключение функций/перевода относится к этому проекту, а не к созданию новой Timeweb-инфраструктуры. Использование API, Functions, Firestore и Storage может оплачиваться существующим проектом; не изменять его тариф или создавать Timeweb ресурсы этим шагом.
- Email-only offline модуль проверен: 9 unit-сценариев и 7 реальных localhost commit/rollback-сценариев. Он затрагивает только `users.email` / `private_users.email`, проверяет версии обоих документов. Эти проверки не являются production-переносом email.

## 1. Получить нужные права и зафиксировать исходное состояние

Для чтения действующих rules владельцу нужно добавить `roles/firebaserules.viewer`; для API-квот — `roles/serviceusage.serviceUsageConsumer`. Эти роли не дают права публикации. Остальные минимальные операции указаны ниже; проверять только изменившийся доступ, не повторять подтверждённые чтения без причины.

Перед первой записью сохранить вне репозитория: текущие ruleset/release IDs и исходники правил, список 22 индексов с именами/состояниями, метаданные существующих функций и IAM, последнюю версию исходников/конфигурации CLRS. Секреты в отчёты не выгружать. Для изменения email нужен свежий зашифрованный снимок затрагиваемых полей обоих документов и plan с update-time guards; прежняя копия только users-root не заменяет такой снимок и не является полной копией Auth/чатов/файлов.

## 2. Подготовить совместимые правила и отдельные индексы

Работать от фактических действующих правил. Внести точечные изменения: запрет самовыдачи ролей и чужих записей; закрытые `private_users`; серверные `_translation_cache`, `_translation_usage`, `_push_deliveries`, `_push_usage`, `_push_fanouts`, `_account_cleanup`; допустимые собственные поля языка/региона, заявки и acceptance markers. Обычный клиент не должен получать email; админский поиск должен читать его разрешённым способом из приватных данных.

**Никогда не публиковать strict draft, rules fragments или required-index fragment целиком.** Учитывать все пересекающиеся `allow`: отдельное `allow false` не отменяет разрешающий wildcard. Проверить разрешённые сценарии текущего/нового APK и отрицательные сценарии на локальном эмуляторе; существующие платежи и данные общих сущностей не менять. Серверный Admin SDK использует IAM и обходит клиентские rules. [Модель Security Rules](https://firebase.google.com/docs/rules), [Firestore IAM](https://docs.cloud.google.com/firestore/native/docs/security/iam).

Создать только недостающий feed index; региональный индекс добавлять только после сверки точной формы и состояния существующих индексов. Не удалять/пересоздавать 22 текущих индекса, дождаться `READY` у нового. Публикация правил и создание индекса — отдельные шаги с сохранённой исходной версией, не побочный эффект deploy функций. После обновления release дождаться распространения правил. [Управление rulesets/releases](https://firebase.google.com/docs/rules/manage-deploy).

## 3. Развернуть только выбранные exports с выключенными флагами

`firebase.translation.json` задаёт отдельный codebase `translation`, Node 22. Выбирать конкретные `functions:translation:<export>`. Не использовать общий `firebase deploy`, `--only functions` или `--only functions:translation`: последние включат и неподключённый Amazon export. Не применять `--force` и не подтверждать удаление посторонних функций. Codebase и точечные selectors сохраняют разделение с чужими функциями. [Codebases](https://firebase.google.com/docs/functions/organize-functions), [точечный deploy и implicit deletion](https://firebase.google.com/docs/functions/manage-functions).

| Блок | Выбранные exports |
| --- | --- |
| Чат, встречи, подарок, обсуждения и реакции | `requestPush`, `pushPrivateMessage`, `pushMeetingMessage`, `notifyPostComment`, `notifyPostLike`, `notifyCommentLike` |
| Дружба и новая встреча в регионе | `notifyFriendRequest`, `notifyFriendAccepted`, `notifyRegionalMeeting` |
| Удаление собственного профиля | `cleanupDeletedProfile` — Auth onDelete v1, не клиентский HTTP endpoint |
| Email новых аккаунтов | `provisionPrivateEmail` + `fenceDeletedPrivateEmail` — доверенные Auth onCreate/onDelete v1; разворачивать парой |
| Сербский перевод | `translateContentGoogle` — только `TRANSLATION_CACHE_HMAC_KEY`, без AWS secrets |

`translateContent` (Amazon) не разворачивать: AWS не подключён. Пример будущего точечного шага после выполнения условий, **не команда, выполненная этой поставкой**:

```sh
firebase deploy --project chatapp-4e347 --config firebase.translation.json --only functions:translation:translateContentGoogle
```

Для push выбирать имена из таблицы, для cleanup — только его export. На этом этапе все флаги ниже остаются false; отсутствие/неверная настройка не должна давать платный запрос или удаление данных.

| Сервер / APK | До подтверждения подключения |
| --- | --- |
| `CLRS_PUSH_ENABLED` | `false` |
| `CLRS_ACCOUNT_CLEANUP_ENABLED` | `false` |
| `CLRS_PRIVATE_EMAIL_PROVISION_ENABLED` | `false`: trusted Auth→private_users и companion deletion fence включать только парой после проверки правил/IAM |
| `GOOGLE_TRANSLATION_ENABLED` | `false` |
| `TRANSLATION_ENABLED` (Amazon) | `false` |
| APK `CLRS_SERVER_SOCIAL_NOTICES` | `false`: сохраняет прежние клиентские inbox-записи дружбы, комментариев и реакций и не добавляет language-write |
| APK `CLRS_PRIVATE_EMAIL` | `false`: включать только после переноса действующих email в `private_users` и проверки совместимых правил |
| APK `CLRS_TRANSLATION_REMOTE_FALLBACK` | `false`, `CLRS_TRANSLATION_ENDPOINT` пуст |

## 4. Проверить сервер и данные на контролируемых аккаунтах

Публикация выключенной функции не проверяет FCM, Translate или cleanup. Перед общим включением выполнить авторизованные реальные запросы и события только от согласованных тестовых UID; не менять чужие аккаунты и не рассылать исторические события.

- Push: сообщение/подарок, обсуждение/ответ/реакция, дружба (отказ → повтор → принятие), публичная встреча в точном регионе; личная встреча не рассылается. Проверить дедупликацию event+HTTP, повтор после сбоя, фон/закрытый APK, язык, mute и переход уведомления. В deployment record указать фактически включённые exports и значения флагов.
- Регион: у legacy профилей country/region почти отсутствуют. Не выводить их автоматически из city. Проверить сохранение выбранного реального региона владельцем профиля; неизвестный регион не участвует в региональной рассылке.
- Cleanup: удалить собственный согласованный тестовый Auth аккаунт с tombstone, убедиться в очистке доказанно принадлежащих UID документов/фото, повторе и восстановлении после сбоя. Flat legacy-файлы без доказанного владельца и общие/финансовые данные остаются в контролируемом review; не удалять их по произвольному URL.
- Перевод: включение `translate.googleapis.com` выполняет владелец с правом enable, затем настоящий RU↔SR и RU↔EN через `translateContentGoogle`; второй одинаковый запрос должен использовать cache. Сохранить оригинал и компактную читаемую Google attribution. Ошибки/таймаут/смена UID не показывают поздний чужой результат. [Cloud Translation IAM](https://docs.cloud.google.com/iam/docs/roles-permissions/cloudtranslate), [ADC](https://docs.cloud.google.com/translate/docs/authentication), [атрибуция](https://docs.cloud.google.com/translate/attribution).
- Email: `CLRS_PRIVATE_EMAIL` остаётся `false` до переноса действующих email и проверки правил. Применять только проверенный email-only plan, затем сверить перенесённые поля и проверить приватную схему: обычный пользователь не получает email, администратор может выполнить поиск. Version conflict любого из двух документов блокирует запись этой пары. Не переносить баланс, роли, подарки, чаты и другие поля вместе с email.

## 5. Включить клиент после серверных доказательств

После готовности совместимых правил и серверных обработчиков выпустить APK с `CLRS_SERVER_SOCIAL_NOTICES=true`: сервер создаёт inbox-уведомления дружбы, комментариев и реакций, клиент не создаёт дублирующие inbox-записи этих событий. Клиент пишет оба `acceptedByUid` атомарно и сохраняет выбранный язык владельца профиля. Старый APK должен пройти согласованный переход без двойных/пропавших уведомлений. Не включать этот клиентский флаг раньше сервера.

`CLRS_PRIVATE_EMAIL=true` включать отдельно, только после успешного переноса email, сверки результатов и проверки правил приватной схемы **и provisioning новых аккаунтов**. Текущий APK не записывает email в `users`, но сам не создаёт `private_users.email`: одного переноса существующих полей недостаточно. До включения проверить новую регистрацию → запись private email → админский поиск. Обычный пользователь не должен получать приватный email через Firestore. В текущей сборке клиентский и новый серверный флаги по умолчанию выключены.

### Email новых аккаунтов: граница и отдельный gate

Два новых server exports используют только доверенные Auth lifecycle события. `provisionPrivateEmail` сверяет текущий `getUser`, берёт email только из **актуального Auth**, не из события/`users`/клиентского payload, и пишет только `private_users/{uid}`: `uid`, нормализованный `email`, служебные `authCreatedAtMs` и `authCreateEventHash` — SHA256 доверенного platform `context.eventId`. Только повтор того же create event с совпадающей metadata/email идемпотентен и не делает новую запись. Другой create event существующего UID требует manual review даже при одинаковой SDK-секунде/email; private запись без полного event fence также не принимается автоматически. Несовпадение email/UID/schema/generation/event не перезаписывается и фиксируется безопасным review-кодом без email/UID. Это не массовая сверка существующих Auth аккаунтов; legacy Auth без private email требует отдельного проверенного переноса/сверки. Мигрированный email доступен администратору по своей закрытой схеме, но `onCreate` не присваивает ему event fence без owner review.

`fenceDeletedPrivateEmail` при прямом Auth/Console удалении атомарно убирает свою private email и оставляет **служебный marker без email** `{uid, authCreatedAtMs, status: 'auth_deleted'}`; если create event fence уже существовал, его `authCreateEventHash` сохраняется. Creator читает тот же документ в Firestore transaction: поздний create получает read-conflict/retry либо видит marker. Этот marker сохраняется при повторе/переключении флага и **не удаляется generic cleanup**; `status` намеренно отсутствует в его private-field allowlist, а два private metadata поля времени/hash разрешены. При обычном удалении через приложение постоянная защита — сохранённый `users.status=deleted` / `deletionRequestedAt`; private документ своего поколения можно удалить. Cleanup job читается только по реальному `_account_cleanup/{sha256(uid + '\\0' + seconds + ':' + nanoseconds)}` из этого timestamp, не по выдуманному `_account_cleanup/{uid}`. Серверные обработчики не меняют `users`, роли, баланс или общие данные.

**UID reuse — обязательный owner-review gate.** Установленный Admin SDK преобразует Auth creation time через `toUTCString()` и теряет миллисекунды; `authCreatedAtMs` хранит сравнимую metadata, но не является уникальным generation ID. Отдельный trusted create event hash закрывает выявленный сценарий recreate того же UID/email в той же SDK-секунде **до позднего старого delete**: новый create event требует review, не получает `already_provisioned`. Старый delete ничего не пишет, если текущий Auth UID существует. Новый create не преодолевает marker или fence другого create event автоматически, даже если дата стала новее. Общей транзакции Auth+Firestore нет: privileged delete/recreate одного UID, особенно между последним Auth lookup и commit, не поддерживается автоматически и требует ручной проверки владельцем. Старый create retry не доказывает существование прежнего Auth поколения по секундному timestamp; возвращаемую идемпотентность нельзя использовать как разрешение на UID reuse. Не снимать marker/event fence и не переиспользовать UID как часть обычной эксплуатации. Не объявлять эту границу абсолютной ABA-защитой.

Будущий точечный selector (не выполнялся этой поставкой):

```sh
firebase deploy --project chatapp-4e347 --config firebase.translation.json --only functions:translation:provisionPrivateEmail,functions:translation:fenceDeletedPrivateEmail
```

До production enablement нужны: совместимые реальные правила, запрещающие обычному клиенту private email и возврат email в публичный `users`; runtime identity ниже; оба lifecycle exports; согласованные тестовые UID. Сначала при серверном флаге `false` проверить metadata, затем на контролируемом аккаунте включить `CLRS_PRIVATE_EMAIL_PROVISION_ENABLED=true` и доказать новую регистрацию → корректный `private_users.email` → admin email-search → ordinary read denied. Отдельно выполнить direct Auth delete → marker без email → поздний/retry create заблокирован и app-delete → tombstone. Проверить deploy/restart, повтор события и safe conflict reporting. Клиент `CLRS_PRIVATE_EMAIL` до этих доказательств остаётся `false`; никаких production запросов или публикации эта подготовка не выполняет.

Для подтверждённого Google URL включить `CLRS_TRANSLATION_REMOTE_FALLBACK=true` + HTTPS `CLRS_TRANSLATION_ENDPOINT`. Остальные 22 языка остаются на ML Kit; endpoint используется для сербского source/target. Проверить в установленном APK два UID, оригинал/перевод, offline, повтор и смену аккаунта. Закрыть матрицу только фактическими серверными/Android доказательствами, а не mock-тестом или наличием export.

## Runtime IAM: отдельно от deployer

Назначать отдельные runtime identities через `PUSH_SERVICE_ACCOUNT`, `ACCOUNT_CLEANUP_SERVICE_ACCOUNT`, `GOOGLE_TRANSLATION_SERVICE_ACCOUNT`, `PRIVATE_EMAIL_SERVICE_ACCOUNT`, без скачивания JSON-ключа. Ниже — минимальные операции текущего кода; это не утверждение, что права уже выданы.

| Identity | Нужные операции |
| --- | --- |
| Push runtime | `firebaseauth.users.get`; `datastore.databases.get`, `datastore.entities.get/list/create/update/delete`; `cloudmessaging.messages.create` |
| Cleanup runtime | `firebaseauth.users.get`; те же Firestore операции; на существующем bucket `storage.objects.list/get/delete` |
| Private email runtime | `firebaseauth.users.get`; `datastore.databases.get`, `datastore.entities.get/create/update/delete` для transaction-проверок `users`/реального cleanup job и записей только `private_users`; без Auth create/delete/update, FCM, Storage, Translate и secrets |
| Google runtime | `firebaseauth.users.get`; `datastore.databases.get`, `datastore.entities.get/create/update/delete`; `cloudtranslate.generalModels.predict`, `serviceusage.services.use`; `secretmanager.versions.access` только на `TRANSLATION_CACHE_HMAC_KEY` |

Firestore delete требуется для lease/token/разрешённого cleanup, а не удаления всей базы. IAM нельзя считать заменой UID/allowlist проверок в коде; клиентские rules не ограничивают Admin SDK. Runtime не нужны Auth create/delete/update, выдача ролей, управление функциями/IAM, изменение биллинга, создание bucket/индексов/API keys или чтение остальных секретов. Для ready-made ролей возможны `roles/firebaseauth.viewer`, `roles/firebasecloudmessaging.admin`, `roles/cloudtranslate.user`; custom roles предпочтительнее, поскольку эти роли шире перечисленных операций. Secret Accessor выдаётся на один secret, Storage права — на существующий bucket с применимыми условиями. [Firebase product roles](https://firebase.google.com/docs/projects/iam/roles-predefined-product), [Storage permissions](https://docs.cloud.google.com/storage/docs/access-control/iam-permissions), [Secret access](https://docs.cloud.google.com/secret-manager/docs/access-secret-version).

## Owner/deployer IAM: точные отдельные действия

| Действие | Минимальная граница |
| --- | --- |
| Читать правила / использовать API | `roles/firebaserules.viewer`, `roles/serviceusage.serviceUsageConsumer` |
| Создать/обновить выбранные функции | `cloudfunctions.functions.create/update/get/list`, `cloudfunctions.operations.get`; готовая `roles/cloudfunctions.developer` либо custom role |
| Собрать и загрузить исходники | Cloud Build create/read build и права сборочного SA на конкретные source/artifact ресурсы; `roles/cloudbuild.builds.editor` — готовая более широкая роль |
| Привязать runtime/build SA | `iam.serviceAccounts.actAs` только на выбранных SA (`roles/iam.serviceAccountUser` на этих SA, не всём проекте) |
| Настроить transport invocation | Только нужные `setIamPolicy` на новых HTTP Functions/Cloud Run services; публичный transport допускается потому, что handler проверяет Firebase token, профиль и квоты. Firestore/Auth триггеры не становятся публичными HTTP API |
| Включить Translate API | Владелец: `serviceusage.services.enable` для `translate.googleapis.com`; runtime/deployer не получают право disable APIs |
| Публиковать точечные rules | Читать/test/create ruleset и обновить существующий release: `firebaserules.rulesets.get/create`, `firebaserules.projects.test`, `firebaserules.releases.get/update`; не удалять старые rulesets |
| Добавить индекс | `datastore.indexes.create/get/list`, `datastore.operations.get`; не удалять текущие индексы |
| Подготовить secret / grants | Владелец: создать только cache-HMAC secret, добавить версию и назначить доступ выбранному Google SA. Deployer получает только необходимые metadata/config права, runtime — access на этот secret |
| Выполнить email plan | Отдельная доверенная identity с Firestore get/transaction/create/update для двух целевых документов; не выдавать её мобильному приложению |

Зависимости платформы (Cloud Build/Functions service agents, Eventarc/Pub/Sub для v2 событий) проверяются владельцем при выборе существующих runtime/build identities; service-agent роли не выдаются человеку или обычному runtime. Право deploy не означает права назначать IAM самому себе. [Functions deployment roles](https://docs.cloud.google.com/functions/docs/reference/iam/roles), [build process](https://docs.cloud.google.com/functions/docs/building), [Rules IAM](https://docs.cloud.google.com/iam/docs/roles-permissions/firebaserules).

## Rollback

1. Остановить только новый блок: выключить соответствующие серверные флаги и восстановить совместимый APK с прежними client flags/пустым translation URL. Для дружбы, комментариев и реакций согласовать сервер/клиент одновременно, чтобы прекращение server-inbox не оставило новый APK без уведомлений.
2. Вернуть сохранённую версию **только выбранных CLRS exports** с выключенными флагами. Не удалять функции путём исчезновения exports из исходника и общего deploy; никогда не отключать две существующие extensions.
3. Откатить конкретный rules release к сохранённому immutable ruleset после проверки совместимости. Не заменять его draft-файлом. Новые безопасные индексы можно оставить; 22 исходных индекса сохранить.
4. Откатить email только через проверенный парный version-guarded plan. Не затирать новые изменения пользователей. Не возвращать private email в публичное чтение без действующей защиты; конфликт отправляется в review.
5. Сохранить delivery/cleanup/translation leases, журналы и зашифрованные snapshots. Не удалять свежие дедупликационные записи, не запускать массовый replay и не восстанавливать уже удалённый Auth аккаунт автоматически. Уже доставленный FCM и удалённый файл нельзя отменить переключением флага: для разрешённого удаления нужны отдельный проверенный file backup и restore с preconditions.

Результат rollback фиксировать по списку CLRS exports, правилам, данным тестовых UID и состоянию обеих extensions. Непроверенный live этап остаётся открытым в матрице.
