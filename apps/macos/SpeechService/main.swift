import Foundation
import MyScreenCamCore
import SpeechCore
import SpeechEngines

// `MyScreenCamSpeech.xpc`: the one owner of loaded speech models. Started on demand by the app; it exits when its
// connection goes away (the app cancelled, went idle, or quit), which is how every byte of Core ML / MLX memory is
// returned to the system. Requests are handled one at a time by `InferenceEngine`; `shutdown` is answered
// immediately, outside the engine.

let appBundleID = SpeechServiceIdentity.appBundleIdentifier(forService: Bundle.main.bundleIdentifier ?? "")
let engine = InferenceEngine(modelsRoot: ModelStore.defaultRoot(bundleIdentifier: appBundleID))

final class SpeechService: NSObject, SpeechServiceProtocol {
    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let response: WorkerResponse
        do {
            let decoded = try WorkerCoding.decode(WorkerRequest.self, from: request)
            if case .shutdown = decoded {
                reply((try? WorkerCoding.encode(WorkerResponse.ok)) ?? Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }
                return
            }
            Task {
                let response = await engine.handle(decoded)
                reply((try? WorkerCoding.encode(response)) ?? Data())
            }
            return
        } catch {
            response = .failure(.badRequest, message: "Undecodable request")
        }
        reply((try? WorkerCoding.encode(response)) ?? Data())
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only our own app (same signing team) may connect.
        connection.setCodeSigningRequirement(
            "anchor apple generic and certificate leaf[subject.OU] = \"\(Self.teamIdentifier)\"")
        connection.exportedInterface = NSXPCInterface(with: SpeechServiceProtocol.self)
        connection.exportedObject = SpeechService()
        // The host went away (cancel, idle recycle, quit, crash): drop everything by exiting.
        connection.invalidationHandler = { exit(0) }
        connection.interruptionHandler = { exit(0) }
        connection.resume()
        Log.app.info("Speech service connected")
        return true
    }

    static let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "MSCTeamIdentifier") as? String ?? "QWD87G9T3P"
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
