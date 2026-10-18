import SwiftUI

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

struct ContentView: View {
    @StateObject private var runner = Runner()
    @AppStorage("code") private var code = Starter.code
    @State private var tab = 0
    @State private var confirmReset = false
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(runner.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { confirmReset = true }
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

            Picker("", selection: $tab) {
                Text("Code").tag(0)
                Text("Window").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if tab == 0 {
                TextEditor(text: $code)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 8)
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
        .confirmationDialog("Reset to the starter code?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { code = Starter.code }
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
