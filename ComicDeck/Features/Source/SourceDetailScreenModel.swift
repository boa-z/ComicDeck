import Foundation
import Observation

@MainActor
@Observable
final class SourceDetailScreenModel {
    var capabilityProfile = SourceCapabilityProfile.empty
    var settings: [SourceSettingDefinition] = []
    var isLoading = true
    var status = ""
    var savingSettingKeys: Set<String> = []

    func load(source: InstalledSource, using vm: ReaderViewModel) async {
        isLoading = true
        defer { isLoading = false }

        async let capabilityTask = vm.loadSourceCapabilityProfile(sourceKey: source.key)
        async let settingsTask = vm.loadSourceSettings(sourceKey: source.key)
        async let loginProfileTask: Void = vm.login.prepareLoginState(for: source)

        do {
            capabilityProfile = try await capabilityTask
            settings = try await settingsTask
            _ = await loginProfileTask
            status = ""
        } catch {
            _ = await loginProfileTask
            capabilityProfile = .empty
            settings = []
            status = "Failed to load source details: \(error.localizedDescription)"
        }
    }

    func saveSetting(_ setting: SourceSettingDefinition, value: String, using vm: ReaderViewModel, sourceKey: String) async {
        savingSettingKeys.insert(setting.key)
        defer { savingSettingKeys.remove(setting.key) }
        do {
            try await vm.saveSourceSetting(sourceKey: sourceKey, key: setting.key, value: value)
            settings = try await vm.loadSourceSettings(sourceKey: sourceKey)
            status = "Updated \(setting.title)"
        } catch {
            status = "Failed to update \(setting.title): \(error.localizedDescription)"
        }
    }

    func saveSetting(_ setting: SourceSettingDefinition, value: Bool, using vm: ReaderViewModel, sourceKey: String) async {
        savingSettingKeys.insert(setting.key)
        defer { savingSettingKeys.remove(setting.key) }
        do {
            try await vm.saveSourceSetting(sourceKey: sourceKey, key: setting.key, value: value)
            settings = try await vm.loadSourceSettings(sourceKey: sourceKey)
            status = "Updated \(setting.title)"
        } catch {
            status = "Failed to update \(setting.title): \(error.localizedDescription)"
        }
    }

    func isSaving(_ key: String) -> Bool {
        savingSettingKeys.contains(key)
    }
}
