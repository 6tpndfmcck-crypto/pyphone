import SwiftUI
import UniformTypeIdentifiers

enum Starter {
    static let code = #"""
from ui import label, entry, button

# Everything you draw appears in the Window tab.
name = entry("Your name")
greeting = label("")
count = label("Taps: 0")
taps = 0

def hello():
    greeting.set("Hello, " + (name.get() or "world") + "!")

def tap():
    global taps
    taps += 1
    count.set("Taps: " + str(taps))

button("Say hello", hello)
button("Tap me", tap)
print("It works. print() output shows below.")
"""#
}

struct PyFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pythonScript, .plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct ContentView: View {
    @StateObject private var runner = Runner()
    @AppStorage("code") private var code = Starter.code
    @State private var tab = 0
    @AppStorage("filename") private var filename = "script"
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var showReplace = false
    @State private var replaceText = ""
    @State private var replaceName = "script"
    @State private var errorMessage: String?
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(filename).py · \(runner.status)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    Button { ask(text: "", name: "untitled") } label: { Label("New blank file", systemImage: "doc") }
                    Button { showImporter = true } label: { Label("Open .py file…", systemImage: "folder") }
                    Button { showExporter = true } label: { Label("Export .py file…", systemImage: "square.and.arrow.up") }
                    Button { ask(text: Starter.code, name: "script") } label: { Label("Load example", systemImage: "sparkles") }
                } label: {
                    Text("File").padding(.horizontal, 6)
                }
                Button(runner.running ? "Stop ■" : "Run ▶") {
                    if runner.running {
                        runner.stop()
                    } else {
                        runner.run(code)
                        tab = 1
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!runner.ready)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pythonScript, .plainText, .text]) { result in
                handleImport(result)
            }
            .alert("Couldn't open file", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }

            Picker("", selection: $tab) {
                Text("Code").tag(0)
                Text("Window").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .fileExporter(isPresented: $showExporter, document: PyFile(text: code), contentType: .pythonScript, defaultFilename: filename) { result in
                if case .success(let url) = result {
                    filename = url.deletingPathExtension().lastPathComponent
                }
            }

            if tab == 0 {
                CodeEditor(text: $code)
                    .padding(.horizontal, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(runner.widgets) { w in
                            WidgetView(w: w, runner: runner)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                Divider()
                ScrollView {
                    Text(runner.output)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(Color(.secondarySystemBackground))
            }
        }
        .alert("Input", isPresented: Binding(get: { runner.prompt != nil }, set: { _ in })) {
            TextField("", text: $inputText)
            Button("OK") {
                runner.submitInput(inputText)
                inputText = ""
            }
            Button("Stop", role: .cancel) {
                runner.submitInput("")
                runner.stop()
            }
        } message: {
            Text(runner.prompt ?? "")
        }
        .confirmationDialog("Replace the current code?", isPresented: $showReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                code = replaceText
                filename = replaceName
            }
        } message: {
            Text("Export it first if you want to keep it.")
        }
    }

    private func ask(text: String, name: String) {
        let empty = code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty || code == text {
            code = text
            filename = name
        } else {
            replaceText = text
            replaceName = name
            showReplace = true
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let err):
            errorMessage = err.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                ask(text: s, name: url.deletingPathExtension().lastPathComponent)
            } else {
                errorMessage = "That file isn't readable as text."
            }
        }
    }
}

struct WidgetView: View {
    let w: Widget
    let runner: Runner

    var body: some View {
        switch w.kind {
        case "button":
            Button(w.text) { runner.tap(w.id) }
                .buttonStyle(.borderedProminent)
        case "entry":
            TextField(w.placeholder, text: Binding(
                get: { w.text },
                set: { runner.setText(w.id, $0) }
            ))
            .textFieldStyle(.roundedBorder)
        default:
            Text(w.text).font(.title3)
        }
    }
}
