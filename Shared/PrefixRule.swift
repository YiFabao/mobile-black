import Foundation

/// 号段规则：一键拦截/标记某个前缀开头的全部号码。
///
/// 为什么需要它：人工逐条加号码效率极低，而骚扰电话往往集中在特定号段
/// （400 推销、170/171 虚拟运营商等）。一条规则即可覆盖整个号段。
///
/// 硬约束：CallKit 不支持前缀匹配，只能逐条枚举完整号码。
/// 全段枚举不可行（400 后 8 位 = 1 亿种组合），故在预算内**均匀采样**：
/// 按号段大小比例分配条数配额，在范围内等间距取号，尽量铺开覆盖面。
///
/// 注意：采样 ≠ 全覆盖。被采样的号码会被拦截，未被采到的不会。
/// 真正的号段级拦截请交给运营商（移动发短信 KTFSR 到 10086）。
public struct PrefixRule: Codable, Equatable, Hashable, Identifiable {

    /// 号段前缀（不含国家码），如 "400"、"170"
    public var prefix: String

    /// 处置级别（拦截 / 标记）
    public var level: BlockEntry.Level

    /// 来电识别标签（标记级使用）
    public var label: String

    /// 是否启用
    public var isEnabled: Bool

    /// 创建时间
    public var addedAt: Date

    public init(prefix: String,
                level: BlockEntry.Level = .block,
                label: String = "",
                isEnabled: Bool = true,
                addedAt: Date = Date()) {
        self.prefix = prefix
        self.level = level
        self.label = label
        self.isEnabled = isEnabled
        self.addedAt = addedAt
    }

    public var id: String { prefix }

    /// 展示用：400 → `400*`
    public var displayPrefix: String { prefix + "*" }

    /// 估算覆盖的号码总数。
    ///
    /// 前缀 "400" → 国内部分 10 位（400 + 7 位）→ 10^7 = 1000 万。
    /// 前缀 "170" → 国内部分 11 位（手机号）→ 10^8 = 1 亿。
    public var estimatedTotal: Int64 {
        let totalDigits = prefix.hasPrefix("1") ? 11 : 10
        let remaining = max(0, totalDigits - prefix.count)
        var result: Int64 = 1
        for _ in 0..<remaining { result *= 10 }
        return result
    }

    /// 该号段对应的完整号码范围（含国家码 86）。
    ///
    /// 返回 (start, count)，start 为范围起点，count 为号码总数。
    /// 如 "400" → (864000000000, 10_000_000)
    public func numberRange() -> (start: Int64, count: Int64) {
        let totalDigits = prefix.hasPrefix("1") ? 11 : 10
        let remaining = max(0, totalDigits - prefix.count)
        let cc = String(NumberNormalizer.countryCode)
        guard let base = Int64(cc + prefix) else { return (0, 0) }

        var count: Int64 = 1
        for _ in 0..<remaining { count *= 10 }
        return (base * count, count)
    }

    /// 展示用的人类可读数量：10000000 → "1000万"
    public var estimatedTotalDescription: String {
        let total = estimatedTotal
        if total >= 100_000_000 { return "\(total / 100_000_000)亿" }
        if total >= 10_000 { return "\(total / 10_000)万" }
        return "\(total)"
    }

    // MARK: - 验证

    public static let minPrefixLength = 2
    public static let maxPrefixLength = 5
    public static let maxRuleCount = 20

    /// 验证并规范化用户输入的前缀字符串。
    /// 返回 (normalized, nil) 表示成功，(nil, error) 表示失败。
    public static func validate(_ raw: String) -> (String?, String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "前缀不能为空") }
        guard trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber) else {
            return (nil, "前缀只能包含数字")
        }
        guard trimmed.count >= minPrefixLength else {
            return (nil, "前缀至少 \(minPrefixLength) 位")
        }
        guard trimmed.count <= maxPrefixLength else {
            return (nil, "前缀最多 \(maxPrefixLength) 位")
        }
        guard !"0".contains(trimmed.first!) else {
            return (nil, "前缀不能以 0 开头")
        }
        return (trimmed, nil)
    }
}
