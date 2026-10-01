# Ограниченные пользователи двух runtime сервисов

Подготовлены template/validators/tests; реальные пользователи, GRANT/ALTER USER, browser actions и deploy этим шагом не выполнялись. Только существующая MySQL8.4 `clrs_staging`; новых БД/услуг нет. Migration account с CREATE/REFERENCES и общий SELECT на БД не используются публичными runtime сервисами.

| Технический пользователь | Таблица | Точные права |
|---|---|---|
| `clrs_native_auth` | `clrs_staging.accounts` | SELECT |
| `clrs_native_auth` | `clrs_staging.auth_credentials` | SELECT |
| `clrs_native_auth` | `clrs_staging.device_sessions` | SELECT, INSERT, UPDATE |
| `clrs_legacy_read` | `clrs_staging.accounts` | SELECT |
| `clrs_legacy_read` | `clrs_staging.legacy_source` | SELECT |
| `clrs_legacy_read` | `clrs_staging.legacy_documents` | SELECT |

Оба account должны иметь server-side **REQUIRE SSL**. `USAGE ON *.*` не даёт доступа к таблицам и является ожидаемой строкой SHOW GRANTS; иных global/database grants, roles, GRANT OPTION, DELETE/DDL и доступа к `default_db` быть не должно.

## Конкретное действие после подтверждения владельца

1. В уже предоставленной Timeweb БД создать **два** password-protected пользователя с именами выше. Отключить «Использовать одинаковые привилегии для всех баз». Первоначально никаких database-wide/table privileges не добавлять; пароль задавать/сохранять в private0600 config вне Git/APK/чата.
2. Уполномоченный администратор БД сверяет username+host фактически созданных accounts и выполняет [runtime-mysql84-grants.sql](deploy/runtime-mysql84-grants.sql). Шаблон не содержит паролей/CREATE USER/revoke/DDL данных; он задаёт REQUIRE SSL и шесть exact table grants. `%` — host account template, а не право на все БД; заменить на фактический host, если Timeweb создал другой. При доступной проверенной server host restriction использовать её; неизвестный IP не угадывать.
3. Если Timeweb UI позволяет только права на всю БД, **не включать SELECT/INSERT/UPDATE на `clrs_staging.*` для обхода**: runtime validator намеренно откажет. Нужен администратор с MySQL CREATE USER/ALTER USER/GRANT authority либо поддержка Timeweb для exact table grants. Роль `clrs_migrate` с нынешними пятью правами не может выдавать эти grants.
4. Прочитать SHOW GRANTS каждого нового пользователя и сверить таблицу выше. Отдельно подтвердить server-side REQUIRE SSL в private admin console: MySQL8.4 SHOW GRANTS показывает права, nonprivilege account properties находятся в SHOW CREATE USER. Его полный вывод может содержать password authentication hash; наружу сообщать только boolean `requiresSSL=true`, не строку CREATE USER. Не выдавать сервисам SELECT на `mysql.*` ради такой проверки.
5. Подключить private URLs/CA к правильным variables: `CLRS_NATIVE_AUTH_DB_URL`/`CLRS_NATIVE_AUTH_DB_CA_FILE` для первого; `CLRS_LEGACY_READ_DB_URL`/`CLRS_LEGACY_READ_DB_CA_FILE` для второго. Это следующий защищённый config/deploy шаг, не действие SQL template. DNS hostname должен совпасть с сертификатом, CA проверяется, plaintext connection запрещено.

Текст конкретного browser-confirmation для владельца:

> Подтверждаете создание в существующей Timeweb БД двух технических пользователей `clrs_native_auth` и `clrs_legacy_read` с доступом только к перечисленным таблицам `clrs_staging` и обязательным SSL? Первый сможет читать аккаунты/данные входа и создавать/обновлять сессии; второй сможет только читать сохранённые профили и историю. Пароли сохраню отдельно от APK/Git. Новые платные ресурсы и права на другие БД не добавляются.

## Исправление совместимости validators и locking

`native_sessions.py` и `legacy_conversation_read.py` принимают optional exact `REQUIRE SSL` **только** на `GRANT USAGE ON *.*`. Suffix на table SELECT, X509, произвольные SSL options, GRANT OPTION, роли и дополнительные права по-прежнему отклоняются. Отсутствие suffix допускается для стандартного MySQL8.4 SHOW GRANTS; это не заменяет server-side REQUIRE SSL и проверку текущего `Ssl_cipher`, CA и hostname. Основание: [SHOW GRANTS](https://dev.mysql.com/doc/refman/8.4/en/show-grants.html), [account TLS options](https://dev.mysql.com/doc/refman/8.4/en/create-user.html).

Перед выдачей session после KDF аккаунт и credential повторно проверяются с `FOR SHARE OF a, c`; disabled/version/password изменения не могут пройти между readback и COMMIT. Refresh/logout блокируют session `FOR UPDATE OF s` и account `FOR SHARE OF a`. UPDATE право остаётся только у `device_sessions`; прежний unqualified FOR UPDATE на SELECT-only accounts/credentials был несовместим с указанными правами. MySQL8.4 поддерживает mixed clauses и требует alias после OF: [SELECT syntax](https://dev.mysql.com/doc/refman/8.4/en/select.html), [locking read privileges](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html).

Адресная проверка: **46/46** тестов `test_native_auth` и `test_legacy_conversation_read` прошли с synthetic DB и official public SCRYPT vector, без пользовательских данных. Использованы существующие Python3.12, Node22 и установленный PyMySQL; новых зависимостей не ставили. Регрессии проверяют REQUIRE SSL login/read, отказ лишних suffix/scopes/прав, прежний privilege failure и правильные shared/exclusive locks, disabled/token_version recheck, existing refresh/replay/concurrency guards. Synthetic SQL model не доказывает настоящий server parser/permissions.

После завершения текущей raw transaction отдельно выполнить реальный **zero-row SELECT** syntax probe с имеющимся TLS-клиентом, не меняя данные. Затем проверить SHOW GRANTS/TLS уже новым runtime account. Enable routes допускается только после исходного FULL/raw/profile/credential readback и controlled login прежним паролем; legacy READ дополнительно требует reviewed immutable-snapshot membership gate. Этот документ не включает public routes и не объявляет migration законченной.

Два запроса для отдельной проверки server syntax; выполнять в короткой транзакции с `ROLLBACK`, без INSERT/UPDATE/DDL. `WHERE 0` не возвращает пользовательские строки. Проверка с migration account доказывает только syntax, поэтому после выдачи exact grants повторить с `clrs_native_auth`:

```sql
SELECT a.uid, c.uid
FROM clrs_staging.accounts AS a
JOIN clrs_staging.auth_credentials AS c ON c.uid = a.uid
WHERE 0 LIMIT 1 FOR SHARE OF a, c;

SELECT s.session_id, a.uid
FROM clrs_staging.device_sessions AS s
JOIN clrs_staging.accounts AS a ON a.uid = s.uid
WHERE 0 LIMIT 1 FOR UPDATE OF s FOR SHARE OF a;
```
