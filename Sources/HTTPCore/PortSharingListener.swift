/// A listener whose address a replacement listener can bind while both are open, so a
/// graceful restart (#0144) never leaves the address without a listener. On BSD sockets this
/// is `SO_REUSEPORT`, set only for the moment of the swap: the kernel sends new connections to
/// the newest socket, and a third socket that does not ask for sharing still gets
/// `EADDRINUSE`.
///
/// `HTTPServer.Server.restart(...)` uses it when a listener of the new generation binds the
/// address of a running one that conforms: it turns sharing on for both, binds the new one,
/// turns sharing off again, and retires the old one with ``closeAfterPending()``.
/// `NetworkTransport.BSDSocketListener` conforms. Network.framework listeners cannot share an
/// address, so the server hands those over to the new generation instead.
public protocol PortSharingListener: Sendable {
    /// Before the listener binds: bind with sharing on (it then joins a listener that has
    /// sharing on, and still fails against one that has not). After it binds: allow (or stop
    /// allowing) another listener that asks for sharing to bind the same address.
    func setPortSharing(_ enabled: Bool)

    /// Stops listening without dropping connections the system already accepted: they stay
    /// available to ``TransportListener/connections``, which then ends. Use it once a
    /// replacement listener has the address, so connections queued on this one are served
    /// rather than reset. Idempotent; ``TransportListener/close()`` afterwards closes any
    /// connection still not taken.
    func closeAfterPending() async
}
