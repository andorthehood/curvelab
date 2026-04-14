/// Generic Least-Recently-Used cache with a fixed capacity.
///
/// Not thread-safe — all accesses must happen on the same actor or thread.
/// `ImageViewModel` uses this exclusively from `@MainActor` context.
final class LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private var order: [Key] = []       // front = most recently used
    private var store: [Key: Value] = [:]

    init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be > 0")
        self.capacity = capacity
    }

    /// Returns the cached value for `key` and promotes it to most-recently-used.
    func get(_ key: Key) -> Value? {
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    /// Stores `value` under `key`, evicting the least-recently-used entry if needed.
    func set(_ key: Key, _ value: Value) {
        if store[key] != nil {
            touch(key)
        } else {
            if order.count >= capacity {
                let evicted = order.removeLast()
                store.removeValue(forKey: evicted)
            }
            order.insert(key, at: 0)
        }
        store[key] = value
    }

    // MARK: - Private

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
    }
}
