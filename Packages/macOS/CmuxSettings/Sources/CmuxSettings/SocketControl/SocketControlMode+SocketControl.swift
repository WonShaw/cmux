
public extension SocketControlMode {
    /// The POSIX permission bits to apply to the socket file for this mode.
    ///
    /// Always `0o600`: only the owner may connect.
    var socketFilePermissions: UInt16 {
        // comux: the socket is always private to the owner, including in
        // `allowAll` mode, so other local accounts can never connect.
        0o600
    }

    /// Whether this mode requires a password handshake before commands are accepted.
    var requiresPasswordAuth: Bool {
        self == .password
    }
}
