import AppKit

// MARK: - Куда класть файлы на телефоне

let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "bmp", "tiff", "dng"]
let videoExts: Set<String> = ["mp4", "mov", "mkv", "avi", "webm", "3gp", "m4v"]

func destinationDir(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if imageExts.contains(ext) { return "/sdcard/DCIM/Camera" }
    if videoExts.contains(ext) { return "/sdcard/Movies" }
    return "/sdcard/Download"
}

/// Экранирование пути для `adb shell` (команда выполняется через sh на телефоне).
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func byteSize(of url: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    guard isDir.boolValue else {
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    var total: Int64 = 0
    if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    return total
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 0 else { return "" }
    let units: [(String, Double)] = [("ГБ/с", 1e9), ("МБ/с", 1e6), ("КБ/с", 1e3)]
    for (name, scale) in units where bytesPerSecond >= scale {
        return String(format: "%.1f %@", bytesPerSecond / scale, name)
    }
    return String(format: "%.0f Б/с", bytesPerSecond)
}

// MARK: - adb

enum Adb {
    /// Пути, где обычно лежит adb. Первый найденный и используется.
    private static let candidates = [
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath,
        "/usr/bin/adb",
    ]

    static let path: String? = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Result {
        let code: Int32
        let output: String
        var ok: Bool { code == 0 && !output.lowercased().contains("adb: error") }
    }

    @discardableResult
    static func run(_ args: [String]) -> Result {
        guard let adb = path else { return Result(code: 127, output: "adb не найден") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(code: 127, output: "\(error)")
        }
        // Сначала вычитываем поток до EOF, только потом ждём выхода — иначе adb push
        // на большом файле упрётся в переполненный пайп.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// `adb push` с процентами. adb печатает прогресс только в терминал, поэтому
    /// запускаем его через псевдотерминал и подсовываем TERM.
    static func push(local: String, remote: String, onPercent: (Int) -> Void) -> Result {
        guard let adb = path else { return Result(code: 127, output: "adb не найден") }
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: 25, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            return run(["push", local, remote])  // фолбэк: без прогресса, но файл уедет
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["push", local, remote]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm"
        process.environment = environment
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        do {
            try process.run()
        } catch {
            close(master)
            close(slave)
            return Result(code: 127, output: "\(error)")
        }
        close(slave)  // иначе чтение из master никогда не упрётся в EOF

        var output = ""
        var pending = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { break }
            let chunk = String(decoding: buffer[0..<count], as: UTF8.self)
            output += chunk
            pending += chunk
            // Строка прогресса заканчивается \r, финальная — \n.
            while let end = pending.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
                let line = String(pending[pending.startIndex..<end])
                pending = String(pending[pending.index(after: end)...])
                if let percent = percent(in: line) { onPercent(percent) }
            }
        }
        close(master)
        process.waitUntilExit()
        return Result(code: process.terminationStatus, output: output)
    }

    /// Достаёт 42 из строки вида `[ 42%] /sdcard/DCIM/Camera/photo.jpg`.
    private static func percent(in line: String) -> Int? {
        guard let close = line.range(of: "%]"),
              let open = line.range(of: "[", options: .backwards, range: line.startIndex..<close.lowerBound)
        else { return nil }
        return Int(line[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    /// Имя подключённого устройства, либо nil.
    static func connectedDevice() -> String? {
        let result = run(["devices", "-l"])
        guard result.code == 0 else { return nil }
        for line in result.output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[1] == "device" else { continue }
            let model = fields.first { $0.hasPrefix("model:") }?.dropFirst("model:".count)
            return model.map { $0.replacingOccurrences(of: "_", with: " ") } ?? String(fields[0])
        }
        return nil
    }

    /// Просим Android проиндексировать файл, чтобы он появился в галерее.
    static func scanMedia(_ remotePath: String) {
        let viaContent = run([
            "shell", "content", "call",
            "--uri", "content://media/external/file",
            "--method", "scan_file",
            "--arg", shellQuote(remotePath),
        ])
        if viaContent.ok { return }
        // Старые прошивки (Android 9 и ниже) понимают только broadcast.
        run(["shell", "am", "broadcast",
             "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
             "-d", shellQuote("file://" + remotePath)])
    }

    /// Свободное имя в целевой папке: photo.jpg → photo-1.jpg, если занято.
    static func freeName(dir: String, name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        for attempt in 1...50 {
            let probe = run(["shell", "test -e \(shellQuote(dir + "/" + candidate)) && echo BUSY"])
            guard probe.output.contains("BUSY") else { return candidate }
            candidate = ext.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(ext)"
        }
        return candidate
    }
}

// MARK: - Отправка

enum Transfer {
    struct Update {
        var text: String
        var fraction: Double  // 0…1 по всем файлам сразу
        var speed: String
    }

    /// Отправляет файлы по очереди. Колбэки вызываются в главном потоке.
    static func send(_ urls: [URL], progress: @escaping (Update) -> Void, done: @escaping (Int, Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            func report(_ update: Update) { DispatchQueue.main.async { progress(update) } }
            func fail(_ text: String) {
                DispatchQueue.main.async {
                    progress(Update(text: text, fraction: 0, speed: ""))
                    done(0, urls.count)
                }
            }

            guard Adb.path != nil else { return fail("adb не найден — brew install android-platform-tools") }
            guard Adb.connectedDevice() != nil else { return fail("Телефон не подключён") }

            let sizes = urls.map { max(byteSize(of: $0), 1) }
            let totalBytes = sizes.reduce(0, +)
            var finishedBytes: Int64 = 0

            // Скорость: экспоненциальное сглаживание по замерам не чаще 3 раз в секунду.
            var speed = 0.0
            var sampleTime = Date()
            var sampleBytes: Int64 = 0
            func measure(_ bytesDone: Int64) -> String {
                let elapsed = -sampleTime.timeIntervalSinceNow
                if elapsed >= 0.3 {
                    let instant = Double(bytesDone - sampleBytes) / elapsed
                    speed = speed == 0 ? instant : speed * 0.6 + instant * 0.4
                    sampleTime = Date()
                    sampleBytes = bytesDone
                }
                return formatSpeed(speed)
            }

            var sent = 0
            for (index, url) in urls.enumerated() {
                let name = url.lastPathComponent
                let dir = destinationDir(for: url)
                let size = sizes[index]
                let prefix = urls.count > 1 ? "\(index + 1)/\(urls.count) · " : ""
                report(Update(text: prefix + name,
                              fraction: Double(finishedBytes) / Double(totalBytes),
                              speed: formatSpeed(speed)))

                Adb.run(["shell", "mkdir", "-p", shellQuote(dir)])
                let remotePath = dir + "/" + Adb.freeName(dir: dir, name: name)
                let push = Adb.push(local: url.path, remote: remotePath) { percent in
                    let bytesDone = finishedBytes + Int64(Double(size) * Double(percent) / 100)
                    report(Update(text: prefix + name,
                                  fraction: Double(bytesDone) / Double(totalBytes),
                                  speed: measure(bytesDone)))
                }

                if push.ok {
                    sent += 1
                } else {
                    report(Update(text: "Ошибка: \(name)", fraction: Double(finishedBytes) / Double(totalBytes), speed: ""))
                }
                finishedBytes += size
                if push.ok { Adb.scanMedia(remotePath) }
                _ = measure(finishedBytes)
            }

            DispatchQueue.main.async {
                progress(Update(text: "", fraction: 1, speed: ""))
                done(sent, urls.count)
            }
        }
    }
}

// MARK: - Зона перетаскивания

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var isEnabled = true
    private var highlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, !urls(from: sender).isEmpty else { return [] }
        highlighted = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        needsDisplay = true
        let files = urls(from: sender)
        guard isEnabled, !files.isEmpty else { return false }
        onDrop?(files)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 6)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        path.stroke()
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let dropView = DropView(frame: NSRect(x: 16, y: 62, width: 288, height: 108))
    private let deviceLabel = label(frame: NSRect(x: 16, y: 178, width: 288, height: 16), size: 11, color: .secondaryLabelColor)
    private let hintLabel = label(frame: NSRect(x: 8, y: 44, width: 272, height: 20), size: 13, color: .labelColor)
    private let statusLabel = label(frame: NSRect(x: 16, y: 36, width: 288, height: 16), size: 11, color: .secondaryLabelColor)
    private let progressBar = NSProgressIndicator(frame: NSRect(x: 16, y: 20, width: 288, height: 8))
    private var busy = false

    private static func label(frame: NSRect, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.frame = frame
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        field.alignment = .center
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "iphone.and.arrow.forward", accessibilityDescription: "Send to Android")
                ?? NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: "Send to Android")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Файлы можно бросать прямо на иконку в трее.
            button.registerForDraggedTypes([.fileURL])
            button.window?.registerForDraggedTypes([.fileURL])
        }

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        dropView.onDrop = { [weak self] urls in self?.send(urls) }
        dropView.addSubview(hintLabel)
        content.addSubview(deviceLabel)
        content.addSubview(dropView)
        content.addSubview(statusLabel)
        content.addSubview(progressBar)

        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        // .applicationDefined — чтобы окно не закрывалось, когда мы уходим в Finder за файлом.
        popover.behavior = .applicationDefined
        popover.delegate = self

        resetLabels()
    }

    // MARK: Меню/окно

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let device = Adb.connectedDevice()
        menu.addItem(withTitle: device.map { "Устройство: \($0)" } ?? "Телефон не подключён", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            resetLabels()
            refreshDevice()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: false)
    }

    private func resetLabels() {
        guard !busy else { return }
        hintLabel.stringValue = "Перетащите файлы сюда"
        statusLabel.stringValue = "Фото → DCIM/Camera · видео → Movies · остальное → Download"
        progressBar.isHidden = true
        progressBar.doubleValue = 0
    }

    private func refreshDevice() {
        deviceLabel.stringValue = "Проверяю устройство…"
        DispatchQueue.global(qos: .userInitiated).async {
            let device = Adb.connectedDevice()
            DispatchQueue.main.async {
                if Adb.path == nil {
                    self.deviceLabel.stringValue = "adb не найден"
                } else {
                    self.deviceLabel.stringValue = device.map { "● \($0)" } ?? "○ телефон не подключён"
                }
            }
        }
    }

    // MARK: Отправка

    private func send(_ urls: [URL]) {
        guard !busy, !urls.isEmpty else { return }
        busy = true
        dropView.isEnabled = false
        hintLabel.stringValue = "Отправляю…"
        progressBar.isHidden = false
        progressBar.doubleValue = 0

        Transfer.send(urls) { [weak self] update in
            guard let self else { return }
            self.progressBar.doubleValue = update.fraction
            self.statusLabel.stringValue = [update.text, update.speed]
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
        } done: { [weak self] sent, total in
            guard let self else { return }
            self.busy = false
            self.dropView.isEnabled = true
            self.hintLabel.stringValue = sent == total ? "Готово: \(sent) шт." : "Отправлено \(sent) из \(total)"
            self.statusLabel.stringValue = ""
            NSSound(named: sent == total ? "Glass" : "Basso")?.play()
            self.notify(sent: sent, total: total)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.resetLabels() }
        }
    }

    private func notify(sent: Int, total: Int) {
        guard !popover.isShown else { return }
        let alert = NSAlert()
        alert.messageText = sent == total ? "Отправлено на телефон: \(sent)" : "Отправлено \(sent) из \(total)"
        alert.alertStyle = sent == total ? .informational : .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // Дроп на иконку в трее — обрабатывается тем же кодом.
    func handleDropOnStatusItem(_ urls: [URL]) { send(urls) }
}

// Перехватываем drag&drop на кнопку статус-бара.
extension NSStatusBarButton {
    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty,
              let delegate = NSApp.delegate as? AppDelegate else { return false }
        delegate.handleDropOnStatusItem(urls)
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
