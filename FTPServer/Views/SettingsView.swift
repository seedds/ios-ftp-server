import SwiftUI

struct SettingsView: View {
    @Environment(ServerController.self) private var controller
    @State private var showPassword = false

    var body: some View {
        @Bindable var settings = controller.settings
        let locked = controller.isRunning || controller.isBusy

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Username") {
                        TextField("None", text: $settings.username)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Password") {
                        HStack(spacing: 12) {
                            Group {
                                if showPassword {
                                    TextField("Password", text: $settings.password)
                                } else {
                                    SecureField("Password", text: $settings.password)
                                }
                            }
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .monospaced()
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                            .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                            Button {
                                settings.password = ServerSettings.generatePassword()
                                showPassword = true
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .accessibilityLabel("Generate password")
                        }
                        .buttonStyle(.borderless)
                    }
                    Toggle("Anonymous Login", isOn: $settings.allowAnonymous)
                    Toggle("Read-Only", isOn: $settings.readOnly)
                } header: {
                    Text("Access")
                } footer: {
                    if locked { Text("Stop the server to edit access and port.") }
                }
                .disabled(locked)

                Section("Server") {
                    LabeledContent("Port") {
                        TextField("2121", value: $settings.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(settings.isPortValid ? Color.primary : .red)
                    }
                    .disabled(locked)
                    Toggle("Bonjour", isOn: $settings.bonjourEnabled)
                        .disabled(locked)
                    Toggle("Keep Screen Awake", isOn: $settings.keepScreenAwake)
                    Toggle("Start on Launch", isOn: $settings.startOnLaunch)
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: settings.keepScreenAwake) { controller.updateIdleTimer() }
        }
    }
}
