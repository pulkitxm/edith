import EdithCore
import Observation

@MainActor
@Observable
final class ExtensionCatalogModel {
    var query = ""
    var category = ExtensionMarketplaceCategory.all
}
