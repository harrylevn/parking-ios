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

    /// See `AppEnvironment.isUITesting` — omitting AutoFill content types keeps iOS from
    /// putting its "Save Password?" sheet over the board mid-test.
    var isUITesting: Bool { environment.isUITesting }

    /// Read from the configured window rather than written as 20:00, so a demo run with the
    /// backend's window shifted does not open on a screen that contradicts the countdown.
    var windowSummary: String {
        let hour = environment.window.openingHour
        return "80 spaces. Opens at \(hour < 10 ? "0" : "")\(hour):00 for tomorrow."
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
            Haptics.play(.error)
        } catch {
            errorMessage = String(describing: error)
            Haptics.play(.error)
        }
    }
}

struct LoginView: View {
    @StateObject var model: LoginViewModel
    @FocusState private var focus: Field?

    private enum Field { case plate, password }

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    masthead

                    VStack(spacing: 12) {
                        field(
                            icon: "car.fill", title: "Licence plate",
                            identifier: "login.plate", focused: focus == .plate
                        ) {
                            TextField("ABC-123", text: $model.licensePlate)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .textContentType(model.isUITesting ? nil : .username)
                                .focused($focus, equals: .plate)
                                .submitLabel(.next)
                                .onSubmit { focus = .password }
                                .font(.body.monospaced())
                        }

                        field(
                            icon: "lock.fill", title: "Password",
                            identifier: "login.password", focused: focus == .password
                        ) {
                            SecureField("At least 6 characters", text: $model.password)
                                .textContentType(model.isUITesting ? nil : .password)
                                .focused($focus, equals: .password)
                                .submitLabel(.go)
                                .onSubmit { Task { await model.signIn() } }
                        }

                        if let message = model.errorMessage {
                            Label(message, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(Theme.Palette.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("login.error")
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .card()

                    VStack(spacing: 10) {
                        Button {
                            Task { await model.signIn() }
                        } label: {
                            if model.isBusy {
                                ProgressView().tint(.white)
                            } else {
                                Text("Sign in")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier("login.submit")

                        Button("Create an account") { Task { await model.register() } }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(minHeight: Theme.Metric.tapTarget)
                            .disabled(!model.canSubmit)
                            .accessibilityIdentifier("login.register")
                    }
                }
                .padding(Theme.Metric.gutter)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(.snappy(duration: 0.2), value: model.errorMessage)
        .tint(Theme.Palette.accent)
    }

    private var masthead: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.Palette.accentFill)
                    .frame(width: 74, height: 74)
                Image(systemName: "parkingsign")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }

            VStack(spacing: 4) {
                Text("Parking")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(model.windowSummary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .padding(.top, 36)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    private func field<Content: View>(
        icon: String,
        title: String,
        identifier: String,
        focused: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
            content()
                .frame(minHeight: Theme.Metric.tapTarget - 10)
                .padding(.horizontal, 12)
                .background(Theme.Palette.canvas, in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            focused ? Theme.Palette.accent : Theme.Palette.hairline,
                            lineWidth: focused ? 1.5 : 1
                        )
                )
                .accessibilityIdentifier(identifier)
        }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}
