import Foundation
import Combine

struct Widget: Identifiable, Decodable {
    let id: Int
    let kind: String
    var text: String
    let placeholder: String
    let image_data: String?
}

struct PyState: Decodable {
    let widgets: [Widget]
    let running: Bool
    let prompt: String?
    let prompt_id: Int
    let tid: Int
    let seq: Int
    let error_line: Int?
}

struct PythonPackage: Identifiable, Decodable {
    var id: String { name.lowercased() }
    let name: String
    let version: String
}

final class Runner: ObservableObject {
    @Published var widgets: [Widget] = []
    @Published private(set) var inlineImages: [Widget] = []
    @Published private(set) var imageRevision = 0
    @Published var output = ""
    @Published var status = "Starting Python…"
    @Published var running = false
    @Published var prompt: String? = nil
    @Published private(set) var inputRequestID = 0
    @Published private(set) var errorLine: Int?
    @Published private(set) var lastDuration: TimeInterval?
    @Published private(set) var runName = ""
    @Published private(set) var packages: [PythonPackage] = []
    private(set) var runSource = ""
    private var startedAt: Date?

    var executionStatus: String {
        if !ready { return status }
        if prompt != nil { return "Waiting for input" }
        if running { return "Running…" }
        if errorLine != nil { return "Check the console" }
        return lastDuration == nil ? "Ready to code" : "Finished"
    }

    private(set) var ready = false
    private var pending = 0
    private var lastSeq = -1
    private var tid = 0
    private var inFlight = false
    private var promptID = 0
    private var submittedPromptID: Int?
    private var stopRequested = false
    // All native-to-Python calls share one serial queue. A state read and its
    // matching output read must not interleave with another poll or UI event.
    private let pythonQueue = DispatchQueue(label: "py.bridge")
    // Keep Stop/input independent of state polling and startup work.
    private let controlQueue = DispatchQueue(label: "py.control")

    init() {
        if let err = PythonBridge.start() {
            status = "Python failed: \(err)"
            return
        }

        // Importing NumPy can take noticeable time on first launch. Keep that
        // work off the main thread so the editor can render and show status.
        status = "Checking Python and NumPy…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PythonBridge.call("check_runtime", arg: "")
            DispatchQueue.main.async {
                guard let self = self else { return }
                if result.hasPrefix("error:") {
                    let detail = result.hasPrefix("error: ")
                        ? String(result.dropFirst("error: ".count))
                        : result
                    self.status = "Python failed: \(detail)"
                    return
                }

                self.ready = true
                self.status = result
                Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    self?.poll()
                }
            }
        }
    }

    func run(_ code: String, name: String = "Script") {
        // Keep the Run button from queueing duplicate programs before the first
        // state poll returns from Python.
        guard ready, !running else { return }
        output = ""
        inlineImages.removeAll()
        imageRevision += 1
        prompt = nil
        errorLine = nil
        lastDuration = nil
        startedAt = Date()
        runName = name
        runSource = code
        running = true
        tid = 0
        stopRequested = false
        pending += 1
        pythonQueue.async { [self] in
            let r = PythonBridge.call("run_code", arg: code)
            let (st, out) = fetch()
            DispatchQueue.main.async {
                self.finish(st, extra: (r.hasPrefix("error:") ? r + "\n" : "") + out, fromEvent: true)
            }
        }
    }

    func stop() {
        guard running else { return }
        guard tid != 0 else {
            // The Python worker may not have published its thread ID yet.
            // Defer the interrupt until the next state response supplies it.
            stopRequested = true
            return
        }
        let t = UInt(tid)
        stopRequested = false
        controlQueue.async { PythonBridge.stopThread(t) }
    }

    func submitInput(_ text: String) {
        guard prompt != nil else { return }
        let payload: [String: Any] = ["prompt_id": promptID, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        submittedPromptID = promptID
        prompt = nil
        controlQueue.async { _ = PythonBridge.call("input_reply", arg: json) }
    }

    func tap(_ id: Int) { send(id, "tap", "") }

    func clearOutput() {
        output = ""
        inlineImages.removeAll()
        imageRevision += 1
    }

    func refreshPackages() {
        guard ready else { return }
        pythonQueue.async { [weak self] in
            let result = PythonBridge.call("list_packages", arg: "")
            guard let packages = try? JSONDecoder().decode([PythonPackage].self, from: Data(result.utf8)) else { return }
            DispatchQueue.main.async { self?.packages = packages }
        }
    }

    func setText(_ id: Int, _ text: String) {
        if let i = widgets.firstIndex(where: { $0.id == id }) { widgets[i].text = text }
        send(id, "change", text)
    }

    private func send(_ id: Int, _ kind: String, _ value: String) {
        guard ready else { return }
        if kind == "tap", running { return }
        let payload: [String: Any] = ["id": id, "kind": kind, "value": value]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        if kind == "tap" {
            running = true
            errorLine = nil
            lastDuration = nil
            startedAt = Date()
            tid = 0
            stopRequested = false
        }
        pending += 1
        pythonQueue.async { [self] in
            _ = PythonBridge.call("send_event", arg: json)
            let (st, out) = fetch()
            DispatchQueue.main.async { self.finish(st, extra: out, fromEvent: true) }
        }
    }

    private func poll() {
        guard ready, !inFlight else { return }
        inFlight = true
        pythonQueue.async { [self] in
            let (st, out) = fetch()
            DispatchQueue.main.async {
                self.inFlight = false
                self.finish(st, extra: out, fromEvent: false)
            }
        }
    }

    private func fetch() -> (PyState?, String) {
        let s = PythonBridge.call("get_state", arg: "")
        let o = PythonBridge.call("take_output", arg: "")
        return (try? JSONDecoder().decode(PyState.self, from: Data(s.utf8)), o)
    }

    private func finish(_ st: PyState?, extra: String, fromEvent: Bool) {
        if fromEvent { pending -= 1 }
        if !extra.isEmpty {
            output = ConsoleBuffer.appending(extra, to: output)
        }
        guard let st = st else { return }
        if pending == 0 {
            running = st.running
        } else if st.running {
            running = true
        }
        // A new input can start before a poll ever sees the old prompt clear.
        // Compare request IDs, including when both prompts have identical text.
        promptID = st.prompt_id
        inputRequestID = st.prompt_id
        prompt = st.prompt_id == submittedPromptID ? nil : st.prompt
        errorLine = st.error_line
        if !running, let start = startedAt {
            lastDuration = Date().timeIntervalSince(start)
            startedAt = nil
        }
        tid = st.tid
        if stopRequested {
            if tid != 0 {
                let target = UInt(tid)
                stopRequested = false
                controlQueue.async { PythonBridge.stopThread(target) }
            } else if pending == 0 && !st.running {
                stopRequested = false
            }
        }
        if pending == 0 && st.seq >= lastSeq {
            // Images already emitted stay visible in the console even if
            // ui.clear() later removes the interactive window widgets.
            for widget in st.widgets where widget.kind == "image" {
                if let index = inlineImages.firstIndex(where: { $0.id == widget.id }) {
                    if inlineImages[index].image_data != widget.image_data {
                        inlineImages[index] = widget
                        imageRevision += 1
                    }
                } else {
                    inlineImages.append(widget)
                    imageRevision += 1
                }
            }
            // Limit retained image data to avoid runaway memory usage.
            if inlineImages.count > 16 {
                inlineImages.removeFirst(inlineImages.count - 16)
                imageRevision += 1
            }
            widgets = st.widgets
            lastSeq = st.seq
        }
    }
}


