# Native admin: bounded read-only список пользователей

Подготовлен отдельный `RuntimeAdminUsersService` в `server/timeweb/python-stand/runtime_admin_users.py`. Он читает настоящие текущие canonical `accounts`/`profiles` через существующий `RuntimeMutationStore`, pool, verified native session и READ ONLY transaction. Общие HTTP/routes/grants/flags не изменены. Этот этап не создаёт администраторов, не подтверждает выданную роль и не означает готовую админку или полный cutover.

В рамках реализации были только source edits и focused synthetic tests. DB/cloud/SQL/DDL/GRANT/deploy не выполнялись; реальных пользовательских email, UID, паролей или источника ролей в fixtures/doc нет.

## Authority

Actor определяется существующим native session verifier, который проверяет current `device_sessions` + canonical account: exact UID/session, expiry, revoked/token_version, disabled и lifecycle. Store повторяет session/account proof перед возвратом результата из той же READ ONLY transaction. Переданное клиентом имя, email, UID, `admin=true`, Firebase/raw claim или старый public DTO не является доказательством доступа.

Сервис дополнительно делает exact indexed `role_grants(uid,role)` lookup до построения страницы и после него, с `FOR SHARE`, LIMIT 2 и byte-exact UID/role equality. Нужна ровно одна текущая строка `role='admin'`, `revoked_at IS NULL`, `verified_source` ровно из canonical schema allowlist: `firebase_claim`, `approved_uid`, `admin_grant`. Moderator/author, отсутствующая/повреждённая/дублированная строка, неизвестный source или отозванная роль закрывают чтение. Post-check сохраняет exact pre-check source. Это проверка существующего canonical grant, а не bootstrap по email и не подтверждение raw claims.

Shared lock удерживает role row до завершения transaction; параллельный revoke ждёт её окончания. После завершения revoke следующий запрос, включая next page с ранее выданным cursor, обязан снова пройти текущую role/session проверку. Cursor не заменяет authority. Это гарантия границы read transaction; мгновенное прекращение уже отправленного HTTP body здесь не реализовано и не заявляется. HTTP owner должен использовать прежние native guards и `Cache-Control: no-store`.

## Вход и отдельный admin DTO

Server service method:

```python
users(identity, *, access_token, query=None, limit=30, cursor=None)
```

Один `query` — literal prefix по canonical fullName **или** email. None/пустой/whitespace-only query означает список без поиска. Непустой query после `strip().casefold()` имеет минимум 2, максимум 100 Unicode code points и 400 UTF-8 bytes; исходный input ограничен теми же maxima. Controls, DEL, surrogates и нестроковый query отклоняются. Casefold/trim нормализованный scope точно связан с cursor. Prefix использует `startswith`, без regex, SQL LIKE wildcard, arbitrary contains или раздельных несвязанных fullname/email queries. `%` и `_` — обычные символы. Выходные оригинальные строки не нормализуются; leading whitespace в хранимом имени остаётся частью literal prefix.

`limit` — exact int от 1 до 30, без boolean coercion. DTO намеренно отличается от public profile:

```json
{
  "kind": "canonical-admin-users",
  "ordering": "uid_binary_asc",
  "items": [
    {"uid":"synthetic-user","email":null,"fullName":null,"age":null,"lifecycle":"active","disabled":false}
  ],
  "nextCursor": null
}
```

Каждый item содержит только `uid`, `email`, `fullName`, nullable `age`, `lifecycle`, boolean `disabled`. Для этого admin списка доступны также canonical blocked/deleted/disabled аккаунты; public visibility/onboarding не используются как фильтр админского чтения. Source raw/hash/password/credential/session/role details, финансовые поля, media URLs и admin secrets отсутствуют в selection и response.

Indexed LEFT JOIN `profiles` использует обычный exact UID equality плюс binary comparison. Отсутствующая profile row, nullable age/email/fullName и пустое имя сохраняются честно: unknown остаётся NULL, пустая строка остаётся пустой. Source completeness/104 неподдержанных historical age/height records не реконструируются из архива; сервис не читает raw и не угадывает значения. FullName ограничен 1000 code points/4000 bytes; более длинное current значение становится недоступным (`null`) через SQL CASE, без усечения. Email ограничен canonical `VARCHAR(320)` и валидируется как normalized строка; malformed row/тип/age/lifecycle/disabled закрывает целую страницу, без silent coercion.

## Bounds, поиск и продолжение

В нынешней schema есть UID primary keys для accounts/profiles и indexed exact UID join; full_name search index отсутствует. Поэтому SQL не делает OR/contains/LIKE full-table search. Он получает current кандидатов по возрастающему canonical UID primary-key range, максимум 32 строки за SELECT, с `FOR SHARE OF a,p`. Exact byte order/движение anchor проверяются также в decoder. Offset отсутствует.

Одна service action сканирует максимум 128 кандидатов (до четырёх SELECT), локально применяет literal prefix и выдаёт максимум 30 совпадений. SQL выбирает только поля admin allowlist; имя заранее ограничено SQL CASE. Начальные NULL/email/name профили входят в список без поиска и не выдумывают совпадение при prefix query.

Полный response — максимум 65536 bytes. Перед добавлением item бюджет резервирует максимальный bounded cursor. Строки не режутся; если очередной подходящий item не помещается, cursor указывает на последний уже выданный/просканированный UID **перед** ним. Неуместившийся item остаётся кандидатом следующей страницы. Это же правило используется при достижении limit. Tests проверяют полный проход больших Unicode имён без потери/дублирования UID.

Если достигнут scan bound, `items=[]` и ненулевой cursor допустимы. Это означает «в проверенном ограниченном участке совпадений нет», а не «пользователей по запросу нет». UI должен предлагать следующую страницу явным действием и не запускать неограниченный auto-drain. `nextCursor=null` означает, что текущий keyset scan дошёл до конца. Между запросами accounts/profiles могут изменяться; это current read pagination, не immutable snapshot всего списка.

Cursor использует существующий 32-byte server key `CLRS_LEGACY_READ_CURSOR_KEY_B64` с отдельным HMAC domain `clrs-runtime-current-admin-users-cursor-v1\0` и существующим encrypted `OpaqueReferences`. Он содержит current actor UID, purpose/order, exact normalized query hash, limit, after UID и expiration максимум 300 секунд. Максимальный encoded input — 4096 chars. Чужой UID, другая query/limit, просроченный/future/tampered cursor и cursor из people/legacy domain отвергаются; никакой data/query echo в response или server logs сервис не делает. Каждый новый page request сначала проверяет current admin role, даже до разбора cursor.

## Permission boundary

Shared grant maps и role assignments не изменены. `strict-tables-v1` сегодня **не имеет SELECT на `clrs_staging.role_grants`**, поэтому этот service с такой ролью fail closed. Ни missing privilege, ни email allowlist не приводят к обходу admin query.

Минимальная дополнительная table capability для strict runtime map — только `SELECT ON clrs_staging.role_grants`; accounts/device_sessions/profiles SELECT уже нужны существующему store. Перед реальным расширением потребуется отдельная reviewed exact permission-model/parser: нынешний strict validator намеренно отвергает даже добавленный role_grants SELECT как лишний grant. Просто выдать этот grant нынешнему strict account нельзя: это закроет также старые runtime операции. Новый parser/template/label здесь не добавлен, actual GRANT не выполнялся. SELECT на `mysql.*`, DDL/INSERT/UPDATE на role_grants и новая БД не нужны.

Существующий `provider-database-v1` с ровно `SELECT,INSERT,UPDATE ON clrs_staging.*` уже включает нужное чтение; store заново проверяет этот contract каждой transaction. Это broad database technical role, **не** узкая SELECT-only DB роль. Новый action ограничен READ ONLY callback и SELECT SQL, но не уменьшает права технического пользователя при компрометации сервиса. Выбор permission model и реальные role grants остаются отдельным проверяемым owner/admin действием.

## Адресная проверка и следующая граница

`test_runtime_admin_users` — **12 focused synthetic cases PASS** на настоящем RuntimeMutationStore с MySQL-shaped no-TCP fixture. Проверены current native session/UID/version/disable; exact admin/source/revoked/malformed role; pre/post grant/session отказ без выдачи построенного page; nullable/missing/empty profile и explicit admin redaction; literal casefold prefix без wildcard/contains; 128/32 scan и sparse continuation; 30 rows/64KiB без потери следующего item; cursor A→B/query/limit/domain/tampering/expiry/revoke; schema/type/order bounds; strict missing/extra privilege failure; constructor/default-off gates. Нет широких прогонов или live DB proof. Synthetic SQL fixture не подтверждает actual MySQL parser/permission behavior.

Root интегрирует узкую native HTTP route после review source/service и cursor/query contract. Для живой админки затем нужны проверенная deployed native session, существующий canonical unrevoked admin grant, actual runtime permission model, GET-only/no-store HTTP DTO и separately authorized controlled admin/non-admin/revoke сценарий. Эта подготовка не выдаёт Дмитрию или другим пользователям роль и не публикует список реальных email.

Дополнительно root подтвердил actual MySQL 8.4 parser по verified TLS/hostname: EXPLAIN без ANALYZE для первой/следующей страницы и exact role query; accounts используют PRIMARY index/range, profiles — PRIMARY eq_ref. Два constant-table fixture SELECT подтвердили transport/DTO для обычного и отсутствующего nullable профиля. Реальные пользовательские строки не читались, writes/DDL=0; приватный proof `admin-users-sql-proof-20261002.json` связан с SHA сервиса `9a1c5078613b63e5191e6e7763270759d84c9cf619d84cbe3affb29a4630d402`. Это SQL parser/index proof, не live admin authority или UI acceptance.
