import SwiftUI
import UIKit

struct ConsolePane: View {
    @ObservedObject var runner: Runner
    let fontSize: CGFloat
    var goToError: (() -> Void)?
    @State private var input = ""
    @State private var followRequest = 0
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal").foregroundStyle(.primary)
                Text(runner.runName.isEmpty ? "Console" : runner.runName).font(.subheadline.bold()).lineLimit(1)
                Spacer()
                if let duration = runner.lastDuration {
                    Text(String(format: "%.2fs", duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Menu {
                    Button {
                        UIPasteboard.general.string = ANSIConsoleRenderer.render(runner.output, fontSize: fontSize).string
                    } label: { Label("Copy output", systemImage: "doc.on.doc") }.disabled(runner.output.isEmpty)
                    Button { runner.clearOutput() } label: { Label("Clear console", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 40, height: 44) }
                .accessibilityLabel("Console actions")
            }.padding(.leading, 14).padding(.trailing, 4)
            Divider()
            if runner.output.isEmpty && !runner.running {
                VStack(spacing: 12) {
                    Image(systemName: "terminal").font(.system(size: 36)).foregroundStyle(.primary)
                    Text("Ready for your next idea").font(.headline)
                    Text("Tap Run to see output here.").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { viewport in
                    TerminalView(output: runner.output, fontSize: fontSize, followRequest: followRequest)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                }
            }
            HStack {
                if let action = goToError, let line = runner.errorLine {
                    Button("Go to line \(line)", action: action).foregroundStyle(.orange)
                } else { Text(runner.executionStatus).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()

            }.font(.caption).padding(.horizontal, 14).padding(.vertical, 10)
            if let prompt = runner.prompt { inputBar(prompt) }
        }
        .background(Color(.systemBackground)).clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 10).padding(.bottom, 6)
        .onChange(of: runner.inputRequestID) { _ in prepareInput() }
        .onChange(of: runner.prompt) { prompt in
            if prompt != nil { prepareInput() } else { inputFocused = false }
        }
        .onAppear { if runner.prompt != nil { prepareInput() } }
    }

    private func inputBar(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(prompt.isEmpty ? "Your program is waiting for input" : prompt, systemImage: "keyboard")
                .font(.subheadline).lineLimit(3)
            HStack(spacing: 8) {
                TextField("Type your answer…", text: $input)
                    .textFieldStyle(.roundedBorder).font(.system(size: fontSize, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($inputFocused).submitLabel(.send).onSubmit(submit)
                    .accessibilityIdentifier("consoleInput")
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 44, height: 44) }
                    .accessibilityLabel("Send input")
            }
        }.padding(14).background(Color.primary.opacity(0.09))
    }
    private func prepareInput() { input = ""; inputFocused = true; followRequest += 1 }
    private func submit() {
        guard runner.prompt != nil else { return }
        let answer = input
        input = ""
        runner.submitInput(answer)
    }
}

struct ScriptsPane: View {
    @ObservedObject var store: ScriptStore
    let openEditor: () -> Void
    let importFile: () -> Void
    let openPackages: () -> Void
    @State private var search = ""
    @State private var deleting: SavedScript?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { if store.create() { openEditor() } } label: { Label("New script", systemImage: "plus") }
                        Spacer()
                        Button(action: importFile) { Label("Import", systemImage: "square.and.arrow.down") }
                    }.buttonStyle(.borderless).padding(.vertical, 4)
                    ForEach(store.scripts.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { script in
                        Button { if store.open(script.name) { openEditor() } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text").foregroundStyle(.primary).font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(script.name).foregroundStyle(.primary).font(.subheadline.weight(.medium))
                                    Text(script.modified, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if script.name == store.name { Image(systemName: "checkmark.circle.fill").foregroundStyle(.primary) }
                                Button(role: .destructive) { deleting = script } label: { Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 36, height: 36) }
                                    .buttonStyle(.borderless).accessibilityLabel("Delete \(script.name)")
                            }.padding(.vertical, 3)
                        }
                        .swipeActions { Button(role: .destructive) { deleting = script } label: { Label("Delete", systemImage: "trash") } }
                        .contextMenu { Button(role: .destructive) { deleting = script } label: { Label("Delete script", systemImage: "trash") } }
                    }
                } header: { Text("Your scripts") }
                  footer: { Text("Saved automatically. Also available in Files → On My iPhone → PyPhone → Files.") }
                Section { Button(action: openPackages) { Label("Python packages", systemImage: "shippingbox") } }
            }
            .listStyle(.insetGrouped).navigationTitle("Your workspace").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Find a script").onAppear { store.refreshList() }
            .confirmationDialog("Delete \(deleting?.name ?? "script")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete script", role: .destructive) {
                    if let script = deleting { store.delete(script) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { Text("This removes the saved script from PyPhone and Files.") }
        }
    }
}

struct SettingsPane: View {
    @ObservedObject var runner: Runner
    @Environment(\.dismiss) private var dismiss
    @AppStorage("v2.appearance") private var appearance = "dark"
    @AppStorage("v2.fontSize") private var fontSize = 15.0
    @AppStorage("v2.autoIndent") private var autoIndent = true
    var body: some View {
        NavigationStack {
            Form {
                Section("Make it yours") {
                    Picker("Appearance", selection: $appearance) {
                        Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system")
                    }
                    Stepper("Text size: \(Int(fontSize))", value: $fontSize, in: 11...24, step: 1)
                    Text("print(\"Hello, PyPhone\")").font(.system(size: fontSize, design: .monospaced)).foregroundStyle(.primary)
                    Toggle("Automatic indentation", isOn: $autoIndent)
                }
                Section("Python") {
                    Label(runner.status, systemImage: runner.ready ? "checkmark.circle" : "clock")
                        .font(.subheadline).textSelection(.enabled)
                    Text("Install packages from the Code actions menu or Files → Python packages.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("PyPhone 2") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0")
                    Text("Made for coding on your iPhone. Scripts autosave, input stays in the console, and Python UI appears with your code.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct PackagesPane: View {
    @ObservedObject var runner: Runner
    @Environment(\.dismiss) private var dismiss
    let install: (String) -> Void
    @State private var spec = ""
    private var trimmed: String { spec.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*(==[A-Za-z0-9][A-Za-z0-9.!+_-]*)?$"#, options: .regularExpression) != nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("package or package==version", text: $spec)
                        .font(.system(.body, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).onSubmit { if valid && runner.ready && !runner.running { install(trimmed) } }
                    Button { install(trimmed) } label: { Label("Install package", systemImage: "arrow.down.circle") }
                        .disabled(!valid || !runner.ready || runner.running)
                } header: { Text("Install from PyPI") }
                  footer: { Text("Pure-Python wheels only. Install dependencies separately. NumPy is already included; native packages need an app build.") }
                Section("Installed packages") {
                    if runner.packages.isEmpty { Text("No package list yet.").foregroundStyle(.secondary) }
                    ForEach(runner.packages) { package in
                        HStack {
                            Text(package.name); Spacer()
                            Text(package.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }.navigationTitle("Python packages").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onAppear { runner.refreshPackages() }
        }
    }
}
