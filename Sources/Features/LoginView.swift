import SwiftUI

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var licensePlate = ""
    @Published var password = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var canSubmit: Bool {
        licensePlate.count >= 3 && password.count >= 6 && !isBusy
    }

    func signIn() async { await submit(register: false) }
    func register() async { await submit(register: true) }

    private func submit(register: Bool) async {
        guard canSubmit else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let plate = licensePlate.uppercased()
            let account = register
                ? try await environment.auth.register(licensePlate: plate, password: password)
                : try await environment.auth.login(licensePlate: plate, password: password)
            environment.account = account
        } catch let error as APIError {
            // AUTH_FAILED is a failed sign-in, not a dead session: show the message and stay
            // put. The reference web client signs the user out here, which is wrong.
            errorMessage = error.userFacingMessage
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

struct LoginView: View {
    @StateObject var model: LoginViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Licence plate", text: $model.licensePlate)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("login.plate")
                    SecureField("Password", text: $model.password)
                        .accessibilityIdentifier("login.password")
                } footer: {
                    if let message = model.errorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("login.error")
                    }
                }

                Section {
                    Button("Sign in") { Task { await model.signIn() } }
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier("login.submit")
                    Button("Create account") { Task { await model.register() } }
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier("login.register")
                }
            }
            .navigationTitle("Parking")
            .overlay {
                if model.isBusy { ProgressView() }
            }
        }
    }
}
