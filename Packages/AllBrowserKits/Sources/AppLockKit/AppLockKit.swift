import Foundation
import LocalAuthentication
import StorageKit

public enum AppLockError: LocalizedError {
    case biometricsUnavailable
    case authenticationFailed
    case passcodeNotSet
    case passcodeMismatch

    public var errorDescription: String? {
        switch self {
        case .biometricsUnavailable: return "Biometrics unavailable"
        case .authenticationFailed: return "Authentication failed"
        case .passcodeNotSet: return "Set a passcode first"
        case .passcodeMismatch: return "Incorrect passcode"
        }
    }
}

public protocol AppLockServing: AnyObject {
    var isLocked: Bool { get }
    var isPasscodeSet: Bool { get }
    func setPasscode(_ passcode: String) throws
    func clearPasscode()
    func lock()
    func unlockWithBiometrics() async throws
    func unlockWithPasscode(_ passcode: String) throws
    func handleDidEnterBackground()
    func handleWillEnterForeground()
}

@MainActor
public final class AppLockService: ObservableObject, AppLockServing {
    @Published public private(set) var isLocked: Bool = false
    @Published public private(set) var isPasscodeSet: Bool = false

    private let passcodeKey = "allbrowser.app.lock.passcode"
    private var backgroundedAt: Date?
    private let settings: () -> AppSettings

    public init(settings: @escaping () -> AppSettings) {
        self.settings = settings
        isPasscodeSet = (KeychainStore.get(passcodeKey) != nil)
        if settings().appLockEnabled && isPasscodeSet {
            isLocked = true
        }
    }

    public func setPasscode(_ passcode: String) throws {
        guard passcode.count >= 4 else { throw AppLockError.passcodeMismatch }
        KeychainStore.set(passcode, forKey: passcodeKey)
        isPasscodeSet = true
    }

    public func clearPasscode() {
        KeychainStore.delete(passcodeKey)
        isPasscodeSet = false
        isLocked = false
    }

    public func lock() {
        guard settings().appLockEnabled, isPasscodeSet else { return }
        isLocked = true
    }

    public func unlockWithBiometrics() async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw AppLockError.biometricsUnavailable
        }
        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock AllBrowser"
        )
        guard success else { throw AppLockError.authenticationFailed }
        isLocked = false
    }

    public func unlockWithPasscode(_ passcode: String) throws {
        guard let stored = KeychainStore.get(passcodeKey) else {
            throw AppLockError.passcodeNotSet
        }
        guard stored == passcode else {
            throw AppLockError.passcodeMismatch
        }
        isLocked = false
    }

    public func handleDidEnterBackground() {
        guard settings().appLockEnabled, settings().lockOnBackground else { return }
        backgroundedAt = Date()
    }

    public func handleWillEnterForeground() {
        guard settings().appLockEnabled, isPasscodeSet else { return }
        let grace = TimeInterval(settings().lockGraceSeconds)
        if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) >= grace {
            isLocked = true
        } else if backgroundedAt == nil {
            isLocked = true
        }
        backgroundedAt = nil
    }
}

enum KeychainStore {
    static func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.allbrowser.app",
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.allbrowser.app",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.allbrowser.app",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
