#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 最小自检：SpringBoard 启动完成后打一行日志。
// 装到设备上后，控制台里出现 [HelloTweak] 就说明整条链路（CI 编译 → deb → 安装 → 注入）通了。
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    NSLog(@"[HelloTweak] Theos CI self-check loaded");
}

%end
