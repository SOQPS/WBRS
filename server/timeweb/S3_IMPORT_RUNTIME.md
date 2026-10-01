# Ограничения ожидания и повтор безопасного импорта

`createPrivateS3MediaAdapter` проверяет owner-only ACL, MIME, фактический размер
и SHA-256 каждого объекта. Он не доверяет одному ETag или наличию ключа.
`IfNoneMatch: '*'` запрещает перезаписывать существующий объект; отличающиеся
байты или MIME прерывают stage. Полная исходная metadata отдельно сохраняется
и сравнивается SQL adapter. Ключи raw import остаются в quarantine.

SDK-клиент должен иметь `maxAttempts: 1`. `createBoundedS3Transport` проверяет
это до запросов и используется также для bucket ACL/policy/probe проверок.
Рекомендуемые Node HTTP options: `connectionTimeout: 5000`,
`requestTimeout: 35000`, `socketTimeout: 15000`, `throwOnRequestTimeout: true`.
Операции metadata/headers ограничены 35 секундами, PUT — 120 секундами.
Полная проверка GET, включая ACL/headers/body, ограничена 120 секундами;
ожидание следующего непустого body chunk — 15 секундами. Все лимиты абсолютные
максимумы; тесты могут уменьшать их, увеличивать их через options нельзя.
При deadline выполняется abort/destroy; поздний отброшенный response body
также закрывается. Cleanup не подменяет исходную ошибку.

Потерянный ответ PUT не вызывает автоматический повтор. Сохранённый объект
может существовать, даже если клиент получил ошибку. Следующая явно начатая
проверка/попытка перечитывает его полностью; совпавший объект используется без
нового PUT, конфликтующий объект не перезаписывается.

Если COMMIT был отправлен, но подтверждение не получено, `stageImport` бросает
`ImportCommitUncertainError` с `commitOutcomeUnknown: true` и
`requiresVerification: true`. Успешный ответ ROLLBACK после этого не доказывает,
что COMMIT не состоялся. CLI выдаёт `commit_unknown` и требует полной
`--mode verify` на новом соединении, с тем же архивом/ключом/source и privacy
preflight, до повторного stage. Автоматического retry нет; initial error
сохраняется как cause, приватные driver details в stdout/stderr не выводятся.

`onProgress` media adapter передаёт только `verifiedObjects`, `verifiedBytes`
и `putAttempts`. CLI пишет редкие JSON ticks с `phase: uncommitted` или
`readback`, без UID, имён объектов, ключей и содержимого. Эти ticks не являются
подтверждением COMMIT. SQL connection/query/COMMIT/ROLLBACK deadlines должны
обеспечиваться отдельно: S3 deadline не отменяет DB transaction.
