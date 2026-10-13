import SwiftUI

/// 添加号段规则：一键拦截/标记某个前缀开头的全部号码。
///
/// 输入时实时显示估算的覆盖范围和预算分配，让用户了解这条规则能拦多少号码。
/// 注意：受 CallKit 限制，实际是采样拦截而非全覆盖，界面上要明说。
struct AddPrefixSheet: View {
    let model: StoreModel

    @Environment(\.dismiss) private var dismiss
    @State private var prefixText = ""
    @State private var level: BlockEntry.Level = .block
    @State private var label = ""
    @State private var errorMessage: String?

    private var validation: (String?, String?) {
        PrefixRule.validate(prefixText)
    }

    private var estimatedTotal: Int64? {
        let (normalized, _) = validation
        guard let normalized else { return nil }
        return PrefixRule(prefix: normalized).estimatedTotal
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("号段前缀") {
                    TextField("如 400、170、171", text: $prefixText)
                        .keyboardType(.numberPad)

                    if !prefixText.trimmingCharacters(in: .whitespaces).isEmpty {
                        let (normalized, errorMsg) = validation
                        if let normalized {
                            let rule = PrefixRule(prefix: normalized)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("将覆盖 \(rule.displayPrefix) 号段")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text("约 \(rule.estimatedTotalDescription) 个号码")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let errorMsg {
                            Text(errorMsg)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("处置") {
                    Picker("级别", selection: $level) {
                        ForEach(BlockEntry.Level.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(levelExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if level == .label {
                        TextField("标签（如 推销、虚拟运营商）", text: $label)
                    }
                }

                Section {
                    Text("受 CallKit 限制，号段拦截是采样而非全覆盖。400 号段约 1000 万号码，系统最多分配约 45000 条采样名额，每隔约 222 个号码取一个。真正的号段级拦截请交给运营商（移动发短信 KTFSR 到 10086）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加号段规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(isInvalid)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var isInvalid: Bool {
        let (normalized, _) = validation
        return normalized == nil
    }

    private var levelExplanation: String {
        switch level {
        case .block:
            return "号段内采样的号码来电直接静音拦掉。注意：采样 ≠ 全覆盖，未被采到的号码仍会振铃。"
        case .label:
            return "号段内采样的号码来电仍会振铃，只在屏幕上挂标签，接不接由你当场判断。"
        }
    }

    private func save() {
        let (normalized, _) = validation
        guard let normalized else { return }
        Task {
            if let message = await model.addPrefix(prefix: normalized,
                                                    level: level,
                                                    label: label) {
                errorMessage = message
            } else {
                dismiss()
            }
        }
    }
}
