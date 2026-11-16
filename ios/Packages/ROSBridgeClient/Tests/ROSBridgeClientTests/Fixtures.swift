import Foundation

enum Fixtures {
    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        else {
            throw NSError(
                domain: "Fixtures",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing \(name)"]
            )
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Fixture with its `id` rewritten so it matches a client-generated request id.
    static func text(_ name: String, id: String) throws -> String {
        var obj = try JSONSerialization.jsonObject(with: Data(text(name).utf8)) as? [String: Any] ?? [:]
        obj["id"] = id
        return try String(decoding: JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }
}
