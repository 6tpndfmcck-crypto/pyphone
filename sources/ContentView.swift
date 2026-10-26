import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct PyFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pythonScript, .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = decoded
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum WorkspaceTab: Hashable { case code, console, files }

struct ContentView: View {
    @StateObject private var runner = Runner()
    @StateObject private var scripts = ScriptStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("v2.appearance") private var appearance = "dark"
    @AppStorage("v2.fontSize") private var fontSize = 15.0
    @AppStorage("v2.autoIndent") private var autoIndent = true
    @State private var tab: WorkspaceTab = .code
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var showSettings = false
    @State private var showPackages = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var findRequest = 0
    @State private var lineRequest = 0
    @State private var targetLine = 1

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $tab) {
                editor.tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }.tag(WorkspaceTab.code)
                ConsolePane(runner: runner, fontSize: CGFloat(fontSize), goToError: canShowError ? goToError : nil)
                    .tabItem { Label("Console", systemImage: "terminal") }.tag(WorkspaceTab.console)
                ScriptsPane(store: scripts, openEditor: { tab = .code }, importFile: { showImporter = true },
                            openPackages: { showPackages = true })
                    .tabItem { Label("Files", systemImage: "folder") }.tag(WorkspaceTab.files)
            }
        }
        .background(Color(.systemGroupedBackground)).tint(.primary)
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "light" ? .light : .dark))
        .sheet(isPresented: $showSettings) { SettingsPane(runner: runner) }
        .sheet(isPresented: $showPackages) {
            PackagesPane(runner: runner) { spec in
                runner.run("pip install " + spec, name: "Package install")
                showPackages = false
                tab = .console
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pythonScript, .plainText, .text], onCompletion: handleImport)
        .fileExporter(isPresented: $showExporter, document: PyFile(text: scripts.code), contentType: .pythonScript,
                      defaultFilename: (scripts.name as NSString).deletingPathExtension) { result in
            if case .failure(let error) = result { scripts.error = "Couldn't export: " + error.localizedDescription }
        }
        .alert("Rename script", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { scripts.rename(renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("PyPhone", isPresented: Binding(get: { scripts.error != nil }, set: { if !$0 { scripts.error = nil } })) {
            Button("OK", role: .cancel) { scripts.error = nil }
        } message: { Text(scripts.error ?? "") }
        .onChange(of: scenePhase) { phase in
            if phase == .active { scripts.reloadFromFiles() } else { scripts.save() }
        }
        .onChange(of: runner.prompt) { prompt in if prompt != nil { tab = .console } }
        .onChange(of: scripts.name) { _ in lineRequest = 0; findRequest = 0; targetLine = 1 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(.primary)
                .frame(width: 42, height: 42).background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("PyPhone").font(.title3.bold())
                    Text("2").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.16), in: Capsule()).foregroundStyle(.primary)
                }
                Text(runner.executionStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 40, height: 44) }
                .accessibilityLabel("Settings")
            Button(action: runOrStop) {
                Label(runner.running ? "Stop" : "Run", systemImage: runner.running ? "stop.fill" : "play.fill")
                    .font(.subheadline.bold()).frame(minHeight: 28)
            }.buttonStyle(.borderedProminent).tint(runner.running ? .orange : .primary)
                .disabled(!runner.ready).accessibilityIdentifier("runButton")
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.primary)
                Text(scripts.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(scripts.isSaved ? "Saved" : "Saving…").font(.caption2).foregroundStyle(.secondary)
                Button { findRequest += 1 } label: { Image(systemName: "magnifyingglass").frame(width: 36, height: 40) }
                    .accessibilityLabel("Find and replace")
                Menu {
                    Button { if scripts.create() { tab = .code } } label: { Label("New script", systemImage: "doc.badge.plus") }
                    Button { showImporter = true } label: { Label("Import from Files", systemImage: "square.and.arrow.down") }
                    Button { renameText = scripts.name; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { scripts.duplicate() } label: { Label("Duplicate", systemImage: "doc.on.doc") }
                    Button { showPackages = true } label: { Label("Install Python package", systemImage: "shippingbox") }
                    Button { scripts.save(); showExporter = true } label: { Label("Export .py file", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 36, height: 40) }
                .accessibilityLabel("Script actions")
            }.padding(.leading, 14).padding(.trailing, 6)
            Divider()
            GeometryReader { viewport in
                CodeEditor(text: Binding(get: { scripts.code }, set: { scripts.edit($0) }),
                           fontSize: CGFloat(fontSize), autoIndent: autoIndent, findRequest: findRequest,
                           lineRequest: lineRequest, targetLine: targetLine)
                    .id(scripts.name).frame(width: viewport.size.width, height: viewport.size.height)
            }
            if !runner.widgets.isEmpty {
                Divider()
                window
                    .frame(minHeight: 140, maxHeight: 300)
            }
            Divider()
            HStack {
                Text("Python 3.13")
                Spacer()
                Text("\(scripts.code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }) lines")
            }.font(.caption2.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7)
        }
        .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.12)))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private var window: some View {
        Group {
            if runner.widgets.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.3.group").font(.system(size: 42)).foregroundStyle(.primary)
                    Text("Your program's window").font(.title2.bold())
                    Text("Labels, buttons, and images from ui appear here.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try the window example") {
                        if scripts.create(name: "my_window", text: Starter.code) { tab = .code }
                    }.buttonStyle(.borderedProminent)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("PROGRAM WINDOW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(runner.widgets) { WidgetView(w: $0, runner: runner) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
    }

    private var canShowError: Bool {
        runner.errorLine != nil && runner.runName == scripts.name && runner.runSource == scripts.code
    }
    private func goToError() { targetLine = runner.errorLine ?? 1; lineRequest += 1; tab = .code }
    private func runOrStop() {
        if runner.running { runner.stop(); return }
        guard scripts.save() else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        runner.run(scripts.code, name: scripts.name)
        tab = .console
    }
    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1024 * 1024 else { scripts.error = "Choose a script smaller than 2 MB."; return }
            let text = try String(contentsOf: url, encoding: .utf8)
            if scripts.create(name: url.lastPathComponent, text: text) { tab = .code }
        } catch { scripts.error = "Couldn't import the script: " + error.localizedDescription }
    }
}

struct WidgetView: View {
    let w: Widget
    @ObservedObject var runner: Runner
    var body: some View {
        switch w.kind {
        case "button":
            Button(w.text) { runner.tap(w.id) }.buttonStyle(.borderedProminent).disabled(runner.running)
        case "image":
            if let encoded = w.image_data, let data = Data(base64Encoded: encoded), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().interpolation(.none).scaledToFit()
                    .frame(maxWidth: 380, maxHeight: 620).frame(maxWidth: .infinity)
            } else { Text("Couldn't load image: " + w.text).foregroundStyle(.secondary) }
        case "entry":
            TextField(w.placeholder, text: Binding(get: { w.text }, set: { runner.setText(w.id, $0) })).textFieldStyle(.roundedBorder)
        default:
            Text(w.text).font(.system(size: 15, design: .monospaced)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
