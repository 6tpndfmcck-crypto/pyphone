import Foundation
import Combine

struct Widget: Identifiable, Decodable, Equatable {
    let id: Int
    let kind: String
    var text: String
    let placeholder: String
    let image_data: String?
    var image_revision: Int = 0
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
    private var pollTimer: Timer?
    private var lastImageUpdate = -Double.infinity
    private var runGeneration = 0
    private var consoleImageIDs: [Int] = []
    // Accessed only on pythonQueue. Keep latest snapshots across the separate
    // state/output reads, including an image whose marker arrives one poll later.
    private var fetchSequence = -1
    private var fetchedImages: [Int: Widget] = [:]
    private static let imageMarker = try! NSRegularExpression(pattern: "\u{001F}PYPHONE_IMAGE:([0-9]+)\u{001E}")
    private static let maxImages = 16
    private static let maxImageBytes = 32 * 1024 * 1024
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
                self.schedulePoll()
            }
        }
    }

    deinit { pollTimer?.invalidate() }

    private func schedulePoll() {
        pollTimer?.invalidate()
        // Run at up to 30 Hz while frames change, then return to the normal
        // idle cadence. One fetch at a time provides backpressure on slow phones.
        let animating = ProcessInfo.processInfo.systemUptime - lastImageUpdate < 0.5
        let timer = Timer(timeInterval: animating ? 1.0 / 30.0 : 0.2, repeats: false) { [weak self] _ in
            self?.poll()
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func run(_ code: String, name: String = "Script") {
        // Keep the Run button from queueing duplicate programs before the first
        // state poll returns from Python.
        guard ready, !running else { return }
        runGeneration += 1
        let generation = runGeneration
        lastSeq = -1
        lastImageUpdate = -Double.infinity
        output = ""
        consoleImageIDs.removeAll()
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
            fetchSequence = -1
            fetchedImages.removeAll()
            let r = PythonBridge.call("run_code", arg: code)
            let (st, out) = fetch()
            DispatchQueue.main.async {
                self.finish(st, extra: (r.hasPrefix("error:") ? r + "\n" : "") + out, fromEvent: true, generation: generation)
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
        consoleImageIDs.removeAll()
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
        let generation = runGeneration
        pythonQueue.async { [self] in
            _ = PythonBridge.call("send_event", arg: json)
            let (st, out) = fetch()
            DispatchQueue.main.async { self.finish(st, extra: out, fromEvent: true, generation: generation) }
        }
    }

    private func poll() {
        guard ready, !inFlight else { return }
        inFlight = true
        let generation = runGeneration
        pythonQueue.async { [self] in
            let (st, out) = fetch()
            DispatchQueue.main.async {
                self.inFlight = false
                self.finish(st, extra: out, fromEvent: false, generation: generation)
            }
        }
    }

    private func fetch() -> (PyState?, String) {
        let s = PythonBridge.call("get_state", arg: String(fetchSequence))
        let o = PythonBridge.call("take_output", arg: "")
        guard let state = try? JSONDecoder().decode(PyState.self, from: Data(s.utf8)) else { return (nil, o) }
        fetchSequence = state.seq
        let images = state.widgets.filter { $0.kind == "image" }
        let ids = Set(images.map(\.id))
        fetchedImages = fetchedImages.filter { ids.contains($0.key) }
        for image in images {
            if image.image_data != nil {
                fetchedImages[image.id] = image
            } else if let cached = fetchedImages[image.id], image.image_revision > cached.image_revision {
                // Newer revision plus null explicitly releases an evicted frame.
                fetchedImages.removeValue(forKey: image.id)
            }
        }
        let retained = Self.boundedImages(images.compactMap { fetchedImages[$0.id] })
        fetchedImages = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        let merged = state.widgets.map { widget -> Widget in
            guard widget.kind == "image", let cached = fetchedImages[widget.id],
                  cached.image_revision == widget.image_revision else { return widget }
            return cached
        }
        return (PyState(widgets: merged, running: state.running, prompt: state.prompt,
                        prompt_id: state.prompt_id, tid: state.tid, seq: state.seq, error_line: state.error_line), o)
    }

    private static func boundedImages(_ images: [Widget]) -> [Widget] {
        var result: [Widget] = []
        var bytes = 0
        for image in images.reversed() where image.image_data != nil {
            let count = image.image_data?.utf8.count ?? 0
            guard result.count < maxImages, bytes + count <= maxImageBytes else { continue }
            result.append(image)
            bytes += count
        }
        return Array(result.reversed())
    }

    private func updateConsoleImageIDs() {
        let text = output as NSString
        let ids = Self.imageMarker.matches(in: output, range: NSRange(location: 0, length: text.length))
            .compactMap { Int(text.substring(with: $0.range(at: 1))) }
        var seen = Set<Int>()
        consoleImageIDs = Array(ids.reversed().filter { seen.insert($0).inserted }.prefix(Self.maxImages).reversed())
    }

    private func finish(_ st: PyState?, extra: String, fromEvent: Bool, generation: Int) {
        defer { schedulePoll() }
        if fromEvent { pending -= 1 }
        guard generation == runGeneration else { return }
        if !extra.isEmpty {
            output = ConsoleBuffer.appending(extra, to: output)
            updateConsoleImageIDs()
        }
        guard let st = st else { return }
        let isRunning = pending == 0 ? st.running : (running || st.running)
        if running != isRunning { running = isRunning }
        // A new input can start before a poll ever sees the old prompt clear.
        // Compare request IDs, including when both prompts have identical text.
        promptID = st.prompt_id
        if inputRequestID != st.prompt_id { inputRequestID = st.prompt_id }
        let nextPrompt = st.prompt_id == submittedPromptID ? nil : st.prompt
        if prompt != nextPrompt { prompt = nextPrompt }
        if errorLine != st.error_line { errorLine = st.error_line }
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
        if st.seq >= lastSeq {
            // Images already emitted stay visible in the console even if
            // ui.clear() later removes the interactive window widgets.
            var images = Dictionary(uniqueKeysWithValues: inlineImages.map { ($0.id, $0) })
            for widget in st.widgets where widget.kind == "image" && consoleImageIDs.contains(widget.id) {
                if widget.image_data != nil {
                    images[widget.id] = widget
                } else if let old = images[widget.id], widget.image_revision > old.image_revision {
                    images.removeValue(forKey: widget.id)
                }
            }
            let nextImages = Self.boundedImages(consoleImageIDs.compactMap { images[$0] })
            let framesChanged = inlineImages.count != nextImages.count || zip(inlineImages, nextImages).contains {
                $0.0.id != $0.1.id || $0.0.image_revision != $0.1.image_revision
            }
            if framesChanged {
                inlineImages = nextImages
                imageRevision += 1
                if !nextImages.isEmpty { lastImageUpdate = ProcessInfo.processInfo.systemUptime }
            }
            // Image frames don't need to redraw the editor's interactive UI.
            let controls = st.widgets.filter { $0.kind != "image" }
            if widgets != controls { widgets = controls }
            lastSeq = st.seq
        }
    }
}


