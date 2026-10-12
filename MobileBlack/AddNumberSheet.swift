import SwiftUI

/// 手动添加一条号码。
///
/// 输入时就把规范化结果显示出来，是为了避免「存进去的和想拦的不是同一个号」——
/// 号码格式千奇百怪，等到拦不住才发现就晚了。
struct AddNumberSheet: View {
    let model: StoreModel

    @Environment(\.dismiss) private var dismiss
    @State private var numberText = ""
    @State private var level: BlockEntry.Level = .block
    @State private var label = ""
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var showContactPicker = false

    private var normalized: Int64? { NumberNormalizer.normalize(numberText) }

    var body: some View {
        NavigationStack {
            Form {
                Section("号码") {
                    TextField("如 4008208820 或 +86 400-820-8820", text: $numberText)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)

                    Button {
                        showContactPicker = true
                    } label: {
                        Label("从通讯录选择", systemImage: "person.crop.circle")
                    }

                    if !numberText.trimmingCharacters(in: .whitespaces).isEmpty {
                        if let normalized {
                            Text("将存为 \(NumberNormalizer.display(normalized))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("认不出这个号码")
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
                        TextField("标签（如 推销、诈骗）", text: $label)
                    }
                }

                Section("备注") {
                    TextField("自己看的说明，可留空", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加号码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(normalized == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showContactPicker) {
            ContactPicker(
                onPick: { picked in
                    numberText = picked.number
                    // 联系人姓名填入标签，方便日后辨认
                    if !picked.name.isEmpty && label.isEmpty {
                        label = picked.name
                    }
                    showContactPicker = false
                },
                onCancel: { showContactPicker = false }
            )
        }
    }

    private var levelExplanation: String {
        switch level {
        case .block:
            return "来电直接静音拦掉，不进最近通话。确认是骚扰号再用，免得漏接快递、外卖、银行、医院。"
        case .label:
            return "来电仍会振铃，只在屏幕上挂一个标签，接不接由你当场判断。"
        }
    }

    private func save() {
        Task {
            if let message = await model.add(numberText: numberText,
                                             level: level,
                                             label: label,
                                             note: note) {
                errorMessage = message
            } else {
                dismiss()
            }
        }
    }
}
