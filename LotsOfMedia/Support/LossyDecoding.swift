import Foundation

/// Plex JSON is not always consistent about numeric/bool types across server
/// versions (e.g. "1" vs 1, 0/1 vs true/false). These helpers decode leniently.
extension KeyedDecodingContainer {
    func lossyInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(String.self, forKey: key) { return Int(v) ?? Double(v).map { Int($0) } }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v ? 1 : 0 }
        return nil
    }

    func lossyInt64(_ key: Key) -> Int64? {
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(String.self, forKey: key) { return Int64(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int64(v) }
        return nil
    }

    func lossyDouble(_ key: Key) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(String.self, forKey: key) { return Double(v) }
        return nil
    }

    func lossyString(_ key: Key) -> String? {
        if let v = try? decodeIfPresent(String.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return String(v) }
        return nil
    }

    func lossyBool(_ key: Key) -> Bool? {
        if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v != 0 }
        if let v = try? decodeIfPresent(String.self, forKey: key) { return v == "1" || v.lowercased() == "true" }
        return nil
    }

    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        (try? decodeIfPresent([T].self, forKey: key)) ?? []
    }
}
