# ZCode Remote (iOS)

Нативное iOS-приложение-обёртка для ссылок `https://zcode.z.ai/remote/v4?sid=…&mid=…&name=…&app_version=…`.
Позволяет вести несколько аккаунтов ZCode с разной авторизацией и не смешивать их сессии.

## Что реализовано

- **Изоляция аккаунтов.** У каждого аккаунта свой постоянный `WKWebsiteDataStore` (`forIdentifier:`): куки, IndexedDB и localStorage не пересекаются между пользователями и переживают перезапуск приложения.
- **Токены в Keychain.** Необязательный токен хранится с `WhenUnlockedThisDeviceOnly`, не попадает в iCloud. Основная авторизация живёт в веб-хранилище аккаунта.
- **Кэш и быстрый старт.** WKWebView переиспользуются (до 3 последних), поэтому переключение между сессиями не пересоздаёт страницу. Данные сайта сохраняются между запусками.
- **Надёжность соединения.** `NWPathMonitor` отделяет «нет сети» от «сервер недоступен» (HEAD-запрос к `zcode.z.ai` каждые 20 с). При обрыве — авто-реконнект с экспоненциальной задержкой (0.5 → 30 с), при восстановлении сети — немедленный реконнект активной сессии. Статус показывается внизу экрана.
- **Авторизация.** Попапы `window.open` (страница ZCode предлагает «Authorize in browser») открываются в отдельном экране с тем же хранилищем данных аккаунта, поэтому куки авторизации сразу видны remote-сессии.
- **Удобство.** Ссылка из ZCode вставляется целиком и разбирается автоматически; можно открыть сессию в Safari, скопировать ссылку, переподключиться вручную.
- **Deep link.** `zcode-remote://session/<session-uuid>` открывает нужную сессию (удобно для Shortcuts и домашнего экрана).

## Сборка

Проект сгенерирован через [xcodegen](https://github.com/yonaskolb/XcodeGen):

```bash
cd ZCodeRemote
xcodegen generate --spec project.yml
open ZCodeRemote.xcodeproj
```

В Xcode: выбрать scheme `ZCodeRemote`, устройство или симулятор, Run.

### Для установки на реальный iPhone

Сейчас bundle ID временно **`ru.ligarobotov.chores`** — по явной просьбе пользователя. Это значит, что установка заменяет приложение Chores на телефоне (вместе с его данными). Возврат к собственному ID `ru.ligarobotov.zcode-remote` потребует добавить Apple ID в Xcode → Settings → Accounts и выпустить новый provisioning profile.

Подпись автоматическая, команда `ZX334W6FA5`, сертификат `Apple Development: Oleg Marchenko` уже есть в keychain; отдельно добавлять аккаунт в Xcode не нужно, пока используется существующий profile.

```bash
xcodegen generate --spec project.yml
xcodebuild -project ZCodeRemote.xcodeproj -scheme ZCodeRemote \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build-device build
xcrun devicectl device install app --device <UDID> \
  .build-device/Build/Products/Debug-iphoneos/ZCodeRemote.app
xcrun devicectl device process launch --device <UDID> ru.ligarobotov.chores
```

Установлено и запущено на iPhone (Oleg M.) 27.11.2026.

### Сборка из CLI (симулятор)

```bash
xcodebuild -project ZCodeRemote.xcodeproj -scheme ZCodeRemote \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build build \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64
```

### Тесты

```bash
xcodebuild -project ZCodeRemote.xcodeproj -scheme ZCodeRemoteTests \
  -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=<имя устройства>' \
  test CODE_SIGNING_ALLOWED=NO
```

9 тестов: разбор ссылок (полная, без схемы, дефолты, отказ чужого хоста, round-trip URL), backoff и разбор версии ZCode.

### Отладка

При запуске с аргументом `open-session=<uuid>` приложение сразу открывает указанную сессию — использовалось для проверки реальной ссылки в симуляторе.

Положение кнопки «Домой» выбирается в меню `ⓘ` на главном экране: «Поверх, в шапке» (по умолчанию) или «Снизу экрана». Настройка сохраняется между запусками.

Аргумент `home-button=<overlay|bottom>` принудительно задаёт положение кнопки для проверки; `dump-page` пишет в лог структуру DOM при каждом срабатывании наблюдателя; `force-page=<kind>` принудительно задаёт экран; `share-log` вместе с `show-logs` автоматически открывает лист экспорта логов.

### Что показали логи с iPhone (27.11.2026)

ZCode v4 — не обычный SPA с HTTP-API чатов, а зеркало рабочего стола Mac. По HTTP уходят только `POST /api/v1/remote/token` и `GET /api/v1/client/configs`; всё остальное (включая списки чатов/проектов) идёт фрагментами по `wss://zcode.z.ai/api/v1/remote/ws2` (пакеты до ~865 КБ, `dataBase64`). DOM страницы содержит лишь статусы relay («Connecting to Mac…», «Paired. Loading workspace…»), поэтому определить по DOM, что открыт именно список сессий, невозможно. Кнопка «Домой» из-за этого показывается всегда — компактной капсулой в пустом месте шапки ZCode справа, без нижней панели.

Токен из URL WebSocket в логах заменяется на `***`; интервал health-HEAD увеличен с 20 до 45 с (каждый запрос занимал ~1,1–1,5 с).

## Структура

```
Sources/
  Models/        ZCodeAccount, RemoteSession, RemoteLink, AppTypes
  Stores/        Store (JSON), KeychainStore, Backoff, ConnectivityMonitor, WebViewCache
  Views/         ContentView, AccountListView, SessionListView, RemoteWebView,
                 RemoteSessionView, AuthWebView, AddAccountView, AddSessionView
  AppModel.swift
Tests/CoreTests.swift
project.yml
```
