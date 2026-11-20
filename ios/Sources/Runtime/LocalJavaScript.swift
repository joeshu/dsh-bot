import Foundation

struct LocalJavaScript {
    struct Result {
        let value: String
        let logs: [String]
        let error: String?
        var ok: Bool { error == nil }
    }

    func evaluate(_ script: String, timeoutMilliseconds: Int32 = 2_000) async -> Result {
        let task = Task.detached(priority: .userInitiated) {
            script.withCString { source -> Result in
                let result = dsbot_evaluate_javascript(source, script.utf8.count, timeoutMilliseconds)
                defer { dsbot_free_javascript_result(result) }
                return Result(
                    value: result.value.map { String(cString: $0) } ?? "",
                    logs: result.logs.map { String(cString: $0).split(separator: "\n").map(String.init) } ?? [],
                    error: result.error.map { String(cString: $0) }
                )
            }
        }
        return await task.value
    }
}
