import SwiftUI
import DesignSystem
import AppLockKit

struct AppLockScreen: View {
    @EnvironmentObject private var appLock: AppLockService
    @State private var passcode = ""
    @State private var errorText: String?
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ABColor.background, ABColor.surfaceElevated],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(ABColor.accent)
                Text("AllBrowser")
                    .font(ABFont.display(34))
                    .foregroundStyle(ABColor.textPrimary)
                Text("App Locked")
                    .font(ABFont.body(15))
                    .foregroundStyle(ABColor.textSecondary)

                SecureField("Enter passcode", text: $passcode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .padding()
                    .background(ABColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 32)

                if let errorText {
                    Text(errorText)
                        .font(ABFont.body(13))
                        .foregroundStyle(ABColor.danger)
                }

                Button("Unlock") {
                    unlockWithPasscode()
                }
                .buttonStyle(ABPrimaryButtonStyle())
                .padding(.horizontal, 32)
                .disabled(passcode.count < 4)

                Button {
                    Task { await unlockWithBiometrics() }
                } label: {
                    Label("Use Face ID / Touch ID", systemImage: "faceid")
                        .foregroundStyle(ABColor.accent)
                }
                .disabled(isAuthenticating)

                Spacer()
            }
        }
        .task {
            await unlockWithBiometrics()
        }
    }

    private func unlockWithPasscode() {
        do {
            try appLock.unlockWithPasscode(passcode)
            passcode = ""
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func unlockWithBiometrics() async {
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            try await appLock.unlockWithBiometrics()
            errorText = nil
        } catch {
            // Fall back to passcode quietly.
        }
    }
}
