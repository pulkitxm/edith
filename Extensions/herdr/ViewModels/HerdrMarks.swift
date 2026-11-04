import Observation

@MainActor
@Observable
final class HerdrMark<Value: Equatable> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@MainActor
final class HerdrMarks<Key: Hashable, Value: Equatable> {
    private var marks: [Key: HerdrMark<Value>] = [:]
    private let resolve: (Key) -> Value

    init(resolve: @escaping (Key) -> Value) {
        self.resolve = resolve
    }

    func value(_ key: Key) -> Value {
        if let mark = marks[key] { return mark.value }
        let mark = HerdrMark(resolve(key))
        marks[key] = mark
        return mark.value
    }

    func refresh() {
        for (key, mark) in marks {
            let next = resolve(key)
            if mark.value != next { mark.value = next }
        }
    }
}
