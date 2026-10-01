# Bounded MySQL 8.4 migration transport

`bounded-mysql84-client.mjs` оборачивает уже созданное mysql2 promise connection. Используется только в четырёх CLI: raw import/readback, profile projection, credential stage и conversation projection. Config/TLS/grants/source/empty-target/receipt gates в этих командах сохраняются; DDL, runtime API, Firebase и настройки сервера не меняются.

Одна query/execute операция получает driver `timeout: 30000` и отдельный абсолютный 30-секундный таймер. Он включает ожидание очереди, `execute` prepare и полный ответ. Graceful `end()` ограничен пятью секундами; одновременные вызовы делят один Future. Connect использует прежний проверенный config `connectTimeout: 5000`; этот wrapper создаётся **после** подключения и не заявляет отдельный абсолютный handshake deadline.

По установленному mysql2 **3.24.5**:

- `lib/promise/connection.js` передаёт object options в base `query/execute` и возвращает `[rows, fields]`.
- `lib/commands/query.js` и `execute.js` получают `options.timeout`; command timer начинается при запуске, после очереди, а binary execute имеет предварительный prepare.
- Promise `destroy()` делегирует в `BaseConnection.destroy/close`, где используется `stream.end()`. Поэтому при timeout wrapper дополнительно вызывает `connection.stream.destroy()` на фактическом TCP/TLS socket. Этот доступ к driver internals привязан к установленной версии; перед обновлением mysql2 требуется повторная проверка контракта.

Таймаут или fatal connection failure закрывают клиент и отвергают **все** pending Futures. Late success/rejection не принимаются, новые query/execute после этого запрещены. Graceful cleanup не ставит ROLLBACK в зависшую очередь. Нормальные аргументы SQL/params и `[rows,fields]` сохраняются; object timeout caller не может отключить/расширить лимит. Nonfatal MySQL errno/code, в частности ожидаемый `1044/ER_DBACCESS_DENIED_ERROR` из preflight, сохраняются.

Адаптеры должны продолжать передавать точный `query('COMMIT')`. Детектор допускает whitespace/trailing semicolon, но намеренно не является SQL parser для comments, `COMMIT WORK` или multi-statements. Сейчас все четыре используемых адаптера имеют этот точный контракт; multipleStatements остаётся выключен в config.

Ошибка/таймаут начатого COMMIT даёт безопасную `CLRS_MYSQL_COMMIT_OUTCOME_UNKNOWN` с `commitOutcomeUnknown=true`. Это **не доказательство rollback**: сервер мог завершить COMMIT до разрыва связи. SQL/params/driver exception/cause не включаются в новый timeout/unknown error, логирование не добавлено. CLI сохраняют существующий generic output и receipt-bound fresh verification; автоматического retry нет. У profile CLI cleanup `end().catch(...)` не маскирует первоначальную unknown ошибку и не препятствует очистке локального key buffer.

При timeout до COMMIT соединение также больше не используется; завершение remote транзакции не объявляется проверенным только по локальному destroy. Перед новой записью оператор сверяет существующий target и сохранённые receipts/source bindings. Отдельно залитые private S3 объекты не удаляются этим wrapper и остаются в существующем import reconciliation flow.

Проверено без MySQL/Firebase/S3 connections: **13/13** новых transport тестов (driver option contract, ignored driver timer/prepare/queue, hung execute/ROLLBACK/end, late/lost COMMIT, concurrent pending, safe errors, nonfatal1044, fatal connection failure). После интеграции вместе с четырьмя затронутыми CLI suites: **62/62 PASS**; `node --check` wrapper и четырёх CLI — PASS. Это targeted synthetic proof, а не live network outage test или подтверждение real stage.

```sh
node --test --test-reporter=spec \
  test/bounded-mysql84-client.test.mjs test/import-mysql84-cli.test.mjs \
  test/project-profiles.test.mjs test/credential-stage.test.mjs \
  test/project-conversations-mysql84.test.mjs
```

Независимый read-only review `db_migration_preflight` подтвердил outer deadline, socket teardown, pending/late-result protection, unknown COMMIT и сохранение errno1044. Реальных DB writes, расширения прав, APK/AVD/build или установки зависимостей этим шагом не было.
