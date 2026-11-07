import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var lang: LanguageStore
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(lang.t("settings.appearance"))) {
                    Picker(lang.t("settings.appearance"), selection: $theme.mode) {
                        ForEach(ModeChoice.allCases, id: \.self) { mode in
                            Text(lang.t(Self.key(for: mode))).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section(header: Text(lang.t("settings.colorTheme"))) {
                    ForEach(ThemePreset.allCases, id: \.self) { preset in
                        Button { theme.preset = preset } label: {
                            HStack {
                                Circle()
                                    .fill(Color(UIColor(sunbayHex: preset.primaryHex) ?? .systemOrange))
                                    .frame(width: 22, height: 22)
                                Text(lang.t(preset.nameKey)).foregroundColor(.primary)
                                Spacer()
                                if theme.preset == preset {
                                    Image(systemName: "checkmark").foregroundColor(theme.primary)
                                }
                            }
                        }
                        .accessibilityIdentifier("theme-\(preset)")
                    }
                }
                Section(header: Text(lang.t("settings.language"))) {
                    Picker(lang.t("settings.language"), selection: $lang.language) {
                        ForEach(ShowcaseLanguage.allCases, id: \.self) { l in
                            Text(lang.t("settings.language.\(l.rawValue)")).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(lang.t("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(lang.t("action.done")) { presentationMode.wrappedValue.dismiss() }
                        .accessibilityIdentifier("settingsDone")
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private static func key(for mode: ModeChoice) -> String {
        switch mode {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
        }
    }
}
