public import HTTPCore

/// Settings a ``Server`` captures once, at construction (docs/ROADMAP.md §3: an immutable
/// `Sendable` value, never an actor hop per request).
public struct ServerConfiguration: Sendable, Hashable {
    /// What happens to a connection that arrives while ``maxConnections`` are open.
    public enum ConnectionLimitPolicy: Sendable, Hashable {
        /// Stop pulling from the listener until a connection closes. New connections wait in
        /// the listener's bounded pending queue; the listener refuses those beyond its bound.
        case backpressure
        /// Keep accepting and close each connection over the limit at once, without starting
        /// any work for it.
        case refuse
    }

    /// Most connections served at once (#0024).
    public var maxConnections: Int
    /// Behaviour at ``maxConnections``.
    public var connectionLimitPolicy: ConnectionLimitPolicy
    /// How long a graceful shutdown waits for open connections before cancelling them.
    /// `nil` waits indefinitely.
    public var drainTimeout: Duration?
    /// How long a cleartext connection may take to send enough bytes for the protocol registry
    /// to pick a protocol, when more than one protocol is registered (#0088). `nil` waits
    /// indefinitely. Defaults to the HTTP/1.1 header timeout.
    public var sniffTimeout: Duration?

    public init(
        maxConnections: Int = 1024,
        connectionLimitPolicy: ConnectionLimitPolicy = .backpressure,
        drainTimeout: Duration? = .seconds(10),
        sniffTimeout: Duration? = .seconds(10)
    ) {
        self.maxConnections = maxConnections
        self.connectionLimitPolicy = connectionLimitPolicy
        self.drainTimeout = drainTimeout
        self.sniffTimeout = sniffTimeout
    }

    /// Throws ``ServerError/invalidConfiguration(_:)`` when a value is out of range.
    public func validate() throws(ServerError) {
        guard maxConnections > 0 else {
            throw .invalidConfiguration("maxConnections must be positive (got \(maxConnections))")
        }
        if let drainTimeout, drainTimeout < .zero {
            throw .invalidConfiguration("drainTimeout must not be negative")
        }
        if let sniffTimeout, sniffTimeout <= .zero {
            throw .invalidConfiguration("sniffTimeout must be positive")
        }
    }
}

/// Errors thrown by ``Server``.
public enum ServerError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A configuration value is out of range.
    case invalidConfiguration(String)
    /// `run()` was called on a server that already ran (or is running).
    case alreadyStarted
    /// The server has no protocols to serve connections with.
    case noProtocols
    /// A restart (#0144) was asked of a server that is not running.
    case notRunning
    /// A restart (#0144) was asked while another one was binding.
    case restartInProgress

    public var description: String {
        switch self {
        case .invalidConfiguration(let message): "invalid configuration: \(message)"
        case .alreadyStarted: "the server was already started"
        case .noProtocols: "no connection protocols are registered"
        case .notRunning: "the server is not running"
        case .restartInProgress: "a restart is already in progress"
        }
    }
}

/// A graceful restart (#0144) failed because a listener of the new generation could not be
/// made or bound. The running listeners keep serving, except the one named by
/// ``closedRunningListener`` (a listener that could not share its address had to close before
/// its replacement could bind).
public struct ServerRestartError: Error, CustomStringConvertible {
    /// The new listener's ``ServerListener/name``.
    public var listener: String
    /// The address it was to bind, when known.
    public var address: TransportAddress?
    /// What the listener (or its `make` closure) threw.
    public var underlying: any Error
    /// The name of a running listener closed for the replacement that then failed: it no
    /// longer serves. `nil` when every running listener still serves.
    public var closedRunningListener: String?

    public init(listener: String, address: TransportAddress?, underlying: any Error, closedRunningListener: String? = nil) {
        self.listener = listener
        self.address = address
        self.underlying = underlying
        self.closedRunningListener = closedRunningListener
    }

    public var description: String {
        var text = "listener \(listener)"
        if let address { text += " on \(address)" }
        text += ": \(underlying)"
        if let closedRunningListener {
            text += "; the running listener \(closedRunningListener) had to close first and no longer serves"
        } else {
            text += "; the running listeners keep serving"
        }
        return text
    }
}
