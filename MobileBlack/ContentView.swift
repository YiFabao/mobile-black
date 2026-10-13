import SwiftUI

struct ContentView: View {
    @State private var model = StoreModel()
    @State private var showAdd = false
    @State private var showImport = false
    @State private var showAddPrefix = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusCard(model: model)
                }

                if let banner = model.banner {
                    Section {
                        BannerView(banner: banner, onDismiss: model.dismissBanner)
                    }
                }

                // 号段规则
                Section {
                    if model.prefixRules.isEmpty {
                        Text("尚无号段规则。点「添加号段」可一键拦截某个前缀开头的全部号码（如 400、170）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.prefixRules) { rule in
                            PrefixRuleRow(rule: rule, model: model)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await model.removePrefix(rule.prefix) }
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    Button {
                                        Task { await model.togglePrefix(rule.prefix) }
                                    } label: {
                                        Label(rule.isEnabled ? "禁用" : "启用",
                                              systemImage: rule.isEnabled ? "pause.circle" : "play.circle")
                                    }
                                    .tint(.orange)
                                }
                        }
                    }
                } header: {
                    Text("号段规则（\(model.prefixRules.count)）")
                }

                ForEach(StoreModel.Section.allCases) { section in
                    let rows = model.entries(in: section)
                    Section {
                        if rows.isEmpty {
                            Text(emptyHint(for: section))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(rows) { entry in
                                EntryRow(entry: entry)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            Task { await model.remove(entry) }
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                        Button {
                                            Task { await model.toggleLevel(entry) }
                                        } label: {
                                            Label(entry.level == .block ? "改为标记" : "改为拦截",
                                                  systemImage: "arrow.left.arrow.right")
                                        }
                                        .tint(.orange)
                                    }
                            }
                        }
                    } header: {
                        Text("\(section.rawValue)（\(rows.count)）")
                    }
                }

                Section {
                    Text(footerNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("黑名单")
            .searchable(text: $model.searchText, prompt: "搜号码、标签或备注")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showImport = true } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showAdd = true
                        } label: {
                            Label("添加号码", systemImage: "plus")
                        }
                        Button {
                            showAddPrefix = true
                        } label: {
                            Label("添加号段", systemImage: "number")
                        }
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
            .refreshable { await model.refreshStatus() }
            .task { await model.refreshStatus() }
            .sheet(isPresented: $showAdd) { AddNumberSheet(model: model) }
            .sheet(isPresented: $showImport) { ImportSheet(model: model) }
            .sheet(isPresented: $showAddPrefix) { AddPrefixSheet(model: model) }
            .overlay {
                if model.isBusy {
                    ProgressView("正在重载名单…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private func emptyHint(for section: StoreModel.Section) -> String {
        switch section {
        case .blocking:
            return "尚无拦截号码。点右上角 ＋ 逐条添加，或用左上角「导入」批量加入。"
        case .labeling:
            return "尚无标记号码。标记级仍会振铃，只在来电界面挂标签，适合拿不准的号码。"
        }
    }

    private var footerNote: String {
        """
        号段拦截是采样而非全覆盖（400 号段约 1000 万号码，系统最多分配约 45000 条采样名额）。\
        真正的号段级拦截请交给运营商（移动发短信 KTFSR 到 10086）。
        """
    }
}

// MARK: - 状态卡

struct StatusCard: View {
    let model: StoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(model.status.headline,
                      systemImage: model.status == .enabled
                          ? "checkmark.shield.fill"
                          : "exclamationmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(model.status == .enabled ? Color.green : Color.orange)
                Spacer()
                if model.status.isActionable {
                    Button("去开启") { Task { await model.openSystemSettings() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button {
                    Task { await model.refreshStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(model.status.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                // 译文可能较长，限四行而非默认两行，免得关键信息被截掉
                .lineLimit(4)

            Divider()

            HStack(spacing: 0) {
                StatBlock(title: "拦截", value: model.statistics.blocking)
                StatBlock(title: "标记", value: model.statistics.identification)
                StatBlock(title: "合计", value: model.statistics.total)
            }

            if let lastLoad = model.lastLoad {
                Text(LoadRecordText.describe(lastLoad))
                    .font(.caption2)
                    // 三元两支必须同为 Color：.secondary 是 HierarchicalShapeStyle，
                    // 与 .red 混在一处，编译器推不出共同类型
                    .foregroundStyle(lastLoad.isSuccess ? Color.secondary : Color.red)
            } else {
                Text("扩展尚未加载过名单。启用后点右上「导入」旁的刷新，或改一次名单即会触发重载。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatBlock: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 把扩展回报的加载记录写成一句话
enum LoadRecordText {
    static func describe(_ record: LoadRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let time = formatter.string(from: record.date)

        if let failure = record.failure {
            return "上次加载 \(time) 失败：\(failure)"
        }
        let source = record.storageShared ? "共享名单" : "内置种子"
        var result = "上次加载 \(time) 成功（\(source)）：拦截 \(record.blockingCount) 条，标记 \(record.identificationCount) 条"

        // 号段生成条数（向后兼容：旧版日志无此字段）
        if let prefixBlock = record.prefixBlockingCount,
           let prefixIdent = record.prefixIdentificationCount,
           prefixBlock + prefixIdent > 0 {
            result += "（其中号段生成：拦截 \(prefixBlock)，标记 \(prefixIdent)）"
        }

        return result
    }
}

// MARK: - 提示条

struct BannerView: View {
    let banner: StoreModel.Banner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(color)
            Text(text)
                .font(.footnote)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var iconName: String {
        switch banner {
        case .info: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch banner {
        case .info: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var text: String {
        switch banner {
        case .info(let message), .warning(let message), .error(let message):
            return message
        }
    }
}

// MARK: - 号段规则行

struct PrefixRuleRow: View {
    let rule: PrefixRule
    let model: StoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(rule.displayPrefix)
                    .font(.body.monospacedDigit())
                Spacer()
                Text(rule.level.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(badgeColor)
                if !rule.isEnabled {
                    Text("已禁用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text("约 \(rule.estimatedTotalDescription) 号码")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !rule.label.isEmpty {
                    Text("· \(rule.label)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var badgeColor: Color {
        rule.level == .block ? .red : .orange
    }
}

// MARK: - 名单行

struct EntryRow: View {
    let entry: BlockEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(entry.displayNumber)
                    .font(.body.monospacedDigit())
                Spacer()
                Text(entry.level.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(badgeColor)
            }

            if !entry.label.isEmpty || !entry.note.isEmpty {
                Text([entry.label, entry.note].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var badgeColor: Color {
        entry.level == .block ? .red : .orange
    }
}

#Preview {
    ContentView()
}
