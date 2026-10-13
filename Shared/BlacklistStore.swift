import Foundation

/// 名单存取。主 App 写、Call Directory 扩展读，靠 App Group 共享容器打通。
public final class BlacklistStore {

    public static let appGroupID = "group.com.fabaoyi.mobileblack"
    public static let fileName = "blocklist.json"
    public static let prefixFileName = "prefixrules.json"

    /// 条目上限。
    ///
    /// Apple 只给了 `MaximumEntriesExceeded` 这个失败码，没公开具体数字；
    /// 而扩展进程内存极小，宁少勿崩，故自设一道闸，超限的丢弃并计数。
    public static let maxEntries = 50_000

    /// 名单存在哪。三种情形界面上必须区别对待——
    /// 退回私有目录时扩展其实读不到名单，若不明说，用户加了号码却拦不住，
    /// 还以为是 App 坏了。
    public enum StorageMode: Equatable {
        /// App Group 共享容器，主 App 与扩展都读得到（正常状态）
        case shared(URL)
        /// 退回本进程私有目录：只有写它的一方读得到
        case privateFallback(URL)
        /// 无处可写，只能每次读 bundle 内置种子
        case readOnlyBundle
    }

    /// 导入结果统计
    public struct ImportReport: Equatable {
        public var added = 0
        public var updated = 0
        /// 因达到 `maxEntries` 被拒的条数
        public var rejectedByLimit = 0
        /// 文件内重复出现的号码数
        public var duplicates = 0
        /// 无法解析的原始行
        public var failures: [String] = []

        /// 一句话摘要，直接显示在界面上
        public var summary: String {
            var parts: [String] = ["新增 \(added) 条"]
            if updated > 0 { parts.append("更新 \(updated) 条") }
            if duplicates > 0 { parts.append("文件内重复 \(duplicates) 条") }
            if rejectedByLimit > 0 { parts.append("超上限丢弃 \(rejectedByLimit) 条") }
            if !failures.isEmpty { parts.append("无法解析 \(failures.count) 行") }
            return parts.joined(separator: "，")
        }
    }

    /// 名单概况
    public struct Statistics: Equatable {
        public var total: Int
        public var blocking: Int
        public var identification: Int
        public var storageShared: Bool
    }

    public private(set) var storageMode: StorageMode = .readOnlyBundle

    private var storage: [Int64: BlockEntry] = [:]
    /// 排序结果缓存：SwiftUI 每次刷新都会取 entries，不该每次都重排
    private var sortedCache: [BlockEntry]?
    private var _prefixRules: [PrefixRule] = []
    private let seedURL: URL?

    public init(appGroupID: String = BlacklistStore.appGroupID,
                fallbackDirectory: URL? = nil,
                seedURL: URL? = nil) {
        self.seedURL = seedURL

        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            storageMode = .shared(container.appendingPathComponent(Self.fileName))
        } else if let fallbackDirectory {
            storageMode = .privateFallback(fallbackDirectory.appendingPathComponent(Self.fileName))
        } else {
            storageMode = .readOnlyBundle
        }
    }

    /// 测试专用：直接指定名单文件位置，绕开 App Group 解析。
    ///
    /// App Group 容器在 Mac 上没有签名权限时行为不定，
    /// 测试须能确定名单落在哪个文件，才谈得上断言。
    init(storageURL: URL?, seedURL: URL? = nil) {
        self.seedURL = seedURL
        if let storageURL {
            storageMode = .privateFallback(storageURL)
        } else {
            storageMode = .readOnlyBundle
        }
    }

    /// App Group 是否真的生效。false 时扩展读不到主 App 写的名单。
    public var isSharedStorageAvailable: Bool {
        if case .shared = storageMode { return true }
        return false
    }

    private var storageURL: URL? {
        switch storageMode {
        case .shared(let url), .privateFallback(let url): return url
        case .readOnlyBundle: return nil
        }
    }

    /// 名单条目，按号码升序
    public var entries: [BlockEntry] {
        if let sortedCache { return sortedCache }
        let sorted = storage.values.sorted { $0.number < $1.number }
        sortedCache = sorted
        return sorted
    }

    public var count: Int { storage.count }

    public func entry(for number: Int64) -> BlockEntry? { storage[number] }

    /// 读名单。
    ///
    /// 共享容器里还没有名单时（首次启动，或 App Group 未生效），
    /// 退回 bundle 内置种子并落盘，让「装上就有一份基础名单」成立。
    public func load() {
        if let url = storageURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? Self.decoder.decode([BlockEntry].self, from: data) {
            replace(with: decoded)
        } else if let seedURL, let text = try? String(contentsOf: seedURL, encoding: .utf8) {
            // 共享容器里没有名单时，退回 bundle 内置种子并落盘
            let parsed = ListTextParser.parse(text).parsed
            replace(with: parsed.map {
                BlockEntry(number: $0.number, level: $0.level, label: $0.label, note: $0.note)
            })
            _ = try? save()
        } else {
            replace(with: [])
        }
        loadPrefixRules()
    }

    /// 写盘。所有增删改都只动内存，须显式调用此方法才落盘。
    @discardableResult
    public func save() throws -> Bool {
        guard let url = storageURL else { return false }
        let data = try Self.encoder.encode(entries)
        try data.write(to: url, options: .atomic)
        return true
    }

    /// 新增或更新一条。返回 false 表示已达上限被拒。
    @discardableResult
    public func upsert(_ entry: BlockEntry) -> Bool {
        if storage[entry.number] == nil, storage.count >= Self.maxEntries { return false }
        storage[entry.number] = entry
        sortedCache = nil
        return true
    }

    @discardableResult
    public func remove(number: Int64) -> Bool {
        guard storage.removeValue(forKey: number) != nil else { return false }
        sortedCache = nil
        return true
    }

    /// 切换级别（拦截 ↔ 标记）
    @discardableResult
    public func toggleLevel(of number: Int64) -> Bool {
        guard var entry = storage[number] else { return false }
        entry.level = entry.level == .block ? .label : .block
        if entry.level == .label, entry.label.isEmpty {
            entry.label = ListTextParser.defaultLabel
        }
        storage[number] = entry
        sortedCache = nil
        return true
    }

    /// 导入名单文本。不会自动落盘，调用方自行 `save()`。
    public func importText(_ text: String) -> ImportReport {
        let parsed = ListTextParser.parse(text)
        var report = ImportReport()
        report.duplicates = parsed.duplicates
        report.failures = parsed.failures

        for line in parsed.parsed {
            let alreadyExists = storage[line.number] != nil
            let entry = BlockEntry(number: line.number,
                                   level: line.level,
                                   label: line.label,
                                   note: line.note)
            guard upsert(entry) else {
                report.rejectedByLimit += 1
                continue
            }
            if alreadyExists { report.updated += 1 } else { report.added += 1 }
        }
        return report
    }

    /// 拦截级号码，严格升序、天然去重（字典键唯一）。
    /// Call Directory 要求逐条递增，乱序则整批失败（EntriesOutOfOrder）。
    public func blockingNumbers() -> [Int64] {
        var numbers: [Int64] = []
        numbers.reserveCapacity(storage.count)
        for entry in storage.values where entry.level == .block {
            numbers.append(entry.number)
        }
        numbers.sort()
        return numbers
    }

    /// 标记级 (号码, 标签)，严格升序去重。
    /// 被拦的号码不会振铃，无需再给识别条目，故只输出 label 级。
    public func identificationEntries() -> [(number: Int64, label: String)] {
        var pairs: [(number: Int64, label: String)] = []
        pairs.reserveCapacity(storage.count)
        for entry in storage.values where entry.level == .label {
            pairs.append((entry.number, entry.effectiveLabel))
        }
        pairs.sort { $0.number < $1.number }
        return pairs
    }

    public func statistics() -> Statistics {
        var blocking = 0
        for entry in storage.values where entry.level == .block { blocking += 1 }
        return Statistics(total: storage.count,
                          blocking: blocking,
                          identification: storage.count - blocking,
                          storageShared: isSharedStorageAvailable)
    }

    // MARK: - 号段规则

    public func prefixRules() -> [PrefixRule] { _prefixRules }

    /// 可用于号段生成的剩余预算（总上限 − 手动条目数）
    public var prefixBudget: Int { max(0, Self.maxEntries - storage.count) }

    /// 添加号段规则。返回 nil 表示成功，否则为错误描述。
    @discardableResult
    public func addPrefix(_ rule: PrefixRule) -> String? {
        let (normalized, error) = PrefixRule.validate(rule.prefix)
        guard let normalized else { return error ?? "无效前缀" }
        var newRule = rule
        newRule.prefix = normalized
        if _prefixRules.contains(where: { $0.prefix == normalized }) {
            return "该号段规则已存在"
        }
        if _prefixRules.count >= PrefixRule.maxRuleCount {
            return "号段规则已达上限 \(PrefixRule.maxRuleCount) 条"
        }
        _prefixRules.append(newRule)
        _ = try? savePrefixRules()
        return nil
    }

    public func removePrefix(_ prefix: String) {
        _prefixRules.removeAll { $0.prefix == prefix }
        _ = try? savePrefixRules()
    }

    public func togglePrefix(_ prefix: String) {
        guard let index = _prefixRules.firstIndex(where: { $0.prefix == prefix }) else { return }
        _prefixRules[index].isEnabled.toggle()
        _ = try? savePrefixRules()
    }

    // MARK: - 内部

    private func loadPrefixRules() {
        guard let url = storageURL else { return }
        let prefixURL = url.deletingLastPathComponent()
            .appendingPathComponent(Self.prefixFileName)
        guard let data = try? Data(contentsOf: prefixURL) else { return }
        _prefixRules = (try? Self.decoder.decode([PrefixRule].self, from: data)) ?? []
    }

    @discardableResult
    private func savePrefixRules() throws -> Bool {
        guard let url = storageURL else { return false }
        let prefixURL = url.deletingLastPathComponent()
            .appendingPathComponent(Self.prefixFileName)
        let data = try Self.encoder.encode(_prefixRules)
        try data.write(to: prefixURL, options: .atomic)
        return true
    }

    private func replace(with list: [BlockEntry]) {
        // uniquingKeysWith：名单文件可能被手工编辑出重复号码，取后者，不能崩
        var rebuilt = Dictionary(list.map { ($0.number, $0) },
                                 uniquingKeysWith: { _, later in later })

        // 超上限则保留号码最小的那批，保住扩展不被撑爆
        if rebuilt.count > Self.maxEntries {
            let kept = rebuilt.values
                .sorted { $0.number < $1.number }
                .prefix(Self.maxEntries)
            rebuilt = Dictionary(kept.map { ($0.number, $0) },
                                 uniquingKeysWith: { _, later in later })
        }

        storage = rebuilt
        sortedCache = nil
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // sortedKeys：落盘内容稳定，便于人工 diff 与备份
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
