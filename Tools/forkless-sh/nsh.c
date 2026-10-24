/* nsh —— forkless shell for iOS.
 *
 * 为什么需要它：iOS SDK 把 fork() 标为 unavailable（编译器原文
 * "'fork()' is unavailable: Please use threads or posix_spawn*()"）。
 * bash 执行任何外部命令、管道、重定向、子 shell 都要 fork，所以在这台设备上
 * 一到这些语法就 SIGBUS(10)。
 *
 * nsh 用 posix_spawn 实现同样的语义，全程不调用 fork：
 *   · 顺序执行      ;        &&        ||
 *   · 管道          a | b | c          （pipe() + 每段一次 posix_spawn）
 *   · 重定向        >  >>  <  2>  2>&1 （posix_spawn_file_actions_adddup2）
 *   · 工作目录      cd                 （addchdir_np，不需要 fork 后 chdir）
 *   · 环境变量      export             （本地 environ，传给子进程）
 *   · 通配符        *.c                （glob()，纯 libc）
 *   · 内建          echo / true / false / pwd / exit / : 
 *
 * 不支持（这些语义本身要求复制进程）：$( ) 命令替换、( ) 子 shell、& 后台。
 * 用法与 sh 一致：  nsh -c "command line"
 */
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define MAX_WORDS 256
#define MAX_STAGES 16
#define MAX_REDIR 8
#define MAX_VARS 256
#define LINE_MAX_LEN 8192

static char *g_extra_env[MAX_VARS];        /* export 追加的 KEY=VALUE */
static int g_extra_env_count = 0;
static int g_last_status = 0;
static int g_should_exit = 0;

/* ---------- 小工具 ---------- */

static void set_last(int status) { g_last_status = status; }

static char *xstrndup(const char *s, size_t n) {
    char *out = (char *)malloc(n + 1);
    if (!out) exit(1);
    memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

/* 在顶层（引号外）查找分隔符；返回位置或 NULL。 */
static char *find_top(char *s, const char *needles[], int count, int *which) {
    int in_s = 0, in_d = 0;
    for (char *p = s; *p; p++) {
        if (*p == '\\' && p[1]) { p++; continue; }
        if (*p == '\'' && !in_d) { in_s = !in_s; continue; }
        if (*p == '"' && !in_s) { in_d = !in_d; continue; }
        if (in_s || in_d) continue;
        for (int i = 0; i < count; i++) {
            size_t len = strlen(needles[i]);
            if (strncmp(p, needles[i], len) == 0) {
                *which = i;
                return p;
            }
        }
    }
    return NULL;
}

/* ---------- 分词 ---------- */

/* 把一段文本切成 argv（就地修改，返回数量）。支持引号与反斜杠。 */
static int split_words(char *text, char **out, int max) {
    int n = 0;
    char *p = text;
    while (*p && n < max - 1) {
        while (*p == ' ' || *p == '\t' || *p == '\n') p++;
        if (!*p) break;
        char *dst = p;
        char *start = p;
        int in_s = 0, in_d = 0;
        while (*p) {
            char c = *p;
            if (c == '\\' && p[1] && !in_s) {
                p++;
                *dst++ = *p++;
                continue;
            }
            if (c == '\'' && !in_d) { in_s = !in_s; p++; continue; }
            if (c == '"' && !in_s) { in_d = !in_d; p++; continue; }
            if (!in_s && !in_d && (c == ' ' || c == '\t' || c == '\n')) break;
            *dst++ = c;
            p++;
        }
        char saved = *p;
        *dst = '\0';
        out[n++] = start;
        if (!saved) break;
        p++;
    }
    out[n] = NULL;
    return n;
}

/* ---------- 通配符展开 ---------- */

static int expand_globs(char **argv, int argc, char *storage, size_t storage_size) {
    char *expanded[MAX_WORDS];
    int n = 0;
    for (int i = 0; i < argc && n < MAX_WORDS - 1; i++) {
        char *word = argv[i];
        if (!strpbrk(word, "*?[")) {
            expanded[n++] = word;
            continue;
        }
        glob_t g;
        memset(&g, 0, sizeof(g));
        int rc = glob(word, GLOB_NOCHECK | GLOB_TILDE, NULL, &g);
        if (rc == 0 && g.gl_pathc > 0) {
            for (size_t k = 0; k < g.gl_pathc && n < MAX_WORDS - 1; k++) {
                expanded[n++] = g.gl_pathv[k];
            }
        } else {
            expanded[n++] = word;
        }
        /* 故意不 globfree：路径要在本次命令执行期间一直有效 */
    }
    expanded[n] = NULL;
    for (int i = 0; i < n; i++) argv[i] = expanded[i];
    argv[n] = NULL;
    (void)storage;
    (void)storage_size;
    return n;
}

/* ---------- 内建命令 ---------- */

static int run_builtin(char **argv, int argc, int *handled) {
    *handled = 0;
    if (argc == 0) return 0;
    const char *cmd = argv[0];

    if (strcmp(cmd, "cd") == 0) {
        *handled = 1;
        const char *target = argc > 1 ? argv[1] : (getenv("HOME") ? getenv("HOME") : "/");
        /* 子进程会继承父进程的 cwd，所以这里 chdir 一次就够，不需要 fork，
           也不需要 iOS SDK 里没有的 posix_spawn_file_actions_addchdir_np。 */
        if (chdir(target) == 0) return 0;
        fprintf(stderr, "nsh: cd: %s: %s\n", target, strerror(errno));
        return 1;
    }
    if (strcmp(cmd, "export") == 0) {
        *handled = 1;
        for (int i = 1; i < argc; i++) {
            if (strchr(argv[i], '=')) {
                if (g_extra_env_count < MAX_VARS - 1) {
                    g_extra_env[g_extra_env_count++] = strdup(argv[i]);
                    g_extra_env[g_extra_env_count] = NULL;
                }
            }
        }
        return 0;
    }
    if (strcmp(cmd, "unset") == 0) {
        *handled = 1;
        for (int i = 1; i < argc; i++) {
            for (int k = 0; k < g_extra_env_count; k++) {
                size_t len = strlen(argv[i]);
                if (strncmp(g_extra_env[k], argv[i], len) == 0 && g_extra_env[k][len] == '=') {
                    free(g_extra_env[k]);
                    for (int m = k; m < g_extra_env_count - 1; m++) g_extra_env[m] = g_extra_env[m + 1];
                    g_extra_env_count--;
                    g_extra_env[g_extra_env_count] = NULL;
                    k--;
                }
            }
        }
        return 0;
    }
    if (strcmp(cmd, "echo") == 0) {
        *handled = 1;
        int newline = 1;
        int start = 1;
        if (argc > 1 && strcmp(argv[1], "-n") == 0) { newline = 0; start = 2; }
        for (int i = start; i < argc; i++) {
            if (i > start) fputc(' ', stdout);
            fputs(argv[i], stdout);
        }
        if (newline) fputc('\n', stdout);
        fflush(stdout);
        return 0;
    }
    if (strcmp(cmd, "printf") == 0) {
        *handled = 1;
        if (argc == 2) { fputs(argv[1], stdout); }
        else if (argc >= 3) {
            /* 只处理 %s / %d / \n，避免把用户输入当格式串 */
            int argi = 2;
            for (const char *p = argv[1]; *p; p++) {
                if (*p == '%' && p[1] == 's') {
                    if (argi < argc) fputs(argv[argi++], stdout);
                    p++;
                } else if (*p == '%' && p[1] == 'd') {
                    printf("%d", argi < argc ? atoi(argv[argi++]) : 0);
                    p++;
                } else if (*p == '\\' && p[1] == 'n') {
                    fputc('\n', stdout);
                    p++;
                } else {
                    fputc(*p, stdout);
                }
            }
        }
        fflush(stdout);
        return 0;
    }
    if (strcmp(cmd, "pwd") == 0) {
        *handled = 1;
        char buf[PATH_MAX];
        if (getcwd(buf, sizeof(buf))) { puts(buf); fflush(stdout); }
        return 0;
    }
    if (strcmp(cmd, "exec") == 0) {
        *handled = 1;
        if (argc > 1) {
            /* 用 exec 替换自身：不创建新进程，也不需要 fork */
            execvp(argv[1], argv + 1);
            fprintf(stderr, "nsh: exec: %s: %s\n", argv[1], strerror(errno));
            return 127;
        }
        return 0;
    }
    if (strcmp(cmd, "true") == 0 || strcmp(cmd, ":") == 0) { *handled = 1; return 0; }
    if (strcmp(cmd, "false") == 0) { *handled = 1; return 1; }
    if (strcmp(cmd, "exit") == 0) {
        *handled = 1;
        g_should_exit = 1;
        return argc > 1 ? atoi(argv[1]) : g_last_status;
    }
    if (strcmp(cmd, "test") == 0 || strcmp(cmd, "[") == 0) {
        *handled = 1;
        int last = (strcmp(cmd, "[") == 0) ? 1 : 0;   /* 忽略结尾的 ] */
        int n = argc - 1 - last;
        char **a = argv + 1;
        if (n == 1) return strcmp(a[0], "") != 0 ? 0 : 1;
        if (n == 2) {
            if (strcmp(a[0], "-e") == 0) return access(a[1], F_OK) == 0 ? 0 : 1;
            if (strcmp(a[0], "-f") == 0) {
                struct stat st; return (stat(a[1], &st) == 0 && S_ISREG(st.st_mode)) ? 0 : 1;
            }
            if (strcmp(a[0], "-d") == 0) {
                struct stat st; return (stat(a[1], &st) == 0 && S_ISDIR(st.st_mode)) ? 0 : 1;
            }
            if (strcmp(a[0], "-x") == 0) return access(a[1], X_OK) == 0 ? 0 : 1;
            if (strcmp(a[0], "-r") == 0) return access(a[1], R_OK) == 0 ? 0 : 1;
            if (strcmp(a[0], "-z") == 0) return strlen(a[1]) == 0 ? 0 : 1;
            if (strcmp(a[0], "-n") == 0) return strlen(a[1]) > 0 ? 0 : 1;
        }
        if (n == 3) {
            if (strcmp(a[1], "=") == 0 || strcmp(a[1], "==") == 0) return strcmp(a[0], a[2]) == 0 ? 0 : 1;
            if (strcmp(a[1], "!=") == 0) return strcmp(a[0], a[2]) != 0 ? 0 : 1;
        }
        return 1;
    }
    return 0;
}

/* ---------- 单条命令（无管道）：解析重定向后 spawn ---------- */

typedef struct {
    char *argv[MAX_WORDS];
    int argc;
    char *stdin_path;
    char *stdout_path;
    int stdout_append;
    char *stderr_path;
    int stderr_to_stdout;
} Command;

static int parse_command(char *text, Command *cmd) {
    memset(cmd, 0, sizeof(*cmd));
    char *tokens[MAX_WORDS];
    int count = split_words(text, tokens, MAX_WORDS);
    int out = 0;
    for (int i = 0; i < count; i++) {
        char *tok = tokens[i];
        if (strcmp(tok, "2>&1") == 0) { cmd->stderr_to_stdout = 1; continue; }
        if (strcmp(tok, ">") == 0 || strcmp(tok, ">>") == 0 || strcmp(tok, "<") == 0) {
            char *target = (i + 1 < count) ? tokens[++i] : NULL;
            if (!target) return -1;
            if (tok[0] == '<') cmd->stdin_path = target;
            else { cmd->stdout_path = target; cmd->stdout_append = (strcmp(tok, ">>") == 0); }
            continue;
        }
        if (strcmp(tok, "2>") == 0) {
            char *target = (i + 1 < count) ? tokens[++i] : NULL;
            if (!target) return -1;
            cmd->stderr_path = target;
            continue;
        }
        if (tok[0] == '>') { cmd->stdout_path = tok + 1; cmd->stdout_append = 0; continue; }
        if (tok[0] == '<') { cmd->stdin_path = tok + 1; continue; }
        if (tok[0] == '2' && tok[1] == '>') { cmd->stderr_path = tok + 2; continue; }
        cmd->argv[out++] = tok;
    }
    cmd->argv[out] = NULL;
    cmd->argc = out;
    return 0;
}

/* 构造子进程环境：environ + export 追加 */
static char **build_env(void) {
    if (g_extra_env_count == 0) return environ;
    int base = 0;
    while (environ && environ[base]) base++;
    char **env = (char **)calloc(base + g_extra_env_count + 1, sizeof(char *));
    if (!env) return environ;
    for (int i = 0; i < base; i++) env[i] = environ[i];
    for (int i = 0; i < g_extra_env_count; i++) env[base + i] = g_extra_env[i];
    env[base + g_extra_env_count] = NULL;
    return env;
}

/* 起一个进程（不 fork），返回 pid 或 -1 */
static pid_t spawn_command(Command *cmd, int in_fd, int out_fd) {
    if (cmd->argc == 0) return -1;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    if (in_fd >= 0) posix_spawn_file_actions_adddup2(&actions, in_fd, STDIN_FILENO);
    if (cmd->stdin_path) posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, cmd->stdin_path, O_RDONLY, 0644);
    if (cmd->stdout_path) {
        int flags = O_WRONLY | O_CREAT | (cmd->stdout_append ? O_APPEND : O_TRUNC);
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, cmd->stdout_path, flags, 0644);
    } else if (out_fd >= 0) {
        posix_spawn_file_actions_adddup2(&actions, out_fd, STDOUT_FILENO);
    }
    if (cmd->stderr_path) {
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, cmd->stderr_path,
                                         O_WRONLY | O_CREAT | O_TRUNC, 0644);
    } else if (cmd->stderr_to_stdout) {
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    }
    /* 管道 fd 不能泄漏给子进程 */
    if (in_fd > STDERR_FILENO) posix_spawn_file_actions_addclose(&actions, in_fd);
    if (out_fd > STDERR_FILENO && out_fd != in_fd) posix_spawn_file_actions_addclose(&actions, out_fd);

    pid_t pid = 0;
    int rc = posix_spawnp(&pid, cmd->argv[0], &actions, NULL, cmd->argv, build_env());
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        fprintf(stderr, "nsh: %s: %s\n", cmd->argv[0], strerror(rc));
        return -1;
    }
    return pid;
}

/* ---------- 执行一段（可能含管道） ---------- */

static int run_segment(char *text) {
    char *segments[MAX_STAGES];
    int seg_count = 0;

    /* 按顶层 | 切分 */
    char *p = text;
    while (seg_count < MAX_STAGES) {
        const char *needles[] = {"|"};
        int which = 0;
        char *hit = find_top(p, needles, 1, &which);
        if (!hit) { segments[seg_count++] = p; break; }
        *hit = '\0';
        segments[seg_count++] = p;
        p = hit + 1;
    }

    if (seg_count == 1) {
        Command cmd;
        if (parse_command(segments[0], &cmd) != 0) { fprintf(stderr, "nsh: 语法错误\n"); return 1; }
        if (cmd.argc == 0) return g_last_status;
        expand_globs(cmd.argv, cmd.argc, NULL, 0);
        int handled = 0;
        int rc = run_builtin(cmd.argv, cmd.argc, &handled);
        if (handled || cmd.argc == 0) return rc;
        pid_t pid = spawn_command(&cmd, -1, -1);
        if (pid < 0) return 127;
        int status = 0;
        while (waitpid(pid, &status, 0) < 0) {
            if (errno == EINTR) continue;
            return 127;
        }
        if (WIFEXITED(status)) return WEXITSTATUS(status);
        if (WIFSIGNALED(status)) {
            fprintf(stderr, "nsh: %s: 被信号 %d 终止\n", cmd.argv[0], WTERMSIG(status));
            return 128 + WTERMSIG(status);
        }
        return 1;
    }

    /* 管道：每段一次 posix_spawn，用 pipe 串联，不 fork */
    pid_t pids[MAX_STAGES];
    int pid_count = 0;
    int prev_read = -1;

    for (int i = 0; i < seg_count; i++) {
        Command cmd;
        if (parse_command(segments[i], &cmd) != 0) return 1;
        if (cmd.argc == 0) continue;
        expand_globs(cmd.argv, cmd.argc, NULL, 0);

        int fds[2] = {-1, -1};
        int need_pipe = (i < seg_count - 1);
        if (need_pipe && pipe(fds) != 0) {
            fprintf(stderr, "nsh: pipe: %s\n", strerror(errno));
            return 1;
        }
        int in_fd = prev_read;
        int out_fd = need_pipe ? fds[1] : -1;

        int handled = 0;
        if (i == 0) {
            int rc = run_builtin(cmd.argv, cmd.argc, &handled);
            if (handled) { set_last(rc); }
        }
        if (!handled) {
            pid_t pid = spawn_command(&cmd, in_fd, out_fd);
            if (pid > 0) pids[pid_count++] = pid;
        }

        if (prev_read >= 0) close(prev_read);
        if (need_pipe) close(fds[1]);
        prev_read = need_pipe ? fds[0] : -1;
    }
    if (prev_read >= 0) close(prev_read);

    int status = 0;
    for (int i = 0; i < pid_count; i++) {
        int st = 0;
        while (waitpid(pids[i], &st, 0) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        status = st;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}

/* ---------- 顶层：按 ; && || 顺序/条件执行 ---------- */

static int eval(char *line) {
    char *p = line;
    int last_op = 0;   /* 0=首个 1=; 2=&& 3=|| */
    int result = 0;

    while (p && *p) {
        const char *needles[] = {";", "&&", "||"};
        int which = -1;
        char *hit = find_top(p, needles, 3, &which);
        char *segment = p;
        char *next = NULL;
        if (hit) {
            *hit = '\0';
            size_t len = strlen(needles[which]);
            next = hit + len;
        }
        /* 去掉首尾空白 */
        while (*segment == ' ' || *segment == '\t' || *segment == '\n') segment++;
        char *end = segment + strlen(segment);
        while (end > segment && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\n')) *--end = '\0';

        int skip = 0;
        if (last_op == 2 && result != 0) skip = 1;   /* && 前一条失败 */
        if (last_op == 3 && result == 0) skip = 1;   /* || 前一条成功 */
        if (!skip && *segment) {
            result = run_segment(segment);
            set_last(result);
        }
        if (g_should_exit) return result;

        last_op = (which >= 0) ? (needles[which][0] == ';' ? 1 : (needles[which][1] == '&' ? 2 : 3)) : 0;
        p = next;
    }
    return result;
}

int main(int argc, char **argv) {
    char *script = NULL;
    if (argc >= 3 && (strcmp(argv[1], "-c") == 0)) {
        script = argv[2];
    } else if (argc >= 2) {
        /* nsh scriptfile */
        FILE *f = fopen(argv[1], "rb");
        if (!f) { fprintf(stderr, "nsh: %s: %s\n", argv[1], strerror(errno)); return 127; }
        static char buf[LINE_MAX_LEN * 8];
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        buf[n] = '\0';
        fclose(f);
        script = buf;
    }
    if (!script) {
        fprintf(stderr, "用法: nsh -c \"command line\"\n"
                        "forkless shell：管道/重定向/序列均用 posix_spawn 实现，不调用 fork。\n");
        return 2;
    }

    char *work = strdup(script);
    if (!work) return 1;
    int rc = eval(work);
    free(work);
    return rc;
}
