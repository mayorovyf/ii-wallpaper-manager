# Менеджер обоев для ii (Quickshell)

Этот репозиторий содержит только модуль менеджера обоев из моей конфигурации `ii` для Quickshell.

Репо не является полноценной сборкой shell: это набор файлов, которые можно встроить в уже установленный `~/.config/quickshell/ii`.

## Что входит

- `.config/quickshell/ii/services/Wallpapers.qml`
- `.config/quickshell/ii/services/WallpaperListener.qml`
- `.config/quickshell/ii/modules/wallpaperSelector/WallpaperSelector.qml`
- `.config/quickshell/ii/modules/wallpaperSelector/WallpaperSelectorContent.qml`
- `.config/quickshell/ii/modules/wallpaperSelector/WallpaperDirectoryItem.qml`
- `.config/quickshell/ii/scripts/colors/switchwall.sh`
- `.config/quickshell/ii/GlobalStates.qml`

## Что умеет модуль

- Горизонтальный селектор обоев (карусель).
- Выбор обоев по клику и навигация с клавиатуры/колеса мыши.
- Live preview во время прокрутки (если включен в настройках).
- Работа с несколькими мониторами (выбор обоев для конкретного экрана).
- Поддержка видео/GIF через first-frame и thumbnail-логику.
- Смена через `switchwall.sh` с генерацией цветовой схемы.

## Зависимости

Для корректной работы нужны:

- `quickshell` + установленный `ii`
- `bash`
- `jq`
- `matugen`
- `ffmpeg`
- `imagemagick` (`magick`)
- `kdialog` (для системного пикера в `switchwall.sh`)

## Быстрая установка

Клонируй репозиторий и скопируй файлы в свой `ii`:

```bash
git clone git@github.com:mayorovyf/ii-wallpaper-manager.git
cd ii-wallpaper-manager

TARGET="$HOME/.config/quickshell/ii"

mkdir -p "$TARGET/services"
mkdir -p "$TARGET/modules/wallpaperSelector"
mkdir -p "$TARGET/scripts/colors"

cp -f .config/quickshell/ii/services/Wallpapers.qml "$TARGET/services/"
cp -f .config/quickshell/ii/services/WallpaperListener.qml "$TARGET/services/"
cp -f .config/quickshell/ii/modules/wallpaperSelector/WallpaperSelector.qml "$TARGET/modules/wallpaperSelector/"
cp -f .config/quickshell/ii/modules/wallpaperSelector/WallpaperSelectorContent.qml "$TARGET/modules/wallpaperSelector/"
cp -f .config/quickshell/ii/modules/wallpaperSelector/WallpaperDirectoryItem.qml "$TARGET/modules/wallpaperSelector/"
cp -f .config/quickshell/ii/GlobalStates.qml "$TARGET/"
cp -f .config/quickshell/ii/scripts/colors/switchwall.sh "$TARGET/scripts/colors/"
chmod +x "$TARGET/scripts/colors/switchwall.sh"
```

После этого перезапусти Quickshell/ii.

## Обновление

```bash
cd ii-wallpaper-manager
git pull
```

И снова выполни блок копирования из раздела выше.

## Примечание

По умолчанию модуль работает с папкой обоев `~/Wallpapers`. Если используешь другую структуру, измени путь в `Wallpapers.qml` (`defaultFolder`) или в своих настройках `ii`.
