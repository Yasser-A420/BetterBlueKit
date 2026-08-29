//
//  SessionStore.swift
//  BBCLI
//
//  Remembers just enough between runs that an MFA-gated account doesn't
//  challenge on every launch.
//
//  The CLI used to throw away three things each run, and each one on its
//  own is enough to force a fresh MFA prompt:
//
//    * The DEVICE ID. `KiaUSAAPIClient` reads `configuration.deviceId` in
//      its initializer and falls back to a brand-new UUID. With nothing
//      persisted, every launch looked like a device the account had never
//      seen — and a new device is exactly what an MFA challenge is for.
//
//      The id still has to come from `registerDevice()` on the first run,
//      NOT from a UUID minted here: the two European clients override it
//      to POST `notifications/register` and adopt a SERVER-issued id,
//      which they then send as `ccsp-device-id` on every request. What
//      this store adds is persisting that id and handing it back through
//      the configuration on later runs — plus, for Kia US specifically,
//      rebuilding the client with it, since that client copies
//      `configuration.deviceId` into a `let` at init and so ignores an id
//      registered afterwards.
//    * The REMEMBER-ME TOKEN. `verifyMFACode` hands one back and the CLI
//      passed it straight to `completeMFALogin` and dropped it, so the
//      next run had nothing to present.
//    * The AUTH TOKEN. Kia sessions last 23 hours; re-logging in on every
//      launch was throwing away most of that.
//
//  What is stored, and what is NOT: the device id, the remember-me token
//  and the auth token — all of which are live credentials for the
//  account. The password and PIN are deliberately never written. The file
//  is created 0600 inside a 0700 directory, and lives under the user's
//  home rather than the repo so it cannot be committed by accident.
//
//  `bbcli --forget` clears it.
//

import BetterBlueKit
import Foundation

/// What one account's saved session holds.
struct CLISession: Codable {
    /// Stable per-account device identity. Generated once, then reused —
    /// this is the field that stops the MFA loop.
    var deviceId: String?
    /// The long-lived credential the backend issues after a successful
    /// MFA verification, and rotates from time to time.
    var rememberMeToken: String?
    /// The short-lived session. Reused while it's still valid so a run
    /// inside the window skips login entirely.
    var authToken: AuthToken?
}

enum SessionStore {

    // MARK: - Location

    private static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bbcli", isDirectory: true)
    }

    private static var file: URL {
        directory.appendingPathComponent("sessions.json")
    }

    /// One entry per account. Username is lowercased because the backends
    /// treat it case-insensitively and we don't want two entries — and two
    /// device identities — for the same login typed differently.
    static func key(brand: Brand, region: Region, username: String) -> String {
        "\(brand.rawValue):\(region.rawValue):\(username.lowercased())"
    }

    // MARK: - Reading

    static func load(brand: Brand, region: Region, username: String) -> CLISession {
        all()[key(brand: brand, region: region, username: username)] ?? CLISession()
    }

    private static func all() -> [String: CLISession] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: CLISession].self, from: data)) ?? [:]
    }

    // MARK: - Writing

    static func save(
        _ session: CLISession,
        brand: Brand,
        region: Region,
        username: String
    ) {
        var sessions = all()
        sessions[key(brand: brand, region: region, username: username)] = session
        write(sessions)
    }

    static func clear(brand: Brand, region: Region, username: String) {
        var sessions = all()
        sessions.removeValue(forKey: key(brand: brand, region: region, username: username))
        write(sessions)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: file)
    }

    /// Writes the store with owner-only permissions.
    ///
    /// Permissions are set in `attributes:` at creation rather than
    /// chmod'ed afterwards — a token written world-readable and narrowed a
    /// moment later was still world-readable for that moment.
    private static func write(_ sessions: [String: CLISession]) {
        let manager = FileManager.default

        do {
            if !manager.fileExists(atPath: directory.path) {
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }

            let data = try JSONEncoder().encode(sessions)

            // `createFile` applies the attributes atomically for a new
            // file; an existing one keeps the mode it was created with.
            if manager.fileExists(atPath: file.path) {
                try data.write(to: file, options: .atomic)
                try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } else {
                manager.createFile(
                    atPath: file.path,
                    contents: data,
                    attributes: [.posixPermissions: 0o600]
                )
            }
        } catch {
            // Never fatal: a CLI that can't cache its session should still
            // work, just with an MFA prompt each run.
            printError("Could not save session (you'll be asked for MFA again next run): \(error)")
        }
    }

    /// Where the store lives, for the `--forget` message and `--help`.
    static var displayPath: String {
        file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
