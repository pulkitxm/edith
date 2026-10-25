enum VideoSampleTransfer {
    static func run<Sample>(
        validate: () throws -> Void,
        readNext: () throws -> Sample?,
        isReady: () -> Bool,
        waitForReadiness: () async throws -> Void,
        append: (Sample) throws -> Void,
        finish: () -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            try validate()
            let sample = try readNext()
            try Task.checkCancellation()
            try validate()
            guard let sample else {
                finish()
                return
            }
            while !isReady() {
                try Task.checkCancellation()
                try validate()
                try await waitForReadiness()
                try Task.checkCancellation()
                try validate()
            }
            try Task.checkCancellation()
            try validate()
            try append(sample)
        }
    }
}
