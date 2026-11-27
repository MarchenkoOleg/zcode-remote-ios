# ZCode Remote (iOS)

Нативное iOS-приложение-обёртка для ссылок `https://zcode.z.ai/remote/v4?sid=…&mid=…&name=…&app_version=…`.
Позволяет вести несколько аккаунтов ZCode с разной авторизацией и не смешивать их сессии.

## Что реализовано

- **Изоляция аккаунтов.** У каждого аккаунта свой постоянный `WKWebsiteDataStore` (`forIdentifier:`): куки, IndexedDB и localStorage не пересекаются между пользователями и переживают перезапуск приложения.
- **Токены в Keychain.** Необязательный токен хранится с `WhenUnlockedThisDeviceOnly`, не попадает в iCloud. Основная авторизация живёт в веб-хранилище аккаунта.
- **Кэш и быстрый старт.** WKWebView переиспользуются (до 3 последних), поэтому переключение между сессиями не пересоздаёт страницу. Данные сайта сохраняются между запусками.
- **Надёжность соединения.** `NWPathMonitor` отделяет «нет сети» от «сервер недоступен» (HEAD-запрос к `zcode.z.ai` каждые 45 с). При обрыве — авто-реконнект с экспоненциальной задержкой (0.5 → 30 с), при восстановлении сети — немедленный реконнект активной сессии. Статус показывается внизу экрана.
- **Авторизация.** Попапы `window.open` (страница ZCode предлагает «Authorize in browser») открываются в отдельном экране с тем же хранилищем данных аккаунта, поэтому куки авторизации сразу видны remote-сессии.
- **Удобство.** Ссылка из ZCode вставляется целиком и разбирается автоматически; можно открыть сессию в Safari, скопировать ссылку, переподключиться вручную.
- **Deep link.** `zcode-remote://session/<session-uuid>` открывает нужную сессию (удобно для Shortcuts и домашнего экрана).
- **Язык интерфейса.** String Catalog (`Resources/Localizable.xcstrings`), переключатель «Системный / Русский / English» в меню `ⓘ`. Выбор также проставляется в `localStorage` страницы ZCode (`zcode-locale-preference`) и перезагружает её, но сам ZCode поддерживает только `zh-CN` и `en-US`: для «Русский» и «Системный» его UI остаётся английским. Иконка взята с официального сайта `zcode.z.ai` (`favicon-192x192.png`) и разведена в `Resources/Assets.xcassets/AppIcon.appiconset`; имя приложения на домашнем экране — **ZCode Remote**.

## Сборка

Проект сгенерирован через [xcodegen](https://github.com/yonaskolb/XcodeGen):

```bash
cd ZCodeRemote
xcodegen generate --spec project.yml
open ZCodeRemote.xcodeproj
```

В Xcode: выбрать scheme `ZCodeRemote`, устройство или симулятор, Run.

### Для установки на реальный iPhone

Bundle ID приложения — **`lr-tech.zcode-remote`** (по просьбе пользователя). В keychain есть сертификат `Apple Development: Oleg Marchenko` и команда `ZX334W6FA5`, но локально есть только provisioning profile для старого ID `ru.ligarobotov.chores`. Чтобы собрать версию с новым ID для реального iPhone, нужно добавить Apple ID в Xcode → Settings → Accounts и пересобрать с `-allowProvisioningUpdates` (Xcode выпустит новый profile). Пока этого не сделано, сборка для симулятора работает с `CODE_SIGNING_ALLOWED=NO`, а на телефоне остаётся предыдущая установка со старым ID.

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

Аргумент `native` сразу открывает бета-экран нативного клиента, `language=<system|ru|en>` принудительно задаёт язык для проверки, `switch-language=<...>` переключает его уже после запуска, `home-button=<overlay|bottom>` — положение кнопки; `dump-page` пишет в лог структуру DOM при каждом срабатывании наблюдателя; `force-page=<kind>` принудительно задаёт экран; `share-log` вместе с `show-logs` автоматически открывает лист экспорта логов.

### Что показали логи с iPhone (27.11.2026)

ZCode v4 — не зеркало экрана и не обычный SPA с HTTP-API. По HTTP уходят только `POST /api/v1/remote/token` и `GET /api/v1/client/configs`; всё остальное идёт по `wss://zcode.z.ai/api/v1/remote/ws2`. Relay V2 лишь аутентифицирует, связывает пару и пересылает непрозрачный `data.payload`; внутри него приложение обменивается `bootstrap-*`, `workspace-*`, `mobile-view-state-update` и RPC-кадрами с рабочим пространством на десктопе. Список задач и чат — это локальный UI веб-клиента, а не видеопоток с Mac. DOM страницы на этапе подключения содержит только статусы relay («Connecting to Mac…», «Paired. Loading workspace…»), поэтому определить по DOM, что открыт именно список сессий, невозможно. Кнопка «Домой» из-за этого показывается всегда — компактной капсулой в пустом месте шапки ZCode справа, без нижней панели.

Токен из URL WebSocket в логах заменяется на `***`; интервал health-HEAD увеличен с 20 до 45 с (каждый запрос занимал ~1,1–1,5 с).

- **Гибридный режим (бета).** Меню `ⓘ → Нативный режим (бета)`: WebKit используется только для входа и получения JWT, дальше сессия идёт через нативный `URLSessionWebSocketTask`. ТЗ и план — в `docs/hybrid-client-plan.md`.

## Нативный WebSocket-клиент (прототип)

`Sources/NativeRemote/` содержит реализацию транспорта Relay V2 без WebKit:

- `POST /api/v1/remote/token` с `Authorization: Bearer <JWT>` и `{"role":"terminal"}`;
- `wss://zcode.z.ai/api/v1/remote/ws2?token=…&mid=…`, `auth_init` → `auth_ack`;
- разбор конверта `type: data` и `payload.zcode_type`;
- сборка фрагментов `rpc-frame` (`messageSeq`, `fragmentIndex/Count`, `messageBytes`, CRC32) и отправка `rpc-frame-ack`;
- heartbeat `pair_status_query` каждые 5 с.

Протокол описан во внутренних документах официального репозитория `zai-org/ZCode` (`docs/web-remote-control/relay-v2-pairing.md`, `packages/shared/src/web-remote-relay/contract.ts`, `web-remote-control.ts`, `web-remote-control-rpc-transport.ts`). Публичного SDK с гарантиями совместимости нет: это внутренний контракт, который может измениться вместе с релизом ZCode.

Важно: `dataBase64` — не protobuf и не видео. Это собственный бинарный формат VS Code-style RPC (1-байтовые теги, varint-длины, JSON-тела для объектов). Поэтому полноценный нативный клиент требует не только транспорта, но и реализации ~39 RPC-сервисов/каналов и всего UI списка задач/чата. Транспорт готов; прикладной слой — отдельная большая работа.

Оценка выигрыша после перехода с WKWebView на нативный клиент:

| Метрика | Ожидаемый эффект |
|---|---|
| Холодный старт | ~1,3–1,5 с загрузки страницы → ~0,8–1,0 с (токен + WS), минус ~0,4 с |
| Тёплый старт | почти без изменений (уже загруженный WKWebView и так быстр) |
| Память | минус ~60–80% (нет WebContent-процесса и 4,6 МБ JS-бандла) |
| CPU/батарея | минус ~30–50% в активной работе (нет JS-движка, DOM, моста сообщений) |
| Задержка ввода | минус ~5–15 мс; сеть (50–150 мс RTT) всё равно доминирует |
| Фон/реконнект | заметно лучше: нативный WS не замораживается сообщением «Page is in background» |

Практичный промежуточный вариант — оставить WebKit только для логина/получения JWT, а всё остальное время работать через нативный транспорт.

## Структура

```
Sources/
  Models/        ZCodeAccount, RemoteSession, RemoteLink, AppTypes
  Stores/        Store (JSON), KeychainStore, Backoff, ConnectivityMonitor, WebViewCache
  NativeRemote/  NativeRemoteProtocol, NativeRemoteClient (Relay V2, без WebKit)
  Views/         ContentView, AccountListView, SessionListView, RemoteWebView,
                 RemoteSessionView, AuthWebView, AddAccountView, AddSessionView
  AppModel.swift
Tests/CoreTests.swift
project.yml
```
