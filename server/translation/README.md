# CLRS: Amazon Translate для пользовательского текста

Существующий отдельный Firebase Functions v2 backend `translateContent` теперь вызывает Amazon Translate. Это **подготовленный код, не развёрнутый сервис**. Переезд CLRS на Timeweb, Firebase Auth/Firestore, 23 словаря интерфейса, платёжная логика и другие экраны этим пакетом не меняются. `TRANSLATION_ENABLED` по умолчанию выключен. Реальные AWS и пользовательские данные не вызывались.

## Контракт

Нативный клиент отправляет HTTPS `POST` с `Authorization: Bearer <Firebase ID token>` и `Content-Type: application/json`:

```json
{"text":"Добрый вечер","targetLanguage":"en"}
```

Успешный ответ:

```json
{"translatedText":"Good evening","detectedSourceLanguage":"ru","targetLanguage":"en"}
```

Только эти два входных поля разрешены. `text` — непустой корректный Unicode, максимум 5000 codepoints **и 10 000 UTF-8 байт** (лимит синхронного Amazon `TranslateText`); тело JSON — максимум 32768 байт. Исходный язык определяется Amazon с `SourceLanguageCode=auto`; для этого Amazon вызывает Comprehend в том же AWS регионе. Имена, URL, email, UI-строки и служебные идентификаторы клиент не должен отправлять как самостоятельные поля для перевода. Ошибка никогда не подменяет оригинал выдуманным переводом.

Поддержаны коды интерфейса `en de es fr it pt el ru sr pl sl sk cs bg ro mk hu sv nb fi da nl is`. Все 23 есть в [списке языков Amazon Translate](https://docs.aws.amazon.com/translate/latest/dg/what-is-languages.html). `nb` передаётся Amazon как `no`, ответ клиенту остаётся `nb`. `sr` передаётся как `sr`; если ответ пришёл сербской кириллицей, **только ответ** преобразуется в латиницу для CLRS. Поскольку автоматическое определение языка может ошибаться на коротком тексте, RU↔SR необходимо проверить реальными запросами до включения пользователям. При отказе/недоступном языке сервер возвращает ошибку и приложение оставляет оригинал.

Ошибки содержат только `{"error":{"code":"..."}}`: 400 `invalid_request`/`unsupported_language`, 401 `unauthenticated`, 403 `account_not_allowed`, 405 `method_not_allowed`, 413 `request_too_large`, 429 `translation_limit`, 503 `translation_unavailable`. Ответы `Cache-Control: no-store, private`. CORS выключен. Приложение может повторить запрос по действию пользователя; backend автоматически не повторяет платный AWS вызов.

## Защита и кэш

Перед кэшем и Amazon проверяются Firebase ID token с отзывом, существующий активный пользователь и `users/{uid}`. Анонимные, отсутствующие, blocked и deleted аккаунты запрещены; обычный email/password аккаунт с пустым `providerData` допускается. Существующая транзакция `_translation_usage` ограничивает UID и проект по символам в сутки и запросам в минуту. Лимит считается и для попадания в кэш, чтобы дешёвыми повторениями нельзя было обойти защиту endpoint. Резерв после ошибки не возвращается: внешний провайдер мог уже выполнить запрос.

Серверный кэш `_translation_cache` разделён по UID. HMAC alias для автоопределения позволяет найти повтор до обращения к Amazon; canonical запись HMAC включает исходный текст, **фактически определённый исходный язык**, целевой язык и UID. Документы не содержат оригинальный текст или открытый хеш текста; canonical хранит переведённый текст, язык и срок 7 дней. Alias имеет ограниченную lease, чтобы параллельные одинаковые запросы на разных экземплярах функции ждали один внешний вызов. При ошибке claim удаляется; зависший claim может быть перехвачен через 25 секунд. Если AWS уже принял запрос, а затем истёк таймаут, гарантировать отсутствие его оплаты невозможно.

`TRANSLATION_CACHE_HMAC_KEY` — отдельный случайный 32-байтный ключ в base64, **только серверный секрет**. При его смене прежние записи кэша становятся недоступными; физическое удаление требует настроенного TTL/очистки. В production Firestore rules нужно исключить `_translation_usage` и `_translation_cache` из **любых** клиентских read/write grants; пример в `firestore.rules.fragment.txt` сам по себе не перекрывает пересекающийся wildcard `allow true`. Кэш содержит пользовательские переводы, поэтому нужно также согласовать срок хранения/удаления и права администраторов. Для `_translation_cache` можно настроить Firestore TTL по полю `ttlAt`; без него записи будут только логически просрочены. Счётчики `_translation_usage` поля `ttlAt` не имеют: для них отдельно согласовать retention и плановую очистку старых суток, **не удаляя текущие счётчики**.

## Что требуется для подключения

1. Доступ к **тому же Firebase/Google проекту CLRS** для развёртывания функции и проверки production Firestore rules. Сейчас такого доступа нет. Нужны права на Cloud Functions/Secret Manager, чтение Auth, чтение `users`, транзакции счётчиков и кэша. До проверки правил не включать сервис.
2. От владельца AWS: **AWS region**, где доступны оба сервиса Amazon Translate и Comprehend; отдельный IAM principal/role для backend с минимальными действиями `translate:TranslateText` и `comprehend:DetectDominantLanguage` (`Resource: "*"` для этих операций, с ограничением региона через IAM condition при возможности). `TranslateDocument`, S3, полный `TranslateFullAccess` не требуются. Нужно проверить разрешение и биллинг Amazon Translate/Comprehend на тестовом аккаунте. Пароль AWS не нужен и в чат не присылается.
3. На этом Firebase Functions backend AWS SDK использует серверные `AWS_ACCESS_KEY_ID` и `AWS_SECRET_ACCESS_KEY`, связанные с функцией через **Secret Manager**; `TRANSLATION_CACHE_HMAC_KEY` хранится там же. Никакие значения секретов не писать в исходники, клиент, `.env`, команды с аргументами, коммиты и логи. Если владелец уже использует федеративную IAM роль, credential provider chain SDK её поддерживает, но развёртывание функции и secret bindings нужно отдельно настроить и проверить для этой роли. `AWS_REGION` — обычная серверная настройка, не секрет; синтаксис валидируется, реальная доступность двух сервисов проверяется при интеграции.
4. `TRANSLATION_ENABLED=true` выставлять **после** проверки доступа, Firestore rules, бюджета и реальных тестов. При `FUNCTIONS_EMULATOR=true` платный провайдер принудительно выключен. Функция ограничена 18-секундным deadline запроса, 20-секундным лимитом платформы, `maxInstances=2`, `concurrency=10`; SDK настроен без автоматических повторов. Отдельно задать AWS budget/quotas: локальные лимиты ограничивают этот endpoint, а не весь AWS счёт.
5. Только после разрешения владельца выполнить узкое развёртывание `translation` codebase из `firebase.translation.json`, не разворачивая чужие rules/functions. Затем реальными авторизованными запросами проверить RU↔EN и RU↔SR, два UID, кэш, ошибку/таймаут, недоступную сеть и client UX; лишь после этого собирать APK с подтверждённым HTTPS URL в `CLRS_TRANSLATION_ENDPOINT`.

Локальные проверки из этой директории: `npm ci --ignore-scripts`, `npm test`, `npm run check`. Тесты используют подменённые Auth/Firestore/AWS вызовы и **не подтверждают** успешный реальный запрос Amazon. В текущем Firebase console проект недоступен, AWS регион и IAM не предоставлены, поэтому деплой и включение не выполнялись.

Первоисточники: [TranslateText API](https://docs.aws.amazon.com/translate/latest/APIReference/API_TranslateText.html), [языки](https://docs.aws.amazon.com/translate/latest/dg/what-is-languages.html), [Comprehend регионы](https://docs.aws.amazon.com/comprehend/latest/dg/guidelines-and-limits.html), [Firebase secret parameters](https://firebase.google.com/docs/functions/config-env#secret-manager), [Firebase ID token verification](https://firebase.google.com/docs/auth/admin/verify-id-tokens).
