import ContactsUI
import SwiftUI

/// 通讯录选号的回调结果
struct PickedPhoneNumber: Identifiable {
    let id = UUID()
    let name: String
    let number: String
}

/// 包装 CNContactPickerViewController，让 SwiftUI 能调起通讯录选人。
///
/// 用 delegate 模式而非 propertyFor 模式，因为我们要的是「人选一个号码」，
/// 不是 App 自己去读通讯录全量数据——前者系统只给选中的号码，权限更小。
struct ContactPicker: UIViewControllerRepresentable {
    let onPick: (PickedPhoneNumber) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // 只显示有电话号码的联系人
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (PickedPhoneNumber) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (PickedPhoneNumber) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            guard let phone = contactProperty.value as? CNPhoneNumber else {
                onCancel()
                return
            }
            let name = CNContactFormatter.string(from: contactProperty.contact, style: .fullName) ?? ""
            onPick(PickedPhoneNumber(name: name, number: phone.stringValue))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onCancel()
        }
    }
}
