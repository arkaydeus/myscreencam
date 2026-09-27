import Foundation
import SpeechCore
import Testing

@testable import MyScreenArt_Dev

nonisolated private final class TestSpeechEndpoint: NSObject, SpeechServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let holdRecognition: Bool
    private let recognitionStarted: DispatchSemaphore
    private var loaded: WorkerModelRole?
    private var requests: [WorkerRequest] = []

    init(holdRecognition: Bool, recognitionStarted: DispatchSemaphore) {
        self.holdRecognition = holdRecognition
        self.recognitionStarted = recognitionStarted
    }

    var received: [WorkerRequest] { lock.withLock { requests } }

    func perform(_ requestData: Data, reply: @escaping @Sendable (Data) -> Void) {
        let request = try! WorkerCoding.decode(WorkerRequest.self, from: requestData)
        if holdRecognition, case .recognise = request {
            lock.withLock { requests.append(request) }
            recognitionStarted.signal()
            return
        }
        let response: WorkerResponse = lock.withLock {
            requests.append(request)
            switch request {
            case .load(let role, _, _):
                loaded = role
                return .loaded(role: role, seconds: 0)
            case .unload, .shutdown:
                loaded = nil
                return .ok
            case .recognise(_, let window, _, _):
                guard loaded == .qwenRecogniser else {
                    return .failure(.noModelLoaded, message: "No recogniser")
                }
                return .recognised(
                    RecognisedWindow(
                        window: window, text: "word", languageTag: "en", units: [], termination: .complete,
                        processingSeconds: 0))
            default:
                return .ok
            }
        }
        reply(try! WorkerCoding.encode(response))
    }
}

nonisolated private final class TestSpeechListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let recognitionStarted = DispatchSemaphore(value: 0)
    private let holdRecognition: Bool
    private let lock = NSLock()
    private var endpoints: [TestSpeechEndpoint] = []

    init(holdRecognition: Bool = false) {
        self.holdRecognition = holdRecognition
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var services: [TestSpeechEndpoint] { lock.withLock { endpoints } }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let endpoint = TestSpeechEndpoint(
            holdRecognition: holdRecognition, recognitionStarted: recognitionStarted)
        lock.withLock { endpoints.append(endpoint) }
        connection.exportedInterface = NSXPCInterface(with: SpeechServiceProtocol.self)
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }
}

@MainActor
struct SpeechServiceClientTests {
    @Test func cancellationInvalidatesInFlightRequest() async throws {
        let server = TestSpeechListener(holdRecognition: true)
        defer { server.listener.invalidate() }
        let client = SpeechServiceClient { NSXPCConnection(listenerEndpoint: server.listener.endpoint) }
        defer { client.reset() }
        let window = WorkWindow(index: 0, owned: SampleRange(start: 0, end: 100), read: SampleRange(start: 0, end: 100))
        let request = Task {
            try await client.send(.recognise(audioPath: "/audio", window: window, languageHint: nil, tokenBudget: nil))
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: server.recognitionStarted.wait(timeout: .now() + 5))
            }
        }
        #expect(started == .success)
        request.cancel()
        await #expect(throws: TranscriptionError.cancelled) { try await request.value }
    }

    @Test func releaseReplaysLoadAndResetForgetsIt() async throws {
        let server = TestSpeechListener()
        defer { server.listener.invalidate() }
        let client = SpeechServiceClient { NSXPCConnection(listenerEndpoint: server.listener.endpoint) }
        defer { client.reset() }
        let window = WorkWindow(index: 0, owned: SampleRange(start: 0, end: 100), read: SampleRange(start: 0, end: 100))
        let load = WorkerRequest.load(role: .qwenRecogniser, directory: "/model", runtimeDirectory: "")
        _ = try await client.send(load)
        client.release()
        let replayed = try await client.send(
            .recognise(audioPath: "/audio", window: window, languageHint: nil, tokenBudget: nil))
        guard case .recognised = replayed else { Issue.record("Load was not replayed"); return }
        let services = server.services
        #expect(services.count == 2)
        #expect(services.last?.received.first == load)

        client.reset()
        let forgotten = try await client.send(
            .recognise(audioPath: "/audio", window: window, languageHint: nil, tokenBudget: nil))
        guard case .failure(let failure, _) = forgotten else { Issue.record("Reset replayed a load"); return }
        #expect(failure == .noModelLoaded)
    }
}
