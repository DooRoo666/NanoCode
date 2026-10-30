import UIKit

// ─────────────────────────────────────────────────────────────
// 最小可用 GUI app 模板（已验证真机运行）
//
// 铁律：必须有 UIApplicationMain，否则编出的是终端程序 → 闪退/黑屏
// ─────────────────────────────────────────────────────────────

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.backgroundColor = .white

        let vc = ViewController()
        window?.rootViewController = vc
        window?.makeKeyAndVisible()

        return true
    }
}

class ViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let label = UILabel()
        label.text = "Hello from Swift on iPhone"
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 24, weight: .medium)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }
}

// 这一行是整个 app 的入口，绝对不能省
UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
