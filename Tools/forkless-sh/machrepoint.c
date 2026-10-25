/* machrepoint —— 把 Mach-O 里对某个 dylib 的依赖改成另一个路径（等长原地覆盖）。
 *
 * 用途：TheosRuntime 的 clang-16 / make / ld64 / ldid 都链接了 Procursus 的
 *      @rpath/libiosexec.1.dylib。这台设备上，从 App 里 spawn 的进程不允许
 *      mmap 第三方 dylib（file system sandbox blocked mmap()），所以工具起不来。
 *      libiosexec 导出的就是 posix_spawn / execve / fopen 这些系统函数，
 *      把依赖改成 /usr/lib/libSystem.B.dylib 即可（两者都是 26 字符）。
 *
 * 用法：
 *   machrepoint <file> <needle> <replacement>     # 单文件
 *   machrepoint -r <dir> <needle> <replacement>   # 递归目录
 *
 * 退出码：0 成功（无论是否命中），2 参数错误，3 IO 错误
 * 输出：每个改动过的文件一行 "patched <path> (<n>)"
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <dirent.h>

#define MH_MAGIC_64   0xfeedfacf
#define MH_CIGAM_64   0xcffaedfe
#define FAT_MAGIC     0xcafebabe
#define LC_LOAD_DYLIB 0x0c
#define LC_LOAD_WEAK_DYLIB   0x80000018
#define LC_REEXPORT_DYLIB    0x8000001f

static unsigned rd32(const unsigned char *p, int big) {
    if (big) return ((unsigned)p[0] << 24) | ((unsigned)p[1] << 16) | ((unsigned)p[2] << 8) | p[3];
    return ((unsigned)p[3] << 24) | ((unsigned)p[2] << 16) | ((unsigned)p[1] << 8) | p[0];
}

typedef struct {
    long found, patched, skipped;
} Counts;

/* 处理一个 thin Mach-O 切片（就地修改 buf） */
static void patch_slice(unsigned char *buf, size_t len, const char *needle,
                        const char *repl, Counts *out) {
    if (len < 32) return;
    if (rd32(buf, 0) != MH_MAGIC_64) return;
    unsigned ncmds = rd32(buf + 16, 0);
    size_t off = 32;
    size_t repl_len = strlen(repl);
    for (unsigned i = 0; i < ncmds; i++) {
        if (off + 8 > len) break;
        unsigned cmd = rd32(buf + off, 0);
        unsigned cmdsize = rd32(buf + off + 4, 0);
        if (cmdsize == 0 || off + cmdsize > len) break;
        if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB) {
            unsigned stroff = rd32(buf + off + 8, 0);
            size_t abs = off + stroff;
            if (abs > 0 && abs < len) {
                size_t slen = strnlen((const char *)buf + abs, len - abs);
                if (strstr((const char *)buf + abs, needle) != NULL) {
                    out->found++;
                    if (repl_len <= slen) {
                        memset(buf + abs, 0, slen);
                        memcpy(buf + abs, repl, repl_len);
                        out->patched++;
                    } else {
                        out->skipped++;
                    }
                }
            }
        }
        off += cmdsize;
    }
}

static int patch_file(const char *path, const char *needle, const char *repl) {
    FILE *f = fopen(path, "rb");
    if (!f) return -3;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -3; }
    long sz = ftell(f);
    if (sz <= 0) { fclose(f); return -3; }
    rewind(f);
    unsigned char *buf = (unsigned char *)malloc((size_t)sz);
    if (!buf) { fclose(f); return -3; }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) { free(buf); fclose(f); return -3; }
    fclose(f);

    Counts c = {0, 0, 0};

    if (rd32(buf, 1) == FAT_MAGIC) {          /* FAT：大端 */
        unsigned narch = rd32(buf + 4, 1);
        for (unsigned i = 0; i < narch && i < 32; i++) {
            size_t base = 8 + i * 20;
            if (base + 20 > (size_t)sz) break;
            unsigned off = rd32(buf + base + 8, 1);
            unsigned size = rd32(buf + base + 12, 1);
            if (off == 0 || size == 0 || (size_t)off + size > (size_t)sz) continue;
            patch_slice(buf + off, size, needle, repl, &c);
        }
    } else {
        patch_slice(buf, (size_t)sz, needle, repl, &c);
    }

    int rc = 0;
    if (c.patched > 0) {
        f = fopen(path, "wb");
        if (!f) { free(buf); return -3; }
        if (fwrite(buf, 1, (size_t)sz, f) != (size_t)sz) rc = -3;
        fclose(f);
        printf("patched %s (%ld)\n", path, c.patched);
    }
    free(buf);
    return rc;
}

static int walk(const char *dir, const char *needle, const char *repl) {
    DIR *d = opendir(dir);
    if (!d) return -3;
    struct dirent *e;
    char path[4096];
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
        struct stat st;
        if (lstat(path, &st) != 0) continue;
        if (S_ISLNK(st.st_mode)) continue;          /* 不跟随符号链接 */
        if (S_ISDIR(st.st_mode)) { walk(path, needle, repl); continue; }
        if (!S_ISREG(st.st_mode)) continue;
        patch_file(path, needle, repl);             /* 非 Mach-O 会被内部跳过 */
    }
    closedir(d);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 5 && strcmp(argv[1], "-r") == 0) {
        return walk(argv[2], argv[3], argv[4]) == 0 ? 0 : 3;
    }
    if (argc == 4) {
        int rc = patch_file(argv[1], argv[2], argv[3]);
        return rc == 0 ? 0 : 3;
    }
    fprintf(stderr, "用法: machrepoint <file> <needle> <replacement>\n"
                    "      machrepoint -r <dir> <needle> <replacement>\n");
    return 2;
}
