import Citadel
import Foundation

/// Sorts Box errors for the File Provider and words them for the user.
public enum BoxErrors {
    public enum Kind: Sendable { case notFound, notAuthenticated, unreachable, failed }

    public static func kind(_ e: Error) -> Kind {
        if SFTPRemoteFileSystem.isNoSuchFile(e) { return .notFound }
        if e is NotConfigured || e is HostKeyMismatch || e is HostKeyNotStored || e is HostKeyStoreUnavailable { return .notAuthenticated }
        if case SSHClientError.allAuthenticationOptionsFailed? = e as? SSHClientError { return .notAuthenticated }
        // A refused or broken SFTP operation (the Box answered): the item cannot sync, the connection is fine.
        if e is SFTPMessage.Status || e is SFTPError || e is RemoteListFailed || e is UnsafePath || e is CocoaError { return .failed }
        return .unreachable
    }

    public static func message(_ e: Error) -> String {
        if case SSHClientError.allAuthenticationOptionsFailed? = e as? SSHClientError {
            return "Anmeldung an der Box abgelehnt: Benutzer oder Passwort falsch."
        }
        if let l = e as? LocalizedError, let d = l.errorDescription { return d }
        return "\(e)"
    }
}
