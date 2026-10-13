import Foundation

/// 号段采样号码生成器。
///
/// 把多条 PrefixRule 转成 CallKit 能吃的 Int64 号码数组：
/// 1. 按号段大小比例分配条数预算（覆盖面越大的号段分到越多名额）
/// 2. 在每条规则范围内等间距取号，尽量铺开
/// 3. 与手动名单合并、排序、去重，保证严格升序
///
/// 处理重叠：长前缀优先。如同时启用 "9" 和 "95"，"95" 取代 "9"，
/// 因为 "9" 范围内的 "95" 子集已被更精确的规则覆盖。
public enum PrefixNumberGenerator {

    /// 为号段规则分配条数配额。
    ///
    /// - Parameters:
    ///   - rules: 已启用的号段规则
    ///   - availableBudget: 可用于号段生成的剩余条数（总上限 − 手动条目数）
    /// - Returns: 每条规则的前缀与分配条数
    public static func allocateBudget(rules: [PrefixRule],
                                      availableBudget: Int) -> [(prefix: String, allocation: Int)] {
        let enabled = rules.filter(\.isEnabled)
        guard !enabled.isEmpty, availableBudget > 0 else { return [] }

        // 长前缀优先：若短前缀的范围完全包含长前缀，短前缀让位
        let sorted = enabled.sorted { $0.prefix.count > $1.prefix.count }
        var active: [PrefixRule] = []
        for rule in sorted {
            let shadowed = active.contains { longer in
                longer.prefix.hasPrefix(rule.prefix)
            }
            if !shadowed { active.append(rule) }
        }
        guard !active.isEmpty else { return [] }

        // 按号段大小比例分配
        let totals = active.map { $0.numberRange().count }
        let grandTotal = totals.reduce(Int64(0), +)
        guard grandTotal > 0 else { return [] }

        var result: [(String, Int)] = []
        for (rule, total) in zip(active, totals) {
            let share = Int((Int64(availableBudget) * total) / grandTotal)
            // 号段内号码不足配额时封顶
            let capped = min(share, Int(total))
            // 至少需要 2 条才能算出间距
            guard capped >= 2 else { continue }
            result.append((rule.prefix, capped))
        }
        return result
    }

    /// 按分配方案生成采样号码。
    ///
    /// 在号段范围内等间距取号：stride = total / allocation。
    /// 如 400 号段（1000 万号码）分到 45000 条，则每隔 222 个号码取一个。
    public static func generateSamples(rules: [PrefixRule],
                                       allocations: [(prefix: String, allocation: Int)]) -> [Int64] {
        var numbers: [Int64] = []

        for (prefix, allocation) in allocations {
            guard let rule = rules.first(where: { $0.prefix == prefix }),
                  rule.isEnabled else { continue }
            let (start, total) = rule.numberRange()
            guard total > 0 else { continue }

            let stride = total / Int64(allocation)
            guard stride >= 1 else { continue }

            for i in 0..<Int64(allocation) {
                numbers.append(start + i * stride)
            }
        }

        numbers.sort()
        return numbers
    }

    /// 按分配方案生成标记级采样条目（号码 + 标签）。
    public static func generateIdentificationSamples(
        rules: [PrefixRule],
        allocations: [(prefix: String, allocation: Int)]
    ) -> [(number: Int64, label: String)] {
        var entries: [(number: Int64, label: String)] = []

        for (prefix, allocation) in allocations {
            guard let rule = rules.first(where: { $0.prefix == prefix }),
                  rule.isEnabled else { continue }
            let (start, total) = rule.numberRange()
            guard total > 0 else { continue }

            let stride = total / Int64(allocation)
            guard stride >= 1 else { continue }

            let effectiveLabel = rule.label.isEmpty ? ListTextParser.defaultLabel : rule.label
            for i in 0..<Int64(allocation) {
                entries.append((start + i * stride, effectiveLabel))
            }
        }

        entries.sort { $0.number < $1.number }
        return entries
    }

    /// 合并手动拦截号码与号段生成号码，排序去重。
    ///
    /// CallKit 要求所有号码严格升序、不重复，故必须统一排序后一次性喂入。
    public static func mergeBlockingNumbers(manual: [Int64],
                                             generated: [Int64]) -> [Int64] {
        var merged = manual
        merged.reserveCapacity(manual.count + generated.count)
        merged.append(contentsOf: generated)
        merged.sort()

        var deduped: [Int64] = []
        deduped.reserveCapacity(merged.count)
        var previous: Int64 = -1
        for number in merged {
            if number != previous {
                deduped.append(number)
                previous = number
            }
        }
        return deduped
    }

    /// 合并手动标记条目与号段生成标记条目，排序去重，排除已拦截号码。
    ///
    /// 被拦截（block）的号码不会振铃，不需要识别标签，
    /// 故标记（label）结果须排除已出现在拦截列表中的号码。
    public static func mergeIdentificationEntries(
        manual: [(number: Int64, label: String)],
        generated: [(number: Int64, label: String)],
        blockingNumbers: [Int64]
    ) -> [(number: Int64, label: String)] {
        var merged = manual
        merged.reserveCapacity(manual.count + generated.count)
        merged.append(contentsOf: generated)
        merged.sort { $0.number < $1.number }

        // 去重
        var deduped: [(number: Int64, label: String)] = []
        var previous: Int64 = -1
        for pair in merged {
            if pair.number != previous {
                deduped.append(pair)
                previous = pair.number
            }
        }

        // 排除已被拦截的号码
        let blockingSet = Set(blockingNumbers)
        return deduped.filter { !blockingSet.contains($0.number) }
    }
}
