import Foundation
import Combine

struct SavedScript: Identifiable {
    var id: String { name }
    let name: String
    let modified: Date
}

/// Autosaved, Files-visible scripts. The v1 draft is copied once and retained in
/// defaults. A pending v2 draft survives termination before the debounce fires.
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [SavedScript] = []
    @Published private(set) var name = "untitled.py"
    @Published private(set) var code = ""
    @Published private(set) var isSaved = true
    @Published var error: String?

    let directory: URL
    private let defaults: UserDefaults
    private var saveTask: DispatchWorkItem?
    private var loadedText: String?

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Files", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            var preferred = defaults.string(forKey: "v2.activeScript")
            if !defaults.bool(forKey: "v2.migrated") {
                if let legacy = defaults.string(forKey: "code") {
                    let migrated = uniqueName(defaults.string(forKey: "filename") ?? "script")
                    try write(legacy, to: migrated)
                    preferred = migrated
                }
                defaults.set(true, forKey: "v2.migrated")
            }
            if let draft = defaults.string(forKey: "v2.draft.text"),
               let draftName = defaults.string(forKey: "v2.draft.name") {
                let safeName = Self.filename(draftName)
                let disk = try? String(contentsOf: url(safeName), encoding: .utf8)
                if disk != draft {
                    let recovered = uniqueName((safeName as NSString).deletingPathExtension + " recovered")
                    try write(draft, to: recovered)
                    preferred = recovered
                } else {
                    preferred = safeName
                }
                clearDraft()
            }
            refreshList()
            if scripts.isEmpty {
                let first = uniqueName("hello")
                try write(Starter.welcome, to: first)
                preferred = first
                refreshList()
            }
            let selected = scripts.first(where: { $0.name == preferred })?.name ?? scripts[0].name
            try load(selected)
        } catch {
            code = defaults.string(forKey: "v2.draft.text") ?? defaults.string(forKey: "code") ?? ""
            name = Self.filename(defaults.string(forKey: "v2.draft.name") ?? "recovered")
            isSaved = false
            self.error = "Your draft is still available, but scripts couldn't be opened: " + error.localizedDescription
        }
    }

    deinit { saveTask?.cancel() }

    static func filename(_ raw: String) -> String {
        var stem = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.lowercased().hasSuffix(".py") { stem = String(stem.dropLast(3)) }
        stem = String(stem.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) { return "_" }
            return Character(String(scalar))
        })
        stem = String(stem.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).prefix(80))
        return (stem.isEmpty ? "untitled" : stem) + ".py"
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(Self.filename(name)) }

    private func uniqueName(_ raw: String) -> String {
        let base = Self.filename(raw)
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: url(candidate).path) {
            candidate = String((base as NSString).deletingPathExtension.prefix(65)) + " \(number).py"
            number += 1
        }
        return candidate
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: url(name), atomically: true, encoding: .utf8)
    }

    private func load(_ name: String) throws {
        let text = try String(contentsOf: url(name), encoding: .utf8)
        self.name = name
        code = text
        loadedText = text
        isSaved = true
        defaults.set(name, forKey: "v2.activeScript")
    }

    private func clearDraft() {
        defaults.removeObject(forKey: "v2.draft.name")
        defaults.removeObject(forKey: "v2.draft.text")
    }

    func edit(_ text: String) {
        guard code != text else { return }
        code = text
        isSaved = false
        defaults.set(name, forKey: "v2.draft.name")
        defaults.set(text, forKey: "v2.draft.text")
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.save() }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    @discardableResult
    func save() -> Bool {
        saveTask?.cancel()
        guard !isSaved else { return true }
        do {
            // An edit made through Files must not be silently overwritten.
            let disk = try? String(contentsOf: url(name), encoding: .utf8)
            var destination = name
            if let disk = disk, disk != loadedText && disk != code {
                destination = uniqueName((name as NSString).deletingPathExtension + " recovered")
            }
            try write(code, to: destination)
            name = destination
            loadedText = code
            isSaved = true
            defaults.set(name, forKey: "v2.activeScript")
            clearDraft()
            refreshList()
            return true
        } catch {
            self.error = "Couldn't save \(name). Your draft is retained. " + error.localizedDescription
            return false
        }
    }

    func refreshList() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
            scripts = files.compactMap { file in
                guard file.pathExtension.lowercased() == "py",
                      Self.filename(file.lastPathComponent) == file.lastPathComponent,
                      let info = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
                return SavedScript(name: file.lastPathComponent, modified: info.contentModificationDate ?? .distantPast)
            }.sorted { $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified }
        } catch { self.error = "Couldn't read your scripts: " + error.localizedDescription }
    }

    func reloadFromFiles() {
        guard save() else { return }
        refreshList()
        if scripts.contains(where: { $0.name == name }) {
            do { try load(name) } catch { self.error = error.localizedDescription }
        }
    }

    @discardableResult
    func open(_ name: String) -> Bool {
        guard save() else { return false }
        do {
            try load(name)
            return true
        } catch {
            self.error = "Couldn't open \(name): " + error.localizedDescription
            return false
        }
    }

    @discardableResult
    func create(name: String = "untitled", text: String = "") -> Bool {
        guard save() else { return false }
        do {
            let destination = uniqueName(name)
            try write(text, to: destination)
            try load(destination)
            refreshList()
            return true
        } catch {
            self.error = "Couldn't create the script: " + error.localizedDescription
            return false
        }
    }

    func duplicate() { _ = create(name: (name as NSString).deletingPathExtension + " copy", text: code) }

    func rename(_ raw: String) {
        guard save() else { return }
        let destination = Self.filename(raw)
        guard destination != name else { return }
        guard !FileManager.default.fileExists(atPath: url(destination).path) else {
            error = "A script with that name already exists. Choose another name."
            return
        }
        do {
            try FileManager.default.moveItem(at: url(name), to: url(destination))
            name = destination
            defaults.set(name, forKey: "v2.activeScript")
            refreshList()
        } catch { self.error = "Couldn't rename the script: " + error.localizedDescription }
    }

    func delete(_ script: SavedScript) {
        guard save() else { return }
        do {
            try FileManager.default.removeItem(at: url(script.name))
            refreshList()
            if script.name == name {
                if let next = scripts.first { try load(next.name) }
                else { _ = create() }
            }
        } catch { self.error = "Couldn't delete the script: " + error.localizedDescription }
    }
}
