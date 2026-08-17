# Send to Android

*Русский · [English](#send-to-android-english)*

Иконка в трее macOS → окошко → перетаскиваешь файлы → они улетают на Android по `adb`.

## Установка

Готовое приложение лежит в репозитории — собирать ничего не нужно:
**[скачать SendToAndroid.app.zip](https://github.com/romaswork/send_to_android/raw/main/dist/SendToAndroid.app.zip)** (54 КБ, Apple Silicon, macOS 13+).

Распаковать, положить в «Программы» и один раз снять карантин — приложение подписано ad-hoc,
без этого macOS не даст его запустить:

```bash
xattr -dr com.apple.quarantine /Applications/SendToAndroid.app
```

Нужен только `adb`: `brew install --cask android-platform-tools`, на телефоне — отладка по USB.

## Сборка из исходников

```bash
./build.sh            # build/SendToAndroid.app
./build.sh --install  # сразу в /Applications
```

## Как пользоваться

- Клик по иконке — открывается окно с зоной для перетаскивания (второй клик закрывает).
- Во время отправки видно полосу прогресса (по всем файлам сразу) и текущую скорость; по завершении играет звук — Glass, если всё ушло, Basso, если были ошибки.
- Файлы можно бросать и прямо на иконку в трее, не открывая окно.
- Правый клик — имя подключённого устройства и «Выйти».

Куда попадают файлы:

| Тип | Папка на телефоне |
|---|---|
| jpg, png, heic, webp, dng… | `/sdcard/DCIM/Camera` |
| mp4, mov, mkv, avi… | `/sdcard/Movies` |
| остальное | `/sdcard/Download` |

После отправки файл сразу индексируется медиасканером, поэтому появляется в галерее без перезагрузки телефона.
Существующие файлы не перезаписываются: `photo.jpg` станет `photo-1.jpg`.

## Автозапуск

Системные настройки → Основные → Объекты входа → добавить `SendToAndroid.app`.

---

# Send to Android (English)

*[Русский](#send-to-android) · English*

A macOS menu bar icon → a small window → drop files in → they fly to your Android over `adb`.

## Install

The built app is in the repository, so there is nothing to compile:
**[download SendToAndroid.app.zip](https://github.com/romaswork/send_to_android/raw/main/dist/SendToAndroid.app.zip)** (54 KB, Apple Silicon, macOS 13+).

Unzip it, move it to Applications and remove the quarantine flag once — the app is ad-hoc signed,
and without this macOS refuses to launch it:

```bash
xattr -dr com.apple.quarantine /Applications/SendToAndroid.app
```

The only requirement is `adb`: `brew install --cask android-platform-tools`, plus USB debugging enabled on the phone.

## Building from source

```bash
./build.sh            # build/SendToAndroid.app
./build.sh --install  # straight into /Applications
```

## Usage

- Click the icon to open the window with the drop zone (a second click closes it).
- While sending you see a progress bar (across all files at once) and the current speed; a sound plays when it finishes — Glass if everything went through, Basso if there were errors.
- You can also drop files directly onto the menu bar icon without opening the window.
- Right click shows the name of the connected device and "Quit".

Where the files end up:

| Type | Folder on the phone |
|---|---|
| jpg, png, heic, webp, dng… | `/sdcard/DCIM/Camera` |
| mp4, mov, mkv, avi… | `/sdcard/Movies` |
| everything else | `/sdcard/Download` |

After transfer each file is indexed by the media scanner right away, so it shows up in the gallery without rebooting the phone.
Existing files are never overwritten: `photo.jpg` becomes `photo-1.jpg`.

## Launch at login

System Settings → General → Login Items → add `SendToAndroid.app`.
