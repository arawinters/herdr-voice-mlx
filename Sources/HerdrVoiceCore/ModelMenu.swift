/// The AI-model entries of the orb's right-click menu: one per local backend, then each cloud provider, in menu
/// order, the current one checked. Ones without an API key, or a local backend before it's set up, are shown but
/// disabled (so it's clear why they can't be picked).
public enum ModelMenu {
    public struct Entry: Equatable {
        public let provider: Provider
        /// Which local helper this entry starts; nil for a cloud provider.
        public let backend: LocalBackend?
        public let title: String
        public let checked: Bool
        public let enabled: Bool

        public init(provider: Provider, backend: LocalBackend? = nil, title: String, checked: Bool, enabled: Bool) {
            self.provider = provider
            self.backend = backend
            self.title = title
            self.checked = checked
            self.enabled = enabled
        }
    }

    public static func entries(current: Provider, currentBackend: LocalBackend, hasKey: (Provider) -> Bool,
                               localIsReady: (LocalBackend) -> Bool) -> [Entry] {
        Provider.menuOrder.flatMap { provider -> [Entry] in
            guard provider == .local else {
                let available = !provider.requiresAPIKey || hasKey(provider)
                return [Entry(provider: provider, title: provider.menuTitle + (available ? "" : " (no key)"),
                              checked: provider == current, enabled: available)]
            }
            return LocalBackend.menuOrder.map { backend in
                let ready = localIsReady(backend)
                return Entry(provider: .local, backend: backend, title: backend.menuTitle + (ready ? "" : " (not set up)"),
                             checked: current == .local && backend == currentBackend, enabled: ready)
            }
        }
    }
}
