import Darwin
import Foundation

/// Runs fixed, read-only system commands off the actor. No shell or client-supplied executable.
enum BoundedProcess {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2, captureError: Bool = false,
                    input: Data? = nil, outputLimit: Int = 65536) -> (text: String, status: Int32) {
        guard (input?.count ?? 0) <= 1_048_576, (1...1_048_576).contains(outputLimit) else { return ("", 126) }
        // A socket pair supports per-descriptor SIGPIPE suppression. Feed stdin while
        // draining stdout so a stalled reader or full output pipe cannot deadlock us.
        var inputSockets: [Int32] = [-1, -1]
        if input != nil {
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &inputSockets) == 0 else { return ("", -1) }
            var enabled: Int32 = 1
            guard setsockopt(inputSockets[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  fcntl(inputSockets[0], F_SETFL, O_NONBLOCK) == 0 else {
                close(inputSockets[0]); close(inputSockets[1]); return ("", -1)
            }
        }
        defer { for descriptor in inputSockets where descriptor >= 0 { close(descriptor) } }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return ("", -1) }
        defer { close(descriptors[0]) }
        let null = open("/dev/null", O_RDWR)
        guard null >= 0 else { close(descriptors[1]); return ("", -1) }
        defer { close(null) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { close(descriptors[1]); return ("", -1) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { close(descriptors[1]); return ("", -1) }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input == nil ? null : inputSockets[1], STDIN_FILENO)
        if input != nil {
            posix_spawn_file_actions_addclose(&actions, inputSockets[0])
            posix_spawn_file_actions_addclose(&actions, inputSockets[1])
        }
        posix_spawn_file_actions_adddup2(&actions, captureError ? descriptors[1] : null, STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawn_file_actions_addclose(&actions, null)
        // Each probe has its own group so timeout also terminates sudo and its child CLI.
        // Concurrent probes must not inherit another probe's pipe/socket ends:
        // an inherited stdin writer prevents EOF and can stall pfctl or mihomo
        // until an unrelated network request exits. Only explicit stdio actions
        // below may survive into the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"]
        let env = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawn = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, environment.baseAddress!)
            }
        }
        close(descriptors[1])
        if inputSockets[1] >= 0 { close(inputSockets[1]); inputSockets[1] = -1 }
        guard spawn == 0 else { return ("", -1) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var output = Data(), bytes = [UInt8](repeating: 0, count: 4096), status: Int32 = 0
        var inputOffset = 0, inputFailed = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            if let input, inputSockets[0] >= 0 {
                if inputOffset < input.count {
                    let written = input.withUnsafeBytes { buffer in
                        write(inputSockets[0], buffer.baseAddress!.advanced(by: inputOffset), min(16384, input.count - inputOffset))
                    }
                    if written > 0 { inputOffset += written }
                    else if written < 0 && errno != EAGAIN && errno != EINTR { inputFailed = true }
                }
                if inputOffset == input.count || inputFailed {
                    close(inputSockets[0]); inputSockets[0] = -1
                }
            }
            var count = read(descriptors[0], &bytes, bytes.count)
            while count > 0 {
                output.append(contentsOf: bytes.prefix(count))
                if output.count > outputLimit { break }
                count = read(descriptors[0], &bytes, bytes.count)
            }
            if output.count > outputLimit || ContinuousClock.now >= deadline {
                kill(-pid, SIGTERM)
                Thread.sleep(forTimeInterval: 0.1)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                return ("", output.count > outputLimit ? 125 : 124)
            }
            if waitpid(pid, &status, WNOHANG) == pid {
                // Drain bytes written just before the child exited.
                count = read(descriptors[0], &bytes, bytes.count)
                while count > 0 && output.count <= outputLimit {
                    output.append(contentsOf: bytes.prefix(count))
                    count = read(descriptors[0], &bytes, bytes.count)
                }
                guard output.count <= outputLimit else { return ("", 125) }
                guard !inputFailed, inputOffset == (input?.count ?? 0) else { return ("", 126) }
                return (String(data: output, encoding: .utf8) ?? "", status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

