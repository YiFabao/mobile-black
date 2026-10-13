import Foundation

/// 扩展每次加载名单的结果。
///
/// 为什么要它：Call Directory 扩展跑在独立进程里，崩了、被系统杀了、号码乱序了，
/// 主 App 一概不知，用户只会觉得「明明加了号码却不拦」。
/// 把结果写进共享容器，界面上就能直接看到上次加载的成败与条数。
public struct LoadRecord: Codable, Equatable {
    public var date: Date
    public var blockingCount: Int
    public var identificationCount: Int
    /// 本次是否为增量请求
    public var incremental: Bool
    /// 名单是否来自 App Group 共享容器；false 说明扩展只读到内置种子
    public var storageShared: Bool
    /// 失败原因；nil 表示成功
    public var failure: String?
    /// 号段规则生成的拦截条数（可选，向后兼容旧版日志）
    public var prefixBlockingCount: Int?
    /// 号段规则生成的标记条数（可选，向后兼容旧版日志）
    public var prefixIdentificationCount: Int?

    public init(date: Date = Date(),
                blockingCount: Int = 0,
                identificationCount: Int = 0,
                incremental: Bool = false,
                storageShared: Bool = false,
                failure: String? = nil,
                prefixBlockingCount: Int? = nil,
                prefixIdentificationCount: Int? = nil) {
        self.date = date
        self.blockingCount = blockingCount
        self.identificationCount = identificationCount
        self.incremental = incremental
        self.storageShared = storageShared
        self.failure = failure
        self.prefixBlockingCount = prefixBlockingCount
        self.prefixIdentificationCount = prefixIdentificationCount
    }

    public var isSuccess: Bool { failure == nil }

    // 向后兼容：旧版日志不含号段字段，decodeIfPresent 缺省为 nil
    private enum CodingKeys: String, CodingKey {
        case date, blockingCount, identificationCount
        case incremental, storageShared, failure
        case prefixBlockingCount, prefixIdentificationCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        blockingCount = try c.decode(Int.self, forKey: .blockingCount)
        identificationCount = try c.decode(Int.self, forKey: .identificationCount)
        incremental = try c.decode(Bool.self, forKey: .incremental)
        storageShared = try c.decode(Bool.self, forKey: .storageShared)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        prefixBlockingCount = try c.decodeIfPresent(Int.self, forKey: .prefixBlockingCount)
        prefixIdentificationCount = try c.decodeIfPresent(Int.self, forKey: .prefixIdentificationCount)
    }
}

/// 加载日志。只留最近一条，够诊断就行，免得无限增长。
public enum LoadLog {

    public static let fileName = "loadlog.json"

    public static func write(_ record: LoadRecord,
                             appGroupID: String = BlacklistStore.appGroupID) {
        guard let url = fileURL(appGroupID: appGroupID) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func latest(appGroupID: String = BlacklistStore.appGroupID) -> LoadRecord? {
        guard let url = fileURL(appGroupID: appGroupID),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LoadRecord.self, from: data)
    }

    private static func fileURL(appGroupID: String) -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        return container.appendingPathComponent(fileName)
    }
}
