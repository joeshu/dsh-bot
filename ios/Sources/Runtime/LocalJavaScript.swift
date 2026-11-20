import Foundation

actor LocalJavaScript {
    struct Result {
        let value: String
        let logs: [String]
        let error: String?
        var ok: Bool { error == nil }
    }

    private var isRunning = false

    func evaluate(_ script: String, timeoutMilliseconds: Int32 = 2_000) async -> Result {
        guard !isRunning else { return Result(value: "", logs: [], error: "已有脚本在运行。") }
        isRunning = true
        defer { isRunning = false }
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
