/* tarx —— 自带的 .tar / .tar.gz 解包器（iOS 用）
 *
 * 为什么需要它：
 *   · iOS 没有 /usr/bin/tar；
 *   · 随包的 ca-filetool 的 tar 只实现了 **创建** 模式
 *     （跑 `tar -xzf` 会直接回 "only create mode (-c) is supported"）；
 *   · TheosRuntime 是 224 MB 的 .tar.gz，必须能解开才能装。
 *
 * 依赖：只链 libz（系统自带）+ libSystem。没有第三方 dylib，
 *      因此不需要 disable-library-validation，也不会踩 library validation。
 *
 * 用法：
 *   tarx -xf archive.tar.gz -C /path/to/dest [--strip-components N]
 *   tarx -tf archive.tar.gz            # 只列表
 *
 * 支持：普通文件、目录、符号链接、硬链接、GNU 长文件名（L/K）、
 *      pax 扩展头（x/g 里的 path=/linkpath=/size=）、mode、mtime。
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#define BLOCK 512

typedef struct {
    gzFile gz;
    long long remaining;   /* 当前条目还剩多少字节 */
    char *longname;        /* GNU 'L' */
    char *longlink;        /* GNU 'K' */
    char *pax_path;        /* pax 'path=' */
    char *pax_link;        /* pax 'linkpath=' */
    long long pax_size;
    int have_pax_size;
} Reader;

static int read_block(Reader *r, unsigned char *buf) {
    int n = gzread(r->gz, buf, BLOCK);
    if (n < 0) return -1;
    if (n != BLOCK) return 0;      /* 结束 */
    return 1;
}

/* 头数据区（条目内容）读取 */
static int read_data(Reader *r, void *dst, size_t n) {
    size_t off = 0;
    char *p = (char *)dst;
    while (off < n) {
        unsigned want = (unsigned)((n - off) > (1u << 20) ? (1u << 20) : (n - off));
        int got = gzread(r->gz, p + off, want);
        if (got <= 0) return -1;
        off += (size_t)got;
    }
    r->remaining -= (long long)n;
    return 0;
}

/* 精确跳过 n 字节（用于 512 块填充） */
static int skip_bytes(Reader *r, long long n) {
    char buf[4096];
    while (n > 0) {
        size_t take = (size_t)(n > (long long)sizeof(buf) ? (long long)sizeof(buf) : n);
        if (read_data(r, buf, take) != 0) return -1;
        n -= (long long)take;
    }
    return 0;
}

static int skip_data(Reader *r) {
    char buf[8192];
    while (r->remaining > 0) {
        size_t n = (size_t)(r->remaining > (long long)sizeof(buf) ? (long long)sizeof(buf) : r->remaining);
        if (read_data(r, buf, n) != 0) return -1;
    }
    return 0;
}

static long long parse_octal(const char *p, size_t len) {
    long long v = 0;
    size_t i = 0;
    while (i < len && (p[i] == ' ' || p[i] == '\0')) i++;
    /* base-256（GNU 大文件） */
    if (i < len && ((unsigned char)p[i] & 0x80)) {
        unsigned char c = (unsigned char)p[i];
        v = (long long)(c & 0x7f);
        for (i++; i < len; i++) v = (v << 8) | (unsigned char)p[i];
        return v;
    }
    for (; i < len; i++) {
        if (p[i] < '0' || p[i] > '7') break;
        v = v * 8 + (p[i] - '0');
    }
    return v;
}

static void parse_pax(const char *data, size_t len, Reader *r) {
    size_t i = 0;
    while (i < len) {
        /* "<len> key=value\n" */
        size_t j = i;
        long n = 0;
        while (j < len && data[j] >= '0' && data[j] <= '9') { n = n * 10 + (data[j] - '0'); j++; }
        if (j >= len || data[j] != ' ' || n <= 0) break;
        size_t rec_end = i + (size_t)n;
        if (rec_end > len || rec_end <= j) break;
        const char *kv = data + j + 1;
        size_t kvlen = rec_end - (j + 1);
        if (kvlen > 0 && data[rec_end - 1] == '\n') kvlen--;
        const char *eq = memchr(kv, '=', kvlen);
        if (eq) {
            size_t klen = (size_t)(eq - kv);
            const char *val = eq + 1;
            size_t vlen = kvlen - klen - 1;
            if (klen == 4 && strncmp(kv, "path", 4) == 0) {
                free(r->pax_path);
                r->pax_path = strndup(val, vlen);
            } else if (klen == 8 && strncmp(kv, "linkpath", 8) == 0) {
                free(r->pax_link);
                r->pax_link = strndup(val, vlen);
            } else if (klen == 4 && strncmp(kv, "size", 4) == 0) {
                r->pax_size = atoll(val);
                r->have_pax_size = 1;
            }
        }
        i = rec_end;
    }
}

/* 拒绝绝对路径与 .. 越界 */
static int safe_path(const char *p) {
    if (!p || !*p) return 0;
    if (p[0] == '/') return 0;
    const char *q = p;
    while (*q) {
        if (q[0] == '.' && q[1] == '.' && (q[2] == '/' || q[2] == '\0')) return 0;
        q++;
    }
    return 1;
}

static int mkdir_p(const char *path) {
    char tmp[4096];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    for (size_t i = 1; i < len; i++) {
        if (tmp[i] == '/') {
            tmp[i] = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) { /* 继续尝试 */ }
            tmp[i] = '/';
        }
    }
    if (mkdir(path, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static int strip_prefix(char *path, int n) {
    if (n <= 0) return 0;
    char *p = path;
    for (int i = 0; i < n; i++) {
        char *slash = strchr(p, '/');
        if (!slash) { p[0] = '\0'; return -1; }   /* 全被剥掉了 */
        p = slash + 1;
    }
    memmove(path, p, strlen(p) + 1);
    return 0;
}

int main(int argc, char **argv) {
    const char *archive = NULL;
    const char *dest = ".";
    int list_only = 0;
    int strip = 0;

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "-xf") == 0 || strcmp(a, "-xzf") == 0 || strcmp(a, "-x") == 0) {
            if (i + 1 < argc) archive = argv[++i];
        } else if (strcmp(a, "-tf") == 0 || strcmp(a, "-tzf") == 0 || strcmp(a, "-t") == 0) {
            list_only = 1;
            if (i + 1 < argc) archive = argv[++i];
        } else if (strcmp(a, "-C") == 0) {
            if (i + 1 < argc) dest = argv[++i];
        } else if (strcmp(a, "--strip-components") == 0) {
            if (i + 1 < argc) strip = atoi(argv[++i]);
        } else if (a[0] != '-' && !archive) {
            archive = a;
        }
    }
    if (!archive) {
        fprintf(stderr, "用法: tarx -xf archive.tar.gz -C dest [--strip-components N]\n"
                        "      tarx -tf archive.tar.gz\n");
        return 2;
    }

    Reader r;
    memset(&r, 0, sizeof(r));
    r.gz = gzopen(archive, "rb");
    if (!r.gz) {
        fprintf(stderr, "tarx: 打不开 %s: %s\n", archive, strerror(errno));
        return 3;
    }

    unsigned char hdr[BLOCK];
    int files = 0, dirs = 0, links = 0;
    int rc = 0;

    for (;;) {
        int got = read_block(&r, hdr);
        if (got <= 0) break;
        /* 全零块 = 结束 */
        int zero = 1;
        for (int i = 0; i < BLOCK; i++) if (hdr[i]) { zero = 0; break; }
        if (zero) break;

        char name[256];
        memcpy(name, hdr, 100);
        name[100] = '\0';
        char prefix[156];
        memcpy(prefix, hdr + 345, 155);
        prefix[155] = '\0';

        long long size = parse_octal((const char *)hdr + 124, 12);
        unsigned mode = (unsigned)parse_octal((const char *)hdr + 100, 8);
        long long mtime = parse_octal((const char *)hdr + 136, 12);
        char type = (char)hdr[156];
        char linkname[101];
        memcpy(linkname, hdr + 157, 100);
        linkname[100] = '\0';

        /* 拼完整路径 */
        char full[4096];
        if (prefix[0]) snprintf(full, sizeof(full), "%s/%s", prefix, name);
        else snprintf(full, sizeof(full), "%s", name);

        r.remaining = size;
        if (r.have_pax_size) { size = r.pax_size; r.remaining = size; r.have_pax_size = 0; }
        /* 数据区按 512 对齐；必须按**原始 size** 算填充，
           否则 remaining 先被读成 0，就永远补不上 padding（曾经因此整体错位） */
        long long pad = (BLOCK - (size % BLOCK)) % BLOCK;

        if (type == 'L') {                    /* GNU 长文件名 */
            free(r.longname);
            r.longname = malloc((size_t)size + 1);
            if (r.longname && read_data(&r, r.longname, (size_t)size) == 0) {
                r.longname[size] = '\0';
                size_t l = strlen(r.longname);
                while (l && (r.longname[l - 1] == '\n' || r.longname[l - 1] == '\0')) r.longname[--l] = '\0';
            }
            skip_bytes(&r, pad);
            continue;
        }
        if (type == 'K') {                    /* GNU 长链接名 */
            free(r.longlink);
            r.longlink = malloc((size_t)size + 1);
            if (r.longlink && read_data(&r, r.longlink, (size_t)size) == 0) {
                r.longlink[size] = '\0';
                size_t l = strlen(r.longlink);
                while (l && r.longlink[l - 1] == '\n') r.longlink[--l] = '\0';
            }
            skip_bytes(&r, pad);
            continue;
        }
        if (type == 'x' || type == 'g') {     /* pax 头 */
            char *buf = malloc((size_t)size + 1);
            if (buf) {
                if (read_data(&r, buf, (size_t)size) == 0) {
                    buf[size] = '\0';
                    parse_pax(buf, (size_t)size, &r);
                }
                free(buf);
            }
            skip_bytes(&r, pad);
            continue;
        }

        if (r.longname && r.longname[0]) {
            snprintf(full, sizeof(full), "%s", r.longname);
            free(r.longname);
            r.longname = NULL;
        }
        if (r.pax_path && r.pax_path[0]) {
            snprintf(full, sizeof(full), "%s", r.pax_path);
            free(r.pax_path);
            r.pax_path = NULL;
        }
        if (r.longlink && r.longlink[0]) {
            snprintf(linkname, sizeof(linkname), "%s", r.longlink);
            free(r.longlink);
            r.longlink = NULL;
        }
        if (r.pax_link && r.pax_link[0]) {
            snprintf(linkname, sizeof(linkname), "%s", r.pax_link);
            free(r.pax_link);
            r.pax_link = NULL;
        }

        if (!safe_path(full) || strip_prefix(full, strip) != 0 || !full[0]) {
            skip_data(&r);
            skip_bytes(&r, pad);
            continue;
        }

        if (list_only) {
            printf("%s\n", full);
            skip_data(&r);
            skip_bytes(&r, pad);
            continue;
        }

        char target[4096];
        snprintf(target, sizeof(target), "%s/%s", dest, full);

        if (type == '5') {
            mkdir_p(target);
            dirs++;
        } else if (type == '2') {
            char dirbuf[4096];
            snprintf(dirbuf, sizeof(dirbuf), "%s", target);
            char *slash = strrchr(dirbuf, '/');
            if (slash) { *slash = '\0'; mkdir_p(dirbuf); }
            unlink(target);
            if (symlink(linkname, target) == 0) links++;
            else fprintf(stderr, "tarx: symlink %s: %s\n", target, strerror(errno));
        } else if (type == '1') {
            char dirbuf[4096];
            snprintf(dirbuf, sizeof(dirbuf), "%s", target);
            char *slash = strrchr(dirbuf, '/');
            if (slash) { *slash = '\0'; mkdir_p(dirbuf); }
            char srcbuf[4096];
            snprintf(srcbuf, sizeof(srcbuf), "%s/%s", dest, linkname);
            unlink(target);
            if (link(srcbuf, target) != 0)
                fprintf(stderr, "tarx: hardlink %s: %s\n", target, strerror(errno));
            links++;
        } else if (type == '0' || type == '\0' || type == '7') {
            char dirbuf[4096];
            snprintf(dirbuf, sizeof(dirbuf), "%s", target);
            char *slash = strrchr(dirbuf, '/');
            if (slash) { *slash = '\0'; mkdir_p(dirbuf); }

            int fd = open(target, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            if (fd < 0) {
                fprintf(stderr, "tarx: 创建 %s: %s\n", target, strerror(errno));
                rc = 5;
                skip_data(&r);
                skip_bytes(&r, pad);
                continue;
            }
            char buf[65536];
            int bad = 0;
            while (r.remaining > 0) {
                size_t n = (size_t)(r.remaining > (long long)sizeof(buf) ? (long long)sizeof(buf) : r.remaining);
                if (read_data(&r, buf, n) != 0) { bad = 1; break; }
                size_t off = 0;
                while (off < n) {
                    ssize_t w = write(fd, buf + off, n - off);
                    if (w <= 0) { bad = 1; break; }
                    off += (size_t)w;
                }
                if (bad) break;
            }
            close(fd);
            if (bad) { rc = 5; break; }
            unsigned perm = mode & 07777;
            if (!perm) perm = 0644;
            chmod(target, perm);
            files++;
        } else {
            skip_data(&r);      /* 设备/FIFO 等：跳过 */
        }

        skip_bytes(&r, pad);
    }

    gzclose(r.gz);
    free(r.longname);
    free(r.longlink);
    free(r.pax_path);
    free(r.pax_link);

    if (!list_only) {
        fprintf(stderr, "tarx: %d files, %d dirs, %d links\n", files, dirs, links);
    }
    return rc;
}
