# AAPSClient iOS

Нативный iOS-клиент (follower) для [AndroidAPS](https://github.com/nightscout/AndroidAPS) через
Nightscout API v3. Мониторинг петли AAPS (глюкоза, IOB/COB, статус петли, история событий) и
ограниченный набор удалённых действий-записи — без необходимости запускать Android.

**Болюс не поддерживается** — это follower/remote-control клиент, а не контроллер помпы.

## Возможности

- Текущая глюкоза, тренд, IOB/COB из device status AndroidAPS
- Статус петли и история последних treatments
- Удалённые действия (требуют соответствующей роли на access-токене в Nightscout):
  - Ввод углеводов (с подтверждением перед отправкой)
  - Установка/отмена temp target
  - Переключение профиля (с процентом и длительностью)
  - Care events
  - Управление режимом петли (open/closed/suspend)
- Фоновое обновление (`BGAppRefreshTask`, ~5 мин) и локальные алармы по порогам глюкозы
- Статистика (TIR, перцентили) за настраиваемый период

## Требования

- iOS 16+
- Работающий Nightscout с включённым API v3, подключённый к AndroidAPS
- Access-токен Nightscout с нужной ролью:
  - `readable` — только мониторинг
  - `careportal`/`admin` (или кастомная роль с `api:treatments:create`) — для удалённых записей
  - Для переключения профиля/режима петли на стороне AndroidAPS должны быть включены мастер-настройки
    `NsClientAcceptProfileSwitch` / `NsClientAcceptRunningMode`

## Стек

- Swift 5.9 / SwiftUI, iOS 16+
- Проект генерируется [xcodegen](https://github.com/yonaskolb/XcodeGen) из `project.yml` —
  сам `.xcodeproj` не хранится в git

## Сборка

```bash
brew install xcodegen   # если ещё не установлен

# Опционально: свой Apple Developer Team ID для подписи
cp Config/Local.xcconfig.example Config/Local.xcconfig
# отредактировать Config/Local.xcconfig

xcodegen generate
open AAPSClientiOS.xcodeproj
```

Сборка для устройства:

```bash
xcodebuild -project AAPSClientiOS.xcodeproj -scheme AAPSClientiOS \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Тесты:

```bash
xcodebuild test -project AAPSClientiOS.xcodeproj -scheme AAPSClientiOSTests \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Проверка сборки без macOS

Часть разработки идёт на Windows, где нет ни Swift-тулчейна, ни iOS SDK. Поэтому
проверка двухуровневая.

**GitHub Actions — единственное место, где код реально компилируется.** Workflow
`.github/workflows/ci.yml` ставит xcodegen, генерирует проект, собирает и прогоняет
тесты на симуляторе без подписи. Полные логи лежат в артефакте `build-logs`, а в
Summary прогона выводится дедуплицированный список всех ошибок — первая компиляция
крупного изменения даёт их десятками, и чинить их пакетом быстрее, чем по одной за
круг CI.

Запускается **только по требованию** (macOS-раннер стоит ~8 минут и в 10 раз больше
billing-минут, чем Linux):

```bash
gh workflow run CI --ref feat/aaps-v4-integration
gh workflow run CI --ref feat/aaps-v4-integration -f run_tests=false   # только компиляция
gh run watch                                                            # следить за прогоном
```

**Локальный пре-флайт** ловит то, что видно без компилятора, за пару секунд:

```bash
python scripts/precheck.py          # что можно проверить чтением
python scripts/precheck.py --list   # список проверок
```

Проверяются: синтаксис Swift, парность ключей `en`/`ru` и совпадение
format-спецификаторов, ссылки `loadFixture()` на существующие файлы, дубли
объявлений типов, совпадение `App/Info.plist` с `project.yml`, и то, что каждый
зарегистрированный BGTask-идентификатор объявлен (незаявленный роняет приложение
на старте, до появления UI).

Синтаксис проверяется настоящим парсером, если в PATH есть `swiftc`: `swiftc -parse`
не резолвит импорты и потому работает без iOS SDK. Ставится на Windows одной командой
(`winget install --id Swift.Toolchain`; нужны VS Build Tools с C++), занимает ~9 секунд
на 110 файлов. Без тулчейна — балансировка скобок.

Это **не компилятор**: вывод типов, разрешение перегрузок, изоляция `@MainActor` и
проверка `Sendable`-захватов требуют настоящего фронтенда. Авторитет — CI.

Хук, чтобы не тратить круг CI на ерунду (обходится через `git push --no-verify`):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/install-hooks.ps1
```

После правки `scripts/precheck.py` прогоните `python scripts/precheck_selftest.py` —
он ломает дерево десятью способами и проверяет, что каждый пойман. Анализатор,
который разучился падать, молча рапортует «чисто» и этого никто не замечает.

Архивирование для распространения использует `ExportOptions.plist` (скопировать из
`ExportOptions.plist.example` и указать свой Team ID — файл в `.gitignore`, так как привязан
к конкретному Apple Developer аккаунту).

## Архитектура

Послойная: `NightscoutClientLive` (HTTP) → `NsMapping` (JSON → доменные модели) → `AppStore`
(состояние приложения) → SwiftUI views.

- **`NightscoutClient`** — протокол чтения NS и отправки treatments. `UnconfiguredClient`
  используется до тех пор, пока в Keychain не появятся учётные данные.
- **`NsTreatmentWriter`** — удалённые записи (carbs, temp target, профиль, care events, режим петли).
- **`AlarmEngine`** — оценка пороговых значений глюкозы и локальные уведомления.
- **`BackgroundScheduler`** — периодическое обновление через `BGAppRefreshTask`.
- **`AppStore`** — единый `@ObservableObject`, инжектируемый во все views.

JSON-ответы парсятся через `JSONSerialization`, а не `JSONDecoder` — `JSONDecoder` в
современных версиях iOS падает на высокоточных числах с плавающей запятой
(напр. `82.8000000000001`), которые AAPS/OpenAPS обычно отдают для IOB/COB.

## Тестирование

Тесты используют fixture-based `NightscoutClient` и mock HTTP transport; JSON-фикстуры лежат
в `AppTests/Fixtures/`.

## Локализация

Строки UI локализуются через `String(localized:)`; переводы — в
`App/Resources/{en,ru}.lproj/Localizable.strings`.

## Лицензия

[GNU AGPLv3](LICENSE), как и AndroidAPS.
