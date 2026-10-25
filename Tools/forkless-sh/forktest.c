/* forktest —— 决定性对照实验：同一份代码，分别编成 arm64 与 arm64e，
 * 在设备上直接 fork 一次，看哪个架构的子进程能活。
 *
 * 背景：iOS SDK 把 fork() 标成 unavailable，所以这里用 syscall(SYS_fork) 绕过标记。
 * 目的不是"证明能不能 fork"，而是**分辨架构**：
 *   · arm64 成功 + arm64e SIGBUS  → 根因是 arm64e 的 PAC + ldid 签名
 *   · 两个都成功                  → 那 bash.real SIGBUS 另有原因（bash 自身）
 *   · 两个都 SIGBUS               → 内核确实拒绝（回到原结论）
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    printf("arch=%s pid=%d\n",
#if defined(__arm64e__)
           "arm64e",
#elif defined(__arm64__)
           "arm64",
#else
           "other",
#endif
           (int)getpid());
    fflush(stdout);

    pid_t pid = (pid_t)syscall(SYS_fork);
    if (pid < 0) {
        printf("fork failed: errno=%d (%s)\n", errno, strerror(errno));
        return 1;
    }
    if (pid == 0) {
        /* 子进程：立刻写一行再退出，证明复制出来的地址空间是可执行的 */
        printf("child alive pid=%d\n", (int)getpid());
        fflush(stdout);
        _exit(0);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        printf("waitpid failed: errno=%d\n", errno);
        return 1;
    }
    if (WIFEXITED(status)) {
        printf("fork OK: child=%d exit=%d\n", (int)pid, WEXITSTATUS(status));
        return 0;
    }
    if (WIFSIGNALED(status)) {
        printf("child killed by signal %d\n", WTERMSIG(status));
        return 128 + WTERMSIG(status);
    }
    printf("child status unknown: %d\n", status);
    return 1;
}
