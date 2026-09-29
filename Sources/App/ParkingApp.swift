import SwiftUI

@main
struct ParkingApp: App {
    @StateObject private var environment = AppEnvironment.forLaunch()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        if environment.account == nil {
            LoginView(model: LoginViewModel(environment: environment))
        } else {
            DashboardView(model: GridViewModel(environment: environment))
        }
    }
}
