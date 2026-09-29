# Сербский пользовательский текст: Cloud Translation NMT

`src/google_provider.js` — подготовленный серверный провайдер Google Cloud Translation Advanced (v3). Он не развёрнут и не подтверждён реальным запросом. Словари 23 языков интерфейса, фон, оплаты и Timeweb не меняются. Поддержанные ML Kit переводы можно сохранить на устройстве, а этот endpoint использовать для исходного/целевого сербского языка.

## Подключение

- Используется существующий Firebase/Google проект. Новый аккаунт AWS/Azure и ключ в APK не нужны.
- Отдельный Firebase export `translateContentGoogle` использует `GOOGLE_TRANSLATION_ENABLED=false` до проверки доступа и правил. Его `readConfig(process.env, 'google')` не требует AWS region/credentials. Прежний Amazon export `translateContent` и `TRANSLATION_ENABLED` остаются независимыми. Провайдер сам проверяет `config.enabled`, `config.provider === 'google'` и допустимый project ID перед получением ADC-токена.
- Сервер обращается только к `https://translate.googleapis.com/v3/projects/{projectId}/locations/global:translateText`, с `mimeType: text/plain` и явной моделью `general/nmt`. Внешний API не получает клиентские credentials и не позволяет вызывающему подставлять URL, модель или проект.
- OAuth берётся через `firebase-admin/applicationDefault().getAccessToken()` на сервере. В Cloud Functions это прикреплённый service account; локально — уже авторизованные ADC. JSON-ключ, refresh token и bearer token не записываются в исходники, пример env, APK, команды или отчёт.
- В проекте должен быть включён `translate.googleapis.com`; биллинг и квоты проверяются владельцем. Наличие подготовленного файла не означает включение API или платного ресурса.

## Минимальные права

Для самой NMT операции нужен `cloudtranslate.generalModels.predict`; для использования квот проекта — `serviceusage.services.use`. У runtime service account нет причины выдавать `Owner`, создавать API keys, модели, glossaries, batch/document jobs или Storage ресурсы. Точная custom role ограничивается этими операциями; более широкая готовая роль `roles/cloudtranslate.user` используется только если custom role недоступна.

Общий endpoint дополнительно требует существующие права чтения Firebase Auth пользователя, `users/{uid}`, транзакций `_translation_usage`/`_translation_cache` и доступа к серверному `TRANSLATION_CACHE_HMAC_KEY` в Secret Manager. Эти коллекции должны быть закрыты от любых клиентских grants. IAM и публикацию проверяет основной исполнитель; отдельный provider не меняет правила, пользователей или данные.

## Языки, кэш и интерфейс

Все текущие коды CLRS поддержаны NMT: `en de es fr it pt el ru sr pl sl sk cs bg ro mk hu sv nb fi da nl is`. `nb` отправляется как `no`, detected `no` возвращается как `nb`. `sr` отправляется как `sr`; существующий `toSerbianLatin` переводит только кириллицу результата в принятый латинский алфавит. Оригинальный текст сохраняется дословно.

Кэш использует отдельный namespace `google-cloud-nmt-v1`: Amazon и Google не разделяют записи. Существующие Auth, квоты, UID-изоляция, HMAC-ключи исходного текста + языка + цели, lease и повторное получение оригинала переиспользуются. `googlePowered: true` сохраняется и выводится при cache hit. Flutter переиспользует существующую компактную читаемую Google attribution рядом с результатом, а не у оригинала или чужого провайдера.

В APK opt-in состоит из `CLRS_TRANSLATION_REMOTE_FALLBACK=true` и подтверждённого HTTPS URL функции в `CLRS_TRANSLATION_ENDPOINT`. По умолчанию флаг `false`, endpoint пуст: прежние 22 ML Kit языка работают как раньше, сербский остаётся явно неподдержанным до включения. При включённом fallback поддержанные языки остаются на ML Kit; Google запрашивается только для целевого `sr` либо обнаруженного исходного `sr`. Ошибка native модели/перевода не запускает лишний платный fallback. Неизвестный исходный `und` не подменяется сербским. Sandbox не может обращаться к production URL.

Запросы не повторяются автоматически. Отмена/таймаут исключают позднее начало запроса после получения credentials; ошибки, невалидный/слишком большой ответ и отсутствие сети возвращаются без текста/токенов провайдера. Отмена не гарантирует отмену оплаты уже принятого внешним API запроса.

## Подтверждение

Локальный isolated тест `test/google_provider.test.js` на Node 22.23.2: **31/31**, 2026-09-28. Проверены 23 кода, NMT/plain text, сербская латиница, ADC и невозможность перенаправления credentials, отказ/отмена/ошибки/лимиты ответа. Использован подменённый HTTP, а не Google API.

После интеграции адресный Node-прогон `cache.test.js`, `translation.test.js`, `dependencies.test.js`: **86/86**. Amazon контракт сохранён, Google endpoint выключен независимо от Amazon и без AWS secrets; проверены cache isolation, дедупликация и атрибуция. Flutter service/native/fallback проверки: **88 успешных сценариев**; один сценарий потребовал исправления UTF-8 заголовка тестовой HTTP-фикстуры и был отдельно повторён (код приложения после прогона не менялся). Проверены 22 native цели без HTTP, RU→SR и SR→RU на подменённом backend, cache/session isolation, таймаут, offline, malformed metadata и отсутствие ненужного fallback.

До включения требуется настоящий запрос через развёрнутый авторизованный backend RU↔SR и RU↔EN, cache hit без второго обращения к провайдеру, UI «Перевести → Показать оригинал», два UID и смена аккаунта/экрана при запросе. Пока эти проверки не выполнены, сербский нельзя считать закрытым.

Первоисточники: [языки NMT](https://docs.cloud.google.com/translate/docs/languages), [v3 TranslateText и permission](https://docs.cloud.google.com/translate/docs/reference/rest/v3/projects.locations/translateText), [аутентификация ADC](https://docs.cloud.google.com/translate/docs/authentication), [IAM роли](https://docs.cloud.google.com/iam/docs/roles-permissions/cloudtranslate), [обязательная атрибуция](https://docs.cloud.google.com/translate/attribution).
