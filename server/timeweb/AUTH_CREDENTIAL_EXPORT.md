# Защищённая выгрузка данных старых паролей

Реальная отдельная выгрузка 2026-09-30 выполнена через существующий Owner ADC:
8208 Auth пользователей, у всех провайдер password, у всех доступны hash и salt,
0 недоступных/редактированных записей, версия hash 0. Полученный project hashConfig
указывает SCRYPT и содержит signerKey, saltSeparator, rounds и memoryCost.
Обратное чтение полного архива с проверкой AES-GCM и счётчиков прошло успешно.
Эти значения и UID не выводились в отчёты или журнал и не сохранялись в Git/APK.
Архив и отдельный случайный ключ 32 байта находятся вне репозитория с правами
`0600`. Незавершённый файл никогда не публикуется как готовый архив.

Это подтверждает доступность исходных данных паролей, а не готовность входа
на Timeweb. В выгрузке намеренно установлены `schemeVerified:false` и
`standaloneLoginVerified:false`. Необходимо проверить реализацию Firebase
SCRYPT по официальным тестовым данным, затем вход контролируемого пользователя
через фактический backend, отказ при неверном пароле, блокировку, logout/login,
обновление/отзыв сессий и восстановление пароля. Стандартный scrypt не заменяет
модифицированный Firebase SCRYPT. Firebase Auth остаётся рабочим до завершения
этих проверок и финальной синхронизации пользователей/смен паролей.

Экспортёр `export-auth-credentials-encrypted.mjs` работает отдельно от полного
Auth/Firestore/Storage экспортёра: выполняет только GET configuration и
постраничный GET accounts:batchGet. Повторной выгрузки Firestore и фотографий
нет. Он сохраняет точные hash/salt/version, прежний UID, providers, disabled,
emailVerified и validSince без подмены алгоритма. Проверяет конфигурацию до
и после выгрузки; её изменение, повторный UID/page token, лимит или ошибка
прерывают публикацию. Другие Auth поля сохранены в основном CLRSX2 архиве.
Снимки сделаны в разные моменты и не считаются атомарными; перед переключением
обязательна финальная синхронизация.

Пример запуска с заранее подготовленным отдельным приватным ключом:

```sh
node export-auth-credentials-encrypted.mjs \
  --project PROJECT_ID --confirm-project PROJECT_ID \
  --out /private/auth-credentials.clrsenc --key-file /private/auth-credentials.key \
  --mode export --max-users 10000 --max-pages 12
```

Повторная локальная проверка не обращается к Firebase:

```sh
node export-auth-credentials-encrypted.mjs \
  --project PROJECT_ID --confirm-project PROJECT_ID \
  --out /private/auth-credentials.clrsenc --key-file /private/auth-credentials.key \
  --mode verify
```

Обычный `import-clrsx2-mysql84.mjs` не читает этот формат и сохраняет лишь
метаданные Auth в `legacy_auth_users`. Он не заполняет `auth_credentials`,
не реализует парольный вход и не превращает staging архив в рабочие аккаунты.
Отдельный credential importer должен подтвердить source UID с основной
выгрузкой и поддержку каждой версии, хранить параметры/секреты ограниченно
и проверять чтение после записи. Режим `bridge_only` оставляет зависимость
от Firebase Authentication; его нельзя назвать полным переносом входа.

По [официальному API](https://docs.cloud.google.com/identity-platform/docs/reference/rest/v1/projects.accounts/batchGet)
нужно `firebaseauth.users.get`, а выдача hash/salt/version требует дополнительного
разрешения. [Firebase](https://firebase.google.com/docs/auth/admin/manage-users#password_hashes_of_listed_users)
указывает `firebaseauth.configs.getHashConfig`; [GET configuration](https://docs.cloud.google.com/identity-platform/docs/reference/rest/v2/projects/getConfig)
требует `firebaseauth.configs.get` и OAuth cloud-platform либо identitytoolkit.
Параметры доступны в `signIn.hashConfig`. [Firebase CLI](https://firebase.google.com/docs/cli/auth#password_hash_parameters)
отдельно предупреждает, что импортированные старые алгоритмы могут дать пустые
hash/salt; наличие провайдера password само по себе не доказывает переносимость.
