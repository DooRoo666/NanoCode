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
#if defined(__APPLE__)
#include <mach-o/dyld.h>      /* _NSGetExecutablePath：$( ) 的子 shell 要用自体路径 */
#endif
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

/* 在顶层（引号外）查找分隔符；返回位置或 NULL。 */
static char *find_top(char *s, const char *needles[], int count, int *which) {
    int in_s = 0, in_d = 0, dp = 0;   /* dp = $( ... ) 嵌套深度 */
    for (char *p = s; *p; p++) {
        if (*p == '\\' && p[1]) { p++; continue; }
        if (in_s) { if (*p == '\'') in_s = 0; continue; }
        if (*p == '\'') { in_s = 1; continue; }
        if (in_d) { if (*p == '"') in_d = 0; continue; }
        if (*p == '"') { in_d = 1; continue; }
        if (dp > 0) {                      /* 命令替换内部的分隔符不算顶层 */
            if (*p == '(') dp++;
            else if (*p == ')') dp--;
            continue;
        }
        if (*p == '$' && p[1] == '(') { dp = 1; p++; continue; }
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

/* ---------- 变量表 ---------- */

/* 查变量：先 export / 赋值的表，再环境变量。
   找不到返回 NULL（shell 语义里未定义变量展开成空串）。 */
static const char *lookup_var(const char *name, size_t len) {
    for (int i = g_extra_env_count - 1; i >= 0; i--) {
        if (strncmp(g_extra_env[i], name, len) == 0 && g_extra_env[i][len] == '=')
            return g_extra_env[i] + len + 1;
    }
    static char key[256];
    if (len == 0 || len >= sizeof(key)) return NULL;
    memcpy(key, name, len);
    key[len] = '\0';
    return getenv(key);
}

/* 设置（覆盖）一个 KEY=VALUE */
static void set_var(const char *assign) {
    const char *eq = strchr(assign, '=');
    if (!eq) return;
    size_t len = (size_t)(eq - assign);
    for (int i = 0; i < g_extra_env_count; i++) {
        if (strncmp(g_extra_env[i], assign, len) == 0 && g_extra_env[i][len] == '=') {
            free(g_extra_env[i]);
            g_extra_env[i] = strdup(assign);
            return;
        }
    }
    if (g_extra_env_count < MAX_VARS - 1) {
        g_extra_env[g_extra_env_count++] = strdup(assign);
        g_extra_env[g_extra_env_count] = NULL;
    }
}

/* NAME=VALUE 形态？（名字只允许字母数字下划线，且不能以数字开头） */
static int is_assignment(const char *w) {
    const char *eq = strchr(w, '=');
    if (!eq || eq == w) return 0;
    if (*w >= '0' && *w <= '9') return 0;
    for (const char *p = w; p < eq; p++) {
        if (!(*p == '_' || (*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9')))
            return 0;
    }
    return 1;
}

/* ---------- 命令替换 $( ... ) ---------- */

/* 拿到自己的可执行路径（iOS 没有 /proc/self/exe） */
static const char *self_path(void) {
    static char buf[4096];
#if defined(__APPLE__)
    uint32_t size = (uint32_t)sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) == 0) return buf;
#else
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0) { buf[n] = '\0'; return buf; }
#endif
    const char *env = getenv("NSH_SELF");
    return env ? env : "nsh";
}

/* 跑一段命令，把 stdout 全部收进 malloc 出来的字符串（去掉尾部换行）。
   用 pipe + posix_spawn 实现，不 fork —— 这就是 $( ) 的 forkless 版本。 */
static char *run_command_capture(const char *cmdtext) {
    int fds[2];
    if (pipe(fds) != 0) return NULL;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    char *argv[4];
    argv[0] = (char *)"nsh";
    argv[1] = (char *)"-c";
    argv[2] = (char *)cmdtext;
    argv[3] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, self_path(), &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    if (rc != 0) { close(fds[0]); return NULL; }

    size_t cap = 1024, len = 0;
    char *out = (char *)malloc(cap);
    if (!out) { close(fds[0]); return NULL; }
    for (;;) {
        if (len + 512 + 1 > cap) {
            size_t nc = cap * 2;
            char *nb = (char *)realloc(out, nc);
            if (!nb) break;
            out = nb; cap = nc;
        }
        ssize_t n = read(fds[0], out + len, cap - len - 1);
        if (n <= 0) break;
        len += (size_t)n;
    }
    close(fds[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { /* retry */ }
    out[len] = '\0';
    while (len > 0 && (out[len - 1] == '\n' || out[len - 1] == '\r')) out[--len] = '\0';
    g_last_status = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    return out;
}

/* ---------- 分词（含 $VAR 展开） ---------- */

typedef struct { char *buf; size_t len, cap; } Word;

static void word_init(Word *w) {
    w->cap = 64; w->len = 0; w->buf = (char *)malloc(w->cap);
    if (w->buf) w->buf[0] = '\0';
}
static void word_putc(Word *w, char c) {
    if (!w->buf) return;
    if (w->len + 2 > w->cap) {
        size_t nc = w->cap * 2;
        char *nb = (char *)realloc(w->buf, nc);
        if (!nb) return;
        w->buf = nb; w->cap = nc;
    }
    w->buf[w->len++] = c;
    w->buf[w->len] = '\0';
}
static void word_puts(Word *w, const char *s) { while (s && *s) word_putc(w, *s++); }

/* 把一段文本切成 argv，返回数量。
   · 单引号：完全原样（不展开）
   · 双引号：只对 \" \\ \$ \` 脱敏，其余反斜杠保留（`printf "%s\n"` 因此不再丢 \n）
   · $NAME / ${NAME} / $? / $$ ：展开成值（不支持的写法原样保留 $）
   · 每个词单独 malloc，进程退出时统一释放即可 */
static int split_words(char *text, char **out, int max) {
    int n = 0;
    char *p = text;
    while (*p && n < max - 1) {
        while (*p == ' ' || *p == '\t' || *p == '\n') p++;
        if (!*p) break;
        Word w;
        word_init(&w);
        int in_s = 0, in_d = 0;
        while (*p) {
            char c = *p;
            if (in_s) {
                if (c == '\'') { in_s = 0; p++; continue; }
                word_putc(&w, c); p++; continue;
            }
            if (c == '\'') { in_s = 1; p++; continue; }
            if (c == '"') { in_d = !in_d; p++; continue; }
            if (c == '\\' && p[1]) {
                char nx = p[1];
                if (in_d) {
                    if (nx == '"' || nx == '\\' || nx == '$' || nx == '`') {
                        word_putc(&w, nx); p += 2; continue;
                    }
                    word_putc(&w, c); p++; continue;   /* 其余反斜杠原样保留 */
                }
                word_putc(&w, nx); p += 2; continue;
            }
            if (c == '$') {
                p++;
                if (*p == '(') {
                    /* $( ... )：找配对右括号（跳过引号与嵌套） */
                    char *start = p + 1;
                    char *q = start;
                    int depth = 1, qs = 0, qd = 0;
                    while (*q && depth > 0) {
                        char ch = *q;
                        if (qs) { if (ch == '\'') qs = 0; q++; continue; }
                        if (ch == '\'') { qs = 1; q++; continue; }
                        if (qd) {
                            if (ch == '\\' && q[1]) { q += 2; continue; }
                            if (ch == '"') qd = 0;
                            q++; continue;
                        }
                        if (ch == '"') { qd = 1; q++; continue; }
                        if (ch == '(') depth++;
                        else if (ch == ')') { depth--; if (depth == 0) break; }
                        q++;
                    }
                    if (depth != 0) { word_puts(&w, "$("); continue; }
                    *q = '\0';                        /* 就地切断，取内部命令串 */
                    char *sub = run_command_capture(start);
                    if (sub) { word_puts(&w, sub); free(sub); }
                    p = q + 1;
                    continue;
                }
                if (*p == '?') {
                    char t[16];
                    snprintf(t, sizeof t, "%d", g_last_status);
                    word_puts(&w, t); p++; continue;
                }
                if (*p == '$') {
                    char t[16];
                    snprintf(t, sizeof t, "%d", (int)getpid());
                    word_puts(&w, t); p++; continue;
                }
                char name[256];
                size_t k = 0;
                if (*p == '{') {
                    p++;
                    while (*p && *p != '}' && k < sizeof(name) - 1) name[k++] = *p++;
                    if (*p == '}') p++;
                } else {
                    while ((*p == '_' || (*p >= 'a' && *p <= 'z') ||
                            (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9')) &&
                           k < sizeof(name) - 1)
                        name[k++] = *p++;
                }
                name[k] = '\0';
                if (k == 0) { word_putc(&w, '$'); continue; }
                const char *v = lookup_var(name, k);
                if (v) word_puts(&w, v);
                continue;
            }
            if (!in_d && (c == ' ' || c == '\t' || c == '\n')) break;
            word_putc(&w, c); p++;
        }
        out[n++] = w.buf ? w.buf : strdup("");
        if (!*p) break;
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
        if (argc >= 2) {
            /* 只处理 %s / %d / %% 与常见转义，避免把用户输入当格式串。
               以前 argc==2 时直接 fputs，导致 `printf "a\nb\nc\n"` 输出字面 \n。 */
            int argi = 2;
            for (const char *p = argv[1]; *p; p++) {
                if (*p == '%' && p[1] == 's') {
                    if (argi < argc) fputs(argv[argi++], stdout);
                    p++;
                } else if (*p == '%' && p[1] == 'd') {
                    printf("%d", argi < argc ? atoi(argv[argi++]) : 0);
                    p++;
                } else if (*p == '%' && p[1] == '%') {
                    fputc('%', stdout);
                    p++;
                } else if (*p == '\\' && p[1]) {
                    char e = p[1];
                    if (e == 'n') fputc('\n', stdout);
                    else if (e == 't') fputc('\t', stdout);
                    else if (e == 'r') fputc('\r', stdout);
                    else if (e == '\\') fputc('\\', stdout);
                    else if (e == '0') fputc('\0', stdout);
                    else { fputc('\\', stdout); fputc(e, stdout); }
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

/* 去掉命令前的 NAME=VALUE 赋值，写入变量表；返回剩下几个参数 */
static int strip_assignments(Command *cmd) {
    int k = 0;
    while (k < cmd->argc && is_assignment(cmd->argv[k])) {
        set_var(cmd->argv[k]);
        k++;
    }
    if (k > 0) {
        int j = 0;
        while (j + k < cmd->argc) { cmd->argv[j] = cmd->argv[j + k]; j++; }
        cmd->argv[j] = NULL;
        cmd->argc = j;
    }
    return cmd->argc;
}

/* 在内建命令外面套一层 fd 重定向。
   以前内建（echo / printf / pwd）直接写进程自己的 stdout，
   于是 `echo hi | wc -l` 的 echo 输出跑到终端、wc 读到空 → 恒为 0；
   `echo hi > f` 的 > 也被完全忽略。这里临时 dup2 到目标 fd，跑完恢复。 */
static int run_builtin_cmd(Command *cmd, int in_fd, int out_fd, int *handled) {
    int opened_in = -1, opened_out = -1;
    int save_in = -1, save_out = -1, save_err = -1;

    if (cmd->stdin_path) opened_in = open(cmd->stdin_path, O_RDONLY);
    if (cmd->stdout_path)
        opened_out = open(cmd->stdout_path,
                          O_WRONLY | O_CREAT | (cmd->stdout_append ? O_APPEND : O_TRUNC), 0644);

    int fi = opened_in >= 0 ? opened_in : in_fd;
    int fo = opened_out >= 0 ? opened_out : out_fd;

    if (fi >= 0) { save_in = dup(STDIN_FILENO); if (save_in >= 0) dup2(fi, STDIN_FILENO); }
    if (fo >= 0) { save_out = dup(STDOUT_FILENO); if (save_out >= 0) dup2(fo, STDOUT_FILENO); }
    if (cmd->stderr_to_stdout) {
        save_err = dup(STDERR_FILENO);
        if (save_err >= 0) dup2(STDOUT_FILENO, STDERR_FILENO);
    } else if (cmd->stderr_path) {
        int fd = open(cmd->stderr_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) { save_err = dup(STDERR_FILENO); dup2(fd, STDERR_FILENO); close(fd); }
    }

    int rc = run_builtin(cmd->argv, cmd->argc, handled);
    fflush(stdout);
    fflush(stderr);

    if (save_err >= 0) { dup2(save_err, STDERR_FILENO); close(save_err); }
    if (save_out >= 0) { dup2(save_out, STDOUT_FILENO); close(save_out); }
    if (save_in >= 0) { dup2(save_in, STDIN_FILENO); close(save_in); }
    if (opened_in >= 0) close(opened_in);
    if (opened_out >= 0) close(opened_out);
    return rc;
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
        if (strip_assignments(&cmd) == 0) return g_last_status;   /* 纯赋值：设置完就结束 */
        cmd.argc = expand_globs(cmd.argv, cmd.argc, NULL, 0);
        int handled = 0;
        int rc = run_builtin_cmd(&cmd, -1, -1, &handled);
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
    int failures = 0;
    int prev_read = -1;

    for (int i = 0; i < seg_count; i++) {
        Command cmd;
        if (parse_command(segments[i], &cmd) != 0) return 1;
        if (strip_assignments(&cmd) == 0) continue;
        cmd.argc = expand_globs(cmd.argv, cmd.argc, NULL, 0);

        int fds[2] = {-1, -1};
        int need_pipe = (i < seg_count - 1);
        if (need_pipe && pipe(fds) != 0) {
            fprintf(stderr, "nsh: pipe: %s\n", strerror(errno));
            return 1;
        }
        int in_fd = prev_read;
        int out_fd = need_pipe ? fds[1] : -1;

        /* 内建命令也要走管道/重定向（echo hi | wc -l 以前恒为 0） */
        int handled = 0;
        int brc = run_builtin_cmd(&cmd, in_fd, out_fd, &handled);
        if (handled) set_last(brc);
        if (!handled) {
            pid_t pid = spawn_command(&cmd, in_fd, out_fd);
            if (pid > 0) pids[pid_count++] = pid;
            else failures++;
        }

        if (prev_read >= 0) close(prev_read);
        if (need_pipe) close(fds[1]);
        prev_read = need_pipe ? fds[0] : -1;
    }
    if (prev_read >= 0) close(prev_read);

    /* 一个都没起来：这是「命令找不到」，不是成功 —— 必须返回 127 */
    if (pid_count == 0) return failures > 0 ? 127 : 0;

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

/* 解析前导标志位。
 *
 * 现实里调用方几乎从不发裸 `-c`：codex / Terminal / xcrun / make 都是
 * `sh -lc '...'`、`sh -ec '...'`、甚至 `sh -c -e`。早先只认 argv[1] == "-c"，
 * 于是 `nsh -lc 'cmd'` 会走到"把它当脚本文件打开"的分支：
 *     nsh: -lc: No such file or directory   → exit 127
 * 整条执行链就此断掉。
 *
 * 这里按字符拆标志：遇到 c 就取下一个参数当命令串，其余（l/i/e/x/s/u…）
 * 对我们没有语义，直接忽略——nsh 没有 login 概念，errexit/xtrace 也没实现。 */
int main(int argc, char **argv) {
    char *script = NULL;
    int i = 1;
    while (i < argc && argv[i][0] == '-' && argv[i][1] != '\0') {
        if (strcmp(argv[i], "--") == 0) { i++; break; }
        int wants_c = 0;
        for (const char *p = argv[i] + 1; *p; p++) {
            if (*p == 'c') { wants_c = 1; break; }
            if (*p == 'V' || *p == 'v') { printf("nsh (forkless shell) 1.0\n"); return 0; }
        }
        if (wants_c) {
            if (i + 1 >= argc) {
                fprintf(stderr, "nsh: -c 需要一个命令串\n");
                return 2;
            }
            script = argv[i + 1];
            i += 2;
            break;
        }
        i++;   /* -l / -i / -e / -x / -s / -u 等：忽略 */
    }
    if (!script && i < argc) {
        /* nsh scriptfile */
        FILE *f = fopen(argv[i], "rb");
        if (!f) { fprintf(stderr, "nsh: %s: %s\n", argv[i], strerror(errno)); return 127; }
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
