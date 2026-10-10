import UIKit

/// The keyboard, set up ahead of the first field tapped. UIKit builds its keyboard the first time anything takes the
/// focus, loading its text input libraries as it goes: 150 ms of the main thread on the Mac's simulator, and longer on
/// the phone, during which the wall's bar had already changed shape and risen for a keyboard that hadn't set off yet
/// (user, 2026-10-08: "首页的键盘那里…各种问题，甚至打开都卡"). Built here as the wall comes up instead, on a field of
/// its own that takes the focus and gives it up in the same turn of the run loop, so nothing of it shows.
enum KeyboardWarmup {
    @MainActor static func run() {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let field = UITextField()
        window.addSubview(field)
        UIView.performWithoutAnimation {
            field.becomeFirstResponder()
            field.resignFirstResponder()
        }
        field.removeFromSuperview()
    }
}
