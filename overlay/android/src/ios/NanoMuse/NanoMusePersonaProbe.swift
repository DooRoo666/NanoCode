import Darwin
import Foundation

/// 设置页「persona 探测」按钮用的报告。真正的探测逻辑在 NanoMusePersona，
/// 这里只做一次薄封装，避免两份实现各自漂移（上一版就是这么漂的）。
///
/// 更正一处旧注释：说「MT 靠 persona 切 root」是没有证据的推测。
/// 翻过它的二进制：kpersona_*、posix_spawnattr_set_persona_np、jailbreakd、
/// libjailbreak、launchctl 全是 0 处，它运行时写的文件属主也是 501。
/// 所以 MT 的真实水平是「能编译、能出包」，装进系统它同样做不到。
/// 我们要不要 root，取决于本文件的探测结果能不能拿到真 root。
enum NanoMusePersonaProbe {

    static func report() -> [String] {
        NanoMusePersona.diagnostics()
    }
}
