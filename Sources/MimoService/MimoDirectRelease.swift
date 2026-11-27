import Foundation

/// A single live supervisor owns each joined Direct transaction. The child checks
/// this record again under the final PF mutation before releasing networking.
struct MimoDirectReleaseRequest: Codable, Equatable, Sendable {
    let id: UUID
    let parentPID: Int32
    let parentIdentity: String
    let revision: Int

    func isCurrent(record: Self, parent: Int32, identity: String, savedRevision: Int,
                   mode: ProxyMode, maintenance: Bool, released: Bool) -> Bool {
        record == self && parentPID > 1 && parentPID == parent && parentIdentity == identity &&
            revision == savedRevision && mode == .direct && !maintenance && !released
    }
}

struct MimoDirectReleaseResult: Codable, Sendable {
    let id: UUID
    let completedAt: Date
    let nativeVerified: Bool
    var pfHealth: MimoPFHealthReceipt? = nil
}

/// The helper's individual operations have deadlines. Do not put a second
/// deadline around the parent: killing only the helper could abandon one of its
/// separately grouped children while that child still owns a network mutation.
/// Cancellation of a requesting task never abandons this physical join.
enum MimoJoinedDirectProcess {
    static func run(_ request: MimoDirectReleaseRequest, closingAfterFailure: Bool = false) throws -> MimoDirectReleaseResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MimoService.executable)
        process.arguments = [closingAfterFailure ? "--close-direct-failure" : "--restore-direct-online", request.id.uuidString]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        return try collect(process, request: request)
    }

    static func collect(_ process: Process, request: MimoDirectReleaseRequest) throws -> MimoDirectReleaseResult {
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let startedAt = Date.now
        do { try process.run() }
        catch {
            RuntimeLog.shared.error("mimo_direct_worker_result_invalid", fields: [
                "operation": request.id.uuidString, "parentPID": String(request.parentPID),
                "stage": "launch", "status": "-1", "receiptValid": "false"])
            throw MimoRuntimeError.unavailable("Direct cleanup could not start. Retry Direct or Stop engine.")
        }
        pipe.fileHandleForWriting.closeFile()
        var output = Data(), oversized = false
        while true {
            let part = pipe.fileHandleForReading.readData(ofLength: 4096)
            if part.isEmpty { break }
            if output.count + part.count <= 8192 { output.append(part) }
            else { oversized = true }
        }
        pipe.fileHandleForReading.closeFile()
        process.waitUntilExit()
        let result = try? JSONDecoder().decode(MimoDirectReleaseResult.self, from: output)
        let stage: String?
        if process.terminationReason != .exit || process.terminationStatus != 0 { stage = "exit" }
        else if oversized { stage = "output_limit" }
        else if result == nil { stage = "receipt_decode" }
        else if result?.id != request.id { stage = "receipt_owner" }
        else if let result, !result.completedAt.timeIntervalSince1970.isFinite || result.completedAt < startedAt || result.completedAt > Date.now { stage = "receipt_time" }
        else { stage = nil }
        if let stage {
            RuntimeLog.shared.error("mimo_direct_worker_result_invalid", fields: [
                "operation": request.id.uuidString, "parentPID": String(request.parentPID),
                "stage": stage, "status": String(process.terminationStatus),
                "receiptValid": String(result != nil)])
            throw MimoRuntimeError.unavailable("Direct cleanup did not complete. Retry Direct or Stop engine.")
        }
        return result!
    }
}
