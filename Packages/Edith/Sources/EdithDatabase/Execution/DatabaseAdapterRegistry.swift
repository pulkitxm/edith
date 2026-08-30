import Foundation

struct DatabaseAdapterRegistry: Sendable {
    private let adaptersByProduct: [DatabaseProduct: any DatabaseAdapter]

    init(adapters: [any DatabaseAdapter]) throws(DatabaseAdapterFailure) {
        var adapterIDs = Set<DatabaseAdapterID>()
        var registered: [DatabaseProduct: any DatabaseAdapter] = [:]
        for adapter in adapters {
            try DatabaseAdapterBounds.validate(
                products: adapter.products,
                adapterID: adapter.id)
            guard adapterIDs.insert(adapter.id).inserted else {
                throw .contractViolation(.duplicateAdapterIdentifier(adapter.id))
            }
            for product in adapter.products {
                guard registered[product] == nil else {
                    throw .contractViolation(.duplicateProductRegistration(product))
                }
                registered[product] = adapter
            }
        }
        adaptersByProduct = registered
    }

    func adapter(for product: DatabaseProduct) throws(DatabaseAdapterFailure)
        -> any DatabaseAdapter
    {
        guard let adapter = adaptersByProduct[product] else {
            throw .contractViolation(.unsupportedProduct(product))
        }
        return adapter
    }

    func supports(_ product: DatabaseProduct) -> Bool {
        adaptersByProduct[product] != nil
    }
}
