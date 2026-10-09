import Foundation

/// A user's connection. Credentials remain in Keychain under this unchanged UUID.
public struct ProviderConnection: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String
    public var requiresAPIKey: Bool
    public var apiProtocol: APIProtocol
    public var authentication: AuthenticationMethod
    public var channelType: ChannelType
    public var textBackend: TextBackend
    public init(id: UUID = UUID(), name: String, kind: ProviderKind = .compatible, baseURL: String,
                requiresAPIKey: Bool = true, apiProtocol: APIProtocol = .automatic,
                authentication: AuthenticationMethod = .apiKey, channelType: ChannelType? = nil,
                textBackend: TextBackend = .builtIn) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL
        self.requiresAPIKey = requiresAPIKey; self.apiProtocol = apiProtocol; self.authentication = authentication
        self.channelType = channelType ?? ChannelType.infer(protocol: apiProtocol, authentication: authentication)
        self.textBackend = textBackend
    }
    public var credentialReference: UUID { id }
    public var service: AccessService {
        .init(channel: channelType, isSubscription: channelType.isSubscription)
    }
}
/// Service identity is distinct from the developer of any model it offers.
public struct AccessService: Equatable, Sendable {
    public var channel: ChannelType
    public var isSubscription: Bool
    public var name: String { channel.title }
}
public struct ProviderCatalog: Codable, Equatable, Sendable {
    public var models: [ModelOffering]
    public var discoveredAt: Date?
    public var thinkingSelections: [String: String]
    public init(models: [ModelOffering] = [], discoveredAt: Date? = nil, thinkingSelections: [String: String] = [:]) {
        self.models = models; self.discoveredAt = discoveredAt; self.thinkingSelections = thinkingSelections
    }
}
