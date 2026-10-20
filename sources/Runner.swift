import Foundation

struct Widget: Identifiable, Decodable {
    let id: Int
    let kind: String
    var text: String
    let placeholder: String
}

struct PyState: Decodable {
    let widgets: [Widget]
    let running: Bool
    let prompt: String?
    let tid: Int
    let seq: Int
}

final class Runner: ObservableObject {
    @Published var widgets: [Widget] = []
    @Published var output = ""
    @Published var status = "Starting Python…"
    @Published var running = false
    @Published var prompt: String? = nil

    private(set) var ready = false
    private var pending = 0
    private var lastSeq = -1
    private var tid = 0
    private var inFlight = false
    // All native-to-Python calls share one serial queue. A state read and its
    // matching output read must not interleave with another poll or UI event.
    private let pythonQueue = DispatchQueue(label: "py.bridge")
    // Control calls must remain independent so Stop/input can interrupt or
    // resume a Python callback that is currently occupying pythonQueue.
    private let controlQueue = DispatchQueue(label: "py.control")

    init() {
        if let err = PythonBridge.start() {
            status = "Python failed: \(err)"
        } else {
            ready = true
            status = "Python ready"
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
    }

    func run(_ code: String) {
        guard ready else { return }
        output = ""
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
        guard tid != 0 else { return }
        let t = UInt(tid)
        controlQueue.async { PythonBridge.stopThread(t) }
    }

    func submitInput(_ text: String) {
        prompt = nil
        controlQueue.async { _ = PythonBridge.call("input_reply", arg: text) }
    }

    func tap(_ id: Int) { send(id, "tap", "") }

    func setText(_ id: Int, _ text: String) {
        if let i = widgets.firstIndex(where: { $0.id == id }) { widgets[i].text = text }
        send(id, "change", text)
    }

    private func send(_ id: Int, _ kind: String, _ value: String) {
        guard ready else { return }
        let payload: [String: Any] = ["id": id, "kind": kind, "value": value]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
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
        output += extra
        guard let st = st else { return }
        running = st.running
        prompt = st.prompt
        tid = st.tid
        if pending == 0 && st.seq >= lastSeq {
            widgets = st.widgets
            lastSeq = st.seq
        }
    }
}
