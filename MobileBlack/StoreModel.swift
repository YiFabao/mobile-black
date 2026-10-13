import Foundation
import Observation

/// 界面与名单之间的一层。SwiftUI 只认这个，不直接碰 BlacklistStore。
///
/// 所有改动一律「先落盘、再重载扩展」：只改内存不重载，系统那边不会生效，
/// 用户会觉得 App 在骗他。
@MainActor
@Observable
final class StoreModel {

    enum Banner: Equatable {
        case info(String)
        case warning(String)
        case error(String)
    }

    /// 界面分组
    enum Section: String, CaseIterable, Identifiable {
        case blocking = "拦截名单"
        case labeling = "标记名单"

        var id: String { rawValue }
        var level: BlockEntry.Level {
            self == .blocking ? .block : .label
        }
    }

    private let store: BlacklistStore

    var entries: [BlockEntry] = []
    var searchText = ""
    var status: ExtensionBridge.Status = .unknown
    var lastLoad: LoadRecord?
    var banner: Banner?
    var isBusy = false
    var statistics = BlacklistStore.Statistics(total: 0, blocking: 0,
                                               identification: 0, storageShared: false)
    var prefixRules: [PrefixRule] = []

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        store = BlacklistStore(
            fallbackDirectory: documents,
            seedURL: Bundle.main.mobileBlackSeedURL()
        )
        store.load()
        syncFromStore()
        lastLoad = LoadLog.latest()
    }

    // MARK: - 查询

    /// 按搜索词过滤后的名单。号码按数字比，标签与备注按文本比。
    func entries(in section: Section) -> [BlockEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            guard entry.level == section.level else { return false }
            guard !needle.isEmpty else { return true }
            if String(entry.number).contains(needle) { return true }
            if entry.displayNumber.contains(needle) { return true }
            if entry.label.localizedCaseInsensitiveContains(needle) { return true }
            if entry.note.localizedCaseInsensitiveContains(needle) { return true }
            return false
        }
    }

    func dismissBanner() { banner = nil }

    // MARK: - 动作

    func refreshStatus() async {
        status = await ExtensionBridge.fetchStatus()
        lastLoad = LoadLog.latest()
        syncFromStore()
    }

    /// 存盘并重载扩展。任何名单改动后都走这里。
    func persistAndReload(then message: @escaping (BlacklistStore.ImportReport?) -> String) async {
        isBusy = true
        defer { isBusy = false }

        do {
            try store.save()
        } catch {
            banner = .error("名单存盘失败：\(error.localizedDescription)")
            syncFromStore()
            return
        }
        syncFromStore()

        guard status == .enabled || status == .unknown else {
            // 扩展没开就重载，系统只会回一句 ExtensionDisabled，
            // 不如先把「去开启」摆在眼前
            banner = .warning("\(message(nil))；但扩展尚未启用，名单还不会生效。")
            return
        }

        if let failure = await ExtensionBridge.reload() {
            banner = .error("\(message(nil))；重载失败：\(failure)")
        } else {
            banner = .info(message(nil))
        }
        lastLoad = LoadLog.latest()
        status = await ExtensionBridge.fetchStatus()
    }

    /// 手动添加一条
    func add(numberText: String, level: BlockEntry.Level, label: String, note: String) async -> String? {
        guard let number = NumberNormalizer.normalize(numberText) else {
            return "认不出这个号码。支持 +86 400-820-8820、4008208820、(010) 1234 5678 等写法；短号（如 95588）无法可靠拦截，请交由运营商处理。"
        }
        let entry = BlockEntry(number: number, level: level,
                               label: level == .label && label.isEmpty ? ListTextParser.defaultLabel : label,
                               note: note)
        guard store.upsert(entry) else {
            return "名单已达上限 \(BlacklistStore.maxEntries) 条，请先精简。"
        }
        await persistAndReload { _ in "已加入\(level.displayName)名单：\(entry.displayNumber)" }
        return nil
    }

    func remove(_ entry: BlockEntry) async {
        store.remove(number: entry.number)
        await persistAndReload { _ in "已移除 \(entry.displayNumber)" }
    }

    func toggleLevel(_ entry: BlockEntry) async {
        store.toggleLevel(of: entry.number)
        let level = store.entry(for: entry.number)?.level ?? entry.level
        await persistAndReload { _ in "\(entry.displayNumber) 改为\(level.displayName)" }
    }

    /// 导入名单文本
    func importText(_ text: String) async {
        let report = store.importText(text)
        await persistAndReload { _ in "导入完成：\(report.summary)" }
        if !report.failures.isEmpty {
            let preview = report.failures.prefix(5).joined(separator: "\n")
            banner = .warning("导入完成：\(report.summary)。以下行未认出：\n\(preview)")
        }
    }

    /// 从文件导入（.txt / .csv）
    func importFile(at url: URL) async -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "读不出这个文件，请确认是 UTF-8 编码的 .txt 或 .csv。"
        }
        await importText(text)
        return nil
    }

    func openSystemSettings() async {
        await ExtensionBridge.openSettings()
    }

    // MARK: - 号段规则

    /// 添加号段规则
    func addPrefix(prefix: String, level: BlockEntry.Level, label: String) async -> String? {
        let rule = PrefixRule(prefix: prefix, level: level,
                              label: level == .label && label.isEmpty ? ListTextParser.defaultLabel : label)
        guard store.addPrefix(rule) == nil else {
            return store.addPrefix(rule)
        }
        await persistAndReload { _ in "已添加号段规则：\(rule.displayPrefix)" }
        return nil
    }

    /// 移除号段规则
    func removePrefix(_ prefix: String) async {
        store.removePrefix(prefix)
        await persistAndReload { _ in "已移除号段规则：\(prefix)*" }
    }

    /// 启用/禁用号段规则
    func togglePrefix(_ prefix: String) async {
        store.togglePrefix(prefix)
        let rule = store.prefixRules().first { $0.prefix == prefix }
        let status = rule?.isEnabled == true ? "已启用" : "已禁用"
        await persistAndReload { _ in "号段规则 \(prefix)* \(status)" }
    }

    // MARK: - 内部

    private func syncFromStore() {
        entries = store.entries
        statistics = store.statistics()
        prefixRules = store.prefixRules()
        if !statistics.storageShared {
            banner = .warning("App Group 共享容器不可用：扩展读不到你在 App 里改的名单，只能用内置种子。请检查两个 target 的 App Groups 权限是否都已生效。")
        }
    }
}
