import SwiftUI

/// Registration is its own screen, not a second button on the sign-in form.
///
/// It asks for something sign-in does not — a confirmation of the password — and it has rules
/// the backend will enforce whether or not the client mentions them: the plate must be 3–20
/// characters of `A–Z`, digits and hyphens (`AuthRequest`), and the password at least 6. Those
/// rules are stated on the screen rather than discovered by submitting.
///
/// Both password fields declare `.password` rather than `.newPassword`, which at least stops
/// the client *asking* iOS to generate one.
///
/// It does not stop iOS offering. The Automatic Strong Password cover view is driven by a
/// heuristic over any pair of secure fields, not by the content type: `.newPassword`, `.password`
/// and `nil` were each checked by screenshot and all three show it. A person can dismiss it;
/// a UI test cannot type through it, which is why the mismatch rule is pinned in
/// `RegisterViewModelTests` rather than through the interface.
@MainActor
final class RegisterViewModel: ObservableObject {
    @Published var licensePlate = ""
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published var revealsPassword = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isUITesting: Bool { environment.isUITesting }

    static let plateHint = "Uppercase letters, numbers and hyphens (e.g. ABC-1234)."
    static let passwordHint = "At least 6 characters."

    /// Mirrors the backend's own constraints so a rejection is explained here rather than
    /// arriving as a 400 with a field map the user never sees.
    var plateProblem: String? {
        let plate = normalisedPlate
        guard !plate.isEmpty else { return nil }
        if plate.count < 3 || plate.count > 20 { return "Between 3 and 20 characters." }
        guard plate.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "-" }) else {
            return "Letters, numbers and hyphens only."
        }
        return nil
    }

    var passwordProblem: String? {
        guard !password.isEmpty else { return nil }
        return password.count < 6 ? "At least 6 characters." : nil
    }

    var confirmProblem: String? {
        guard !confirmPassword.isEmpty else { return nil }
        return confirmPassword == password ? nil : "Passwords do not match."
    }

    var normalisedPlate: String {
        licensePlate.trimmingCharacters(in: .whitespaces).uppercased()
    }

    var canSubmit: Bool {
        !isBusy
            && !normalisedPlate.isEmpty
            && !password.isEmpty
            && !confirmPassword.isEmpty
            && plateProblem == nil
            && passwordProblem == nil
            && confirmProblem == nil
    }

    func register() async {
        guard canSubmit else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            environment.account = try await environment.auth.register(
                licensePlate: normalisedPlate, password: password
            )
        } catch let error as APIError {
            errorMessage = error.userFacingMessage
            Haptics.play(.error)
        } catch {
            errorMessage = String(describing: error)
            Haptics.play(.error)
        }
    }
}

struct RegisterView: View {
    @StateObject var model: RegisterViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field { case plate, password, confirm }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        masthead
                        fields
                        actions
                    }
                    .padding(Theme.Metric.gutter)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Create account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("register.cancel")
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    private var masthead: some View {
        VStack(spacing: 8) {
            Image(systemName: "car.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text("Register your vehicle")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.Palette.ink)
            Text("One account per licence plate.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.inkMuted)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var fields: some View {
        VStack(spacing: 14) {
            FormField(
                icon: "car.fill",
                title: "Licence plate",
                identifier: "register.plate",
                focused: focus == .plate,
                hint: RegisterViewModel.plateHint,
                problem: model.plateProblem
            ) {
                TextField("ABC-1234", text: $model.licensePlate)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(model.isUITesting ? nil : .username)
                    .focused($focus, equals: .plate)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .font(.body.monospaced())
            }

            FormField(
                icon: "lock.fill",
                title: "Password",
                identifier: "register.password",
                focused: focus == .password,
                hint: RegisterViewModel.passwordHint,
                problem: model.passwordProblem
            ) {
                HStack(spacing: 8) {
                    Group {
                        if model.revealsPassword {
                            TextField("Password", text: $model.password)
                        } else {
                            SecureField("Password", text: $model.password)
                        }
                    }
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { focus = .confirm }

                    Button {
                        model.revealsPassword.toggle()
                    } label: {
                        Image(systemName: model.revealsPassword ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .frame(width: Theme.Metric.tapTarget, height: Theme.Metric.tapTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.revealsPassword ? "Hide password" : "Show password")
                    .accessibilityIdentifier("register.reveal")
                }
            }

            FormField(
                icon: "checkmark.shield.fill",
                title: "Confirm password",
                identifier: "register.confirm",
                focused: focus == .confirm,
                problem: model.confirmProblem
            ) {
                SecureField("Repeat the password", text: $model.confirmPassword)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .confirm)
                    .submitLabel(.go)
                    .onSubmit { Task { await model.register() } }
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("register.error")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card()
        .animation(.snappy(duration: 0.2), value: model.errorMessage)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Task { await model.register() }
            } label: {
                if model.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Text("Create account")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canSubmit)
            .accessibilityIdentifier("register.submit")

            Button("Already have an account? Sign in") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("register.signIn")
        }
    }
}
