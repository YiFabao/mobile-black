import CallKit
import Foundation

/// Call Directory 扩展入口。
///
/// 三条硬约束（皆出自 SDK 头文件 CXCallDirectoryExtensionContext.h，非臆测）：
/// 1. 号码类型 `CXCallDirectoryPhoneNumber` 在 Xcode 27 SDK 里是 `int64_t`，
///    且必须**按数值严格升序**逐条喂入，乱序则整批失败（EntriesOutOfOrder）；
/// 2. 号码不可重复，否则 DuplicateEntries；
/// 3. 条数超限则 MaximumEntriesExceeded，且扩展进程内存很小。
///
/// 故此处只取排好序的号码数组，绝不在内存里持有整棵 JSON 树；
/// 添加方法本身不 throws，失败一律经 delegate 的 requestFailed 回报，
/// 并写进 LoadLog 供主 App 显示。
final class CallDirectoryHandler: CXCallDirectoryProvider, CXCallDirectoryExtensionContextDelegate {

    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        context.delegate = self

        // 扩展里不传 fallbackDirectory：读不到 App Group 时只读 bundle 种子，
        // 免得把名单写进扩展私有目录、主 App 永远看不见，造成「加了却不拦」的假象。
        let seedURL = Bundle(for: CallDirectoryHandler.self).mobileBlackSeedURL()
        let store = BlacklistStore(seedURL: seedURL)
        store.load()

        // 增量请求本应只给差异，但我们不维护差异日志（维护错了反而更难查），
        // 故先清空再全量灌入：语义上等价于全量，且绝不会算错。
        let incremental = context.isIncremental
        if incremental {
            context.removeAllBlockingEntries()
            context.removeAllIdentificationEntries()
        }

        // 手动拦截号码
        let manualBlocking = store.blockingNumbers()
        let manualIdentification = store.identificationEntries()

        // 号段规则生成采样号码
        let rules = store.prefixRules()
        let budget = store.prefixBudget
        let allocations = PrefixNumberGenerator.allocateBudget(rules: rules, availableBudget: budget)
        let generatedBlocking = PrefixNumberGenerator.generateSamples(
            rules: rules.filter { $0.level == .block },
            allocations: allocations
        )
        let generatedIdentification = PrefixNumberGenerator.generateIdentificationSamples(
            rules: rules.filter { $0.level == .label },
            allocations: allocations
        )

        // 合并手动与号段生成，排序去重
        let blockingNumbers = PrefixNumberGenerator.mergeBlockingNumbers(
            manual: manualBlocking,
            generated: generatedBlocking
        )

        // 标记条目须排除已被拦截的号码（被拦的不会振铃，无需标签）
        let identifications = PrefixNumberGenerator.mergeIdentificationEntries(
            manual: manualIdentification,
            generated: generatedIdentification,
            blockingNumbers: blockingNumbers
        )

        var previous: Int64 = -1
        for number in blockingNumbers {
            guard number > previous else { continue }
            context.addBlockingEntry(withNextSequentialPhoneNumber: number)
            previous = number
        }

        previous = -1
        var identificationCount = 0
        for pair in identifications {
            guard pair.number > previous else { continue }
            context.addIdentificationEntry(withNextSequentialPhoneNumber: pair.number,
                                           label: pair.label)
            previous = pair.number
            identificationCount += 1
        }

        LoadLog.write(LoadRecord(blockingCount: blockingNumbers.count,
                                 identificationCount: identificationCount,
                                 incremental: incremental,
                                 storageShared: store.isSharedStorageAvailable,
                                 prefixBlockingCount: generatedBlocking.count,
                                 prefixIdentificationCount: generatedIdentification.count))

        context.completeRequest()
    }

    /// 加载失败时系统走这里。把原因写进共享容器，主 App 界面即可看到，
    /// 否则扩展进程里的错误对用户完全是黑箱。
    func requestFailed(for context: CXCallDirectoryExtensionContext, withError error: Error) {
        LoadLog.write(LoadRecord(failure: CallDirectoryErrorExplainer.explain(error)))
        context.cancelRequest(withError: error)
    }
}
