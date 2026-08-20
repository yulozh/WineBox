//
//  YXFakefsImport.c
//  YuixServer
//
//  Alpine rootfs importer: zlib (.tar.gz) + sqlite3, no libarchive.
//  Produces the same {fs}/data + {fs}/meta.db layout that fs/fake.c mounts.
//

#include "YXFakefsImport.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#define YX_HAVE_COMMONCRYPTO 1
#else
#define YX_HAVE_COMMONCRYPTO 0
#endif

// Identical to fs/fix_path.h in the engine: the fakefs data dir is addressed
// relative to root_fd, and normalized entry paths start with '/' (or are ""
// for the root). Forgetting to strip the leading slash would make openat()
// escape to absolute host paths — a sandbox-breaking bug.
static const char *yx_fix_path(const char *path) {
    if (path[0] == '\0')
        return ".";
    if (path[0] == '/')
        path++;
    return path;
}

// ---- ish_stat layout must match fs/fake-db.h ----
struct yx_ish_stat {
    uint32_t mode;
    uint32_t uid;
    uint32_t gid;
    uint32_t rdev;
};

// ish dev encoding: mmmMMMmm (see fs/dev.h)
static uint32_t yx_dev_make(uint32_t major, uint32_t minor) {
    return ((minor & 0xfff00u) << 12) | (major << 8) | (minor & 0xffu);
}

#define YX_FILL_ERR(_type, _code, ...) do { \
    err_out->line = __LINE__; \
    err_out->type = _type; \
    err_out->code = (int)(_code); \
    snprintf(err_out->message, sizeof(err_out->message), __VA_ARGS__); \
    goto fail; \
} while (0)

#define YX_ARCHIVE_ERR(...) YX_FILL_ERR(YX_ERR_ARCHIVE, 0, __VA_ARGS__)
#define YX_POSIX_ERR() YX_FILL_ERR(YX_ERR_POSIX, errno, "%s", strerror(errno))
#define YX_SQLITE_ERR(db) YX_FILL_ERR(YX_ERR_SQLITE, sqlite3_extended_errcode(db), "%s", sqlite3_errmsg(db))
#define YX_FORMAT_ERR(...) YX_FILL_ERR(YX_ERR_FORMAT, 0, __VA_ARGS__)

#define YX_MAX_PATH 4096
#define YX_BLOCK 512
#define YX_PAX_SIZE_NONE UINT64_MAX

// ---------------------------------------------------------------- tar fields

// Parse an octal (or base-256) tar numeric field. Returns 0 on success.
static int yx_parse_tar_num(const char *field, size_t len, uint64_t *out) {
    const unsigned char first = (unsigned char)field[0];
    if (first == 0x80 || first == 0xFF) {
        // GNU base-256 extension (0x80 = positive)
        uint64_t v = (first == 0xFF) ? 0 : 0;
        for (size_t i = 1; i < len; i++) {
            if (v > (UINT64_MAX >> 8)) return -1;
            v = (v << 8) | (unsigned char)field[i];
        }
        *out = v;
        return 0;
    }
    uint64_t v = 0;
    bool any = false;
    for (size_t i = 0; i < len; i++) {
        char c = field[i];
        if (c == ' ' || c == '\0') {
            if (any) break;
            continue;
        }
        if (c < '0' || c > '7') return -1;
        any = true;
        v = v * 8 + (uint64_t)(c - '0');
    }
    if (!any) { *out = 0; return 0; } // empty field == 0
    *out = v;
    return 0;
}

static void yx_field_str(const char *field, size_t len, char *out, size_t out_size) {
    size_t n = 0;
    while (n < len && n + 1 < out_size && field[n] != '\0') {
        out[n] = field[n];
        n++;
    }
    out[n] = '\0';
}

// Same normalization rules as tools/fakefs.c: reject "..", collapse slashes.
static bool yx_path_normalize(const char *path, char *out, size_t out_size) {
#define YX_ENDS_PATH(c) (c == '\0' || c == '/')
    size_t o = 0;
    while (path[0] != '\0') {
        while (path[0] == '/') path++;
        if (path[0] == '\0') break;
        if (path[0] == '.' && path[1] == '.' && YX_ENDS_PATH(path[2]))
            return false; // no dotdot allowed
        if (path[0] == '.' && YX_ENDS_PATH(path[1])) {
            path++;
        } else {
            if (o + 1 >= out_size) return false;
            out[o++] = '/';
            while (path[0] != '/' && path[0] != '\0') {
                if (o + 1 >= out_size) return false;
                out[o++] = *path++;
            }
        }
    }
    out[o] = '\0';
    return true;
#undef YX_ENDS_PATH
}

// ------------------------------------------------------------- gz stream read

struct yx_reader {
    gzFile gz;
    unsigned char buf[64 * 1024];
    size_t len;
    size_t pos;
    uint64_t total;
    int err;
    bool eof;      // gzread returned 0 (clean end of stream)
    bool short_read; // EOF hit in the middle of a requested block
};

static bool yx_reader_fill(struct yx_reader *r) {
    if (r->pos < r->len) return true;
    r->pos = 0;
    int n = gzread(r->gz, r->buf, (unsigned)sizeof(r->buf));
    if (n < 0) { r->err = n; return false; }
    if (n == 0) { r->eof = true; return false; }
    r->len = (size_t)n;
    return true;
}

static bool yx_read_exact(struct yx_reader *r, void *dst, size_t size) {
    unsigned char *p = dst;
    while (size > 0) {
        if (!yx_reader_fill(r)) {
            if (r->err == 0 && r->eof) r->short_read = true;
            return false;
        }
        size_t take = r->len - r->pos;
        if (take > size) take = size;
        memcpy(p, r->buf + r->pos, take);
        r->pos += take;
        r->total += take;
        p += take;
        size -= take;
    }
    return true;
}

static bool yx_skip(struct yx_reader *r, uint64_t size) {
    while (size > 0) {
        if (!yx_reader_fill(r)) return false;
        size_t take = r->len - r->pos;
        if ((uint64_t)take > size) take = (size_t)size;
        r->pos += take;
        r->total += take;
        size -= take;
    }
    return true;
}

// ------------------------------------------------------------- pax record map

struct yx_pax {
    char path[YX_MAX_PATH];
    char linkpath[YX_MAX_PATH];
    uint64_t size;
    bool has_size;
};

static void yx_pax_init(struct yx_pax *pax) {
    pax->path[0] = '\0';
    pax->linkpath[0] = '\0';
    pax->size = 0;
    pax->has_size = false;
}

static bool yx_parse_pax(struct yx_reader *r, uint64_t payload, struct yx_pax *pax) {
    if (payload == 0 || payload > 1024 * 1024) return false;
    char *data = malloc((size_t)payload);
    if (!data) return false;
    if (!yx_read_exact(r, data, (size_t)payload)) { free(data); return false; }
    size_t pos = 0;
    while (pos < payload) {
        size_t len = 0;
        size_t start = pos;
        while (pos < payload && data[pos] >= '0' && data[pos] <= '9') {
            len = len * 10 + (size_t)(data[pos] - '0');
            pos++;
        }
        if (pos >= payload || data[pos] != ' ' || len == 0 || start + len > payload) break;
        size_t rec_end = start + len;
        pos++; // skip space
        size_t kv_end = rec_end;
        if (kv_end > 0 && data[kv_end - 1] == '\n') kv_end--;
        size_t eq = pos;
        while (eq < kv_end && data[eq] != '=') eq++;
        if (eq < kv_end) {
            size_t key_len = eq - pos;
            const char *key = data + pos;
            const char *value = data + eq + 1;
            size_t value_len = kv_end - (eq + 1);
            if (key_len == 4 && memcmp(key, "path", 4) == 0 && value_len < sizeof(pax->path)) {
                memcpy(pax->path, value, value_len);
                pax->path[value_len] = '\0';
            } else if (key_len == 8 && memcmp(key, "linkpath", 8) == 0 && value_len < sizeof(pax->linkpath)) {
                memcpy(pax->linkpath, value, value_len);
                pax->linkpath[value_len] = '\0';
            } else if (key_len == 4 && memcmp(key, "size", 4) == 0) {
                char tmp[32];
                size_t n = value_len < sizeof(tmp) - 1 ? value_len : sizeof(tmp) - 1;
                memcpy(tmp, value, n);
                tmp[n] = '\0';
                pax->size = strtoull(tmp, NULL, 10);
                pax->has_size = true;
            }
        }
        pos = rec_end;
    }
    free(data);
    return true;
}

// ------------------------------------------------------------------ sqlite ai

static bool yx_step_reset(sqlite3 *db, sqlite3_stmt *stmt, struct yx_import_error *err_out) {
    if (sqlite3_step(stmt) != SQLITE_DONE || sqlite3_reset(stmt) != SQLITE_OK) {
        err_out->line = __LINE__;
        err_out->type = YX_ERR_SQLITE;
        err_out->code = sqlite3_extended_errcode(db);
        snprintf(err_out->message, sizeof(err_out->message), "%s", sqlite3_errmsg(db));
        sqlite3_reset(stmt);
        return false;
    }
    return true;
}

// ------------------------------------------------------------------- importer

bool yx_fakefs_import(const char *archive_path, const char *fs,
                      struct yx_import_error *err_out,
                      struct yx_import_progress progress) {
    memset(err_out, 0, sizeof(*err_out));

    // all declarations before the first potential `goto fail`
    struct stat st = {0};
    uint64_t archive_bytes = 0;
    uint64_t last_report = 0;
    gzFile gz = NULL;
    struct yx_reader *reader = NULL;
    unsigned char *chunk = NULL;
    sqlite3 *db = NULL;
    sqlite3_stmt *insert_stat = NULL, *insert_path = NULL, *insert_hardlink = NULL;
    int root_fd = -1;
    char *long_name = NULL, *long_link = NULL;
    uint64_t pax_size_pending = YX_PAX_SIZE_NONE;
    bool archive_has_root = false;
    unsigned char header[YX_BLOCK];
    bool result = false;
    char path_tmp[PATH_MAX];

    if (stat(archive_path, &st) < 0) YX_POSIX_ERR();
    archive_bytes = (uint64_t)st.st_size;

    gz = gzopen(archive_path, "rb");
    if (!gz) YX_ARCHIVE_ERR("cannot open %s", archive_path);
    reader = calloc(1, sizeof(*reader));
    if (!reader) YX_FILL_ERR(YX_ERR_POSIX, ENOMEM, "oom");
    reader->gz = gz;
    chunk = malloc(64 * 1024);
    if (!chunk) YX_FILL_ERR(YX_ERR_POSIX, ENOMEM, "oom");

    // ---- create target layout ----
    if (mkdir(fs, 0777) < 0 && errno != EEXIST) YX_POSIX_ERR();
    if (snprintf(path_tmp, sizeof(path_tmp), "%s/data", fs) >= (int)sizeof(path_tmp))
        YX_FORMAT_ERR("fs path too long");
    if (mkdir(path_tmp, 0777) < 0 && errno != EEXIST) YX_POSIX_ERR();
    root_fd = open(path_tmp, O_RDONLY);
    if (root_fd < 0) YX_POSIX_ERR();

    if (snprintf(path_tmp, sizeof(path_tmp), "%s/meta.db", fs) >= (int)sizeof(path_tmp))
        YX_FORMAT_ERR("fs path too long");
    if (sqlite3_open_v2(path_tmp, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
        if (db) {
            err_out->type = YX_ERR_SQLITE;
            err_out->code = sqlite3_extended_errcode(db);
            snprintf(err_out->message, sizeof(err_out->message), "%s", sqlite3_errmsg(db));
        } else {
            err_out->type = YX_ERR_SQLITE;
            snprintf(err_out->message, sizeof(err_out->message), "sqlite open failed");
        }
        goto fail;
    }
    sqlite3_busy_timeout(db, 10000);

#define YX_EXEC(sql) do { \
    char *_emsg = NULL; \
    if (sqlite3_exec(db, sql, NULL, NULL, &_emsg) != SQLITE_OK) { \
        err_out->type = YX_ERR_SQLITE; \
        err_out->code = sqlite3_extended_errcode(db); \
        snprintf(err_out->message, sizeof(err_out->message), "%s", _emsg ? _emsg : sqlite3_errmsg(db)); \
        sqlite3_free(_emsg); \
        goto fail; \
    } \
} while (0)

    YX_EXEC("pragma journal_mode=wal");
    YX_EXEC("begin");
    YX_EXEC("create table meta (id integer unique default 0, db_inode integer);"
            "insert into meta (db_inode) values (0);"
            "create table stats (inode integer primary key, stat blob);"
            "create table paths (path blob primary key, inode integer references stats(inode));"
            "create index inode_to_path on paths (inode, path);"
            "pragma user_version=3;");

    if (sqlite3_prepare_v2(db, "insert into stats (stat) values (?)", -1, &insert_stat, NULL) != SQLITE_OK)
        YX_SQLITE_ERR(db);
    if (sqlite3_prepare_v2(db, "insert or replace into paths values (?, ?)", -1, &insert_path, NULL) != SQLITE_OK)
        YX_SQLITE_ERR(db);
    if (sqlite3_prepare_v2(db, "insert or replace into paths values (?, (select inode from paths where path = ? limit 1))", -1, &insert_hardlink, NULL) != SQLITE_OK)
        YX_SQLITE_ERR(db);
#undef YX_EXEC

#define YX_REPORT(msg) do { \
    if (progress.callback && (reader->total - last_report > 262144)) { \
        last_report = reader->total; \
        double frac = archive_bytes ? (double)reader->total / (double)archive_bytes : 0; \
        if (frac > 1) frac = 1; \
        if (!progress.callback(progress.cookie, frac, (msg))) { \
            err_out->type = YX_ERR_CANCELLED; \
            snprintf(err_out->message, sizeof(err_out->message), "cancelled"); \
            goto fail; \
        } \
    } \
} while (0)

    for (;;) {
        if (!yx_read_exact(reader, header, YX_BLOCK)) {
            if (reader->err != 0) YX_ARCHIVE_ERR("gzip read error %d", reader->err);
            if (reader->short_read) YX_ARCHIVE_ERR("truncated tar header");
            if (reader->total == 0) YX_ARCHIVE_ERR("empty archive");
            break; // clean EOF at a block boundary
        }
        bool all_zero = true;
        for (size_t i = 0; i < YX_BLOCK; i++) {
            if (header[i] != 0) { all_zero = false; break; }
        }
        if (all_zero) break;

        YX_REPORT("reading");

        char typeflag = (char)header[156];
        char name[256], prefix[256], linkname[256];
        yx_field_str((const char *)header + 0, 100, name, sizeof(name));
        yx_field_str((const char *)header + 345, 155, prefix, sizeof(prefix));
        yx_field_str((const char *)header + 157, 100, linkname, sizeof(linkname));

        uint64_t size = 0, mode = 0, uid = 0, gid = 0, mtime = 0, devmajor = 0, devminor = 0;
        if (yx_parse_tar_num((const char *)header + 124, 12, &size) != 0)
            YX_FORMAT_ERR("bad size field for %s", name);
        yx_parse_tar_num((const char *)header + 100, 8, &mode);
        yx_parse_tar_num((const char *)header + 108, 8, &uid);
        yx_parse_tar_num((const char *)header + 116, 8, &gid);
        yx_parse_tar_num((const char *)header + 136, 12, &mtime);
        yx_parse_tar_num((const char *)header + 329, 8, &devmajor);
        yx_parse_tar_num((const char *)header + 337, 8, &devminor);

        // ---- meta entries affecting the next entry ----
        if (typeflag == 'L' || typeflag == 'K') {
            if (size == 0 || size > YX_MAX_PATH) {
                uint64_t total = ((size + YX_BLOCK - 1) / YX_BLOCK) * YX_BLOCK;
                if (!yx_skip(reader, total)) YX_ARCHIVE_ERR("truncated");
                continue;
            }
            char *buf = malloc((size_t)size + 1);
            if (!buf) YX_FILL_ERR(YX_ERR_POSIX, ENOMEM, "oom");
            if (!yx_read_exact(reader, buf, (size_t)size)) {
                free(buf);
                YX_ARCHIVE_ERR("truncated long name");
            }
            buf[size] = '\0';
            for (uint64_t i = size; i > 0 && buf[i - 1] == '\0'; i--) buf[i - 1] = '\0';
            if (typeflag == 'L') { free(long_name); long_name = buf; }
            else { free(long_link); long_link = buf; }
            uint64_t pad = (YX_BLOCK - (size % YX_BLOCK)) % YX_BLOCK;
            if (pad && !yx_skip(reader, pad)) YX_ARCHIVE_ERR("truncated");
            continue;
        }
        if (typeflag == 'x' || typeflag == 'g') {
            struct yx_pax pax;
            yx_pax_init(&pax);
            if (!yx_parse_pax(reader, size, &pax)) YX_FORMAT_ERR("bad pax header");
            uint64_t pad = (YX_BLOCK - (size % YX_BLOCK)) % YX_BLOCK;
            if (pad && !yx_skip(reader, pad)) YX_ARCHIVE_ERR("truncated");
            if (typeflag == 'x') {
                if (pax.path[0]) { free(long_name); long_name = strdup(pax.path); }
                if (pax.linkpath[0]) { free(long_link); long_link = strdup(pax.linkpath); }
                if (pax.has_size) pax_size_pending = pax.size;
            }
            continue;
        }

        // ---- final name / link ----
        char full_name[YX_MAX_PATH];
        const char *entry_name = long_name ? long_name : name;
        if (prefix[0] && !long_name) {
            if (snprintf(full_name, sizeof(full_name), "%s/%s", prefix, entry_name) >= (int)sizeof(full_name))
                YX_FORMAT_ERR("name too long: %s", name);
        } else {
            if (strlen(entry_name) >= sizeof(full_name)) YX_FORMAT_ERR("name too long");
            snprintf(full_name, sizeof(full_name), "%s", entry_name);
        }
        const char *final_link = long_link ? long_link : linkname;

        if (pax_size_pending != YX_PAX_SIZE_NONE) {
            size = pax_size_pending;
            pax_size_pending = YX_PAX_SIZE_NONE;
        }
        free(long_name); long_name = NULL;
        free(long_link); long_link = NULL;

        char entry_path[YX_MAX_PATH];
        if (!yx_path_normalize(full_name, entry_path, sizeof(entry_path))) {
            fprintf(stderr, "warning: skipped possible path traversal %s\n", full_name);
            uint64_t total = ((size + YX_BLOCK - 1) / YX_BLOCK) * YX_BLOCK;
            if (!yx_skip(reader, total)) YX_ARCHIVE_ERR("truncated");
            continue;
        }
        if (entry_path[0] == '\0') archive_has_root = true;

        // ---- hardlink ----
        if (typeflag == '1') {
            char hardlink_path[YX_MAX_PATH];
            if (!yx_path_normalize(final_link, hardlink_path, sizeof(hardlink_path))) {
                fprintf(stderr, "warning: almost pwned by hardlink %s\n", final_link);
                continue;
            }
            if (linkat(root_fd, yx_fix_path(hardlink_path),
                       root_fd, yx_fix_path(entry_path), 0) < 0) {
                if (errno == EEXIST) {
                    // fall through: refresh the db row below
                } else if (errno == ENOENT) {
                    // out-of-order hardlink (target not yet imported); skip the
                    // db row too so we never store a path with NULL inode
                    continue;
                } else {
                    YX_POSIX_ERR();
                }
            }
            sqlite3_bind_blob64(insert_hardlink, 1, entry_path, strlen(entry_path), SQLITE_TRANSIENT);
            sqlite3_bind_blob64(insert_hardlink, 2, hardlink_path, strlen(hardlink_path), SQLITE_TRANSIENT);
            if (!yx_step_reset(db, insert_hardlink, err_out)) goto fail;
            continue;
        }

        // ---- mkdir -p parent chain ----
        {
            char *copy = strdup(entry_path);
            if (!copy) YX_FILL_ERR(YX_ERR_POSIX, ENOMEM, "oom");
            char *slash = copy;
            while ((slash = strchr(*slash ? slash + 1 : slash, '/')) != NULL) {
                *slash = '\0';
                int err = mkdirat(root_fd, yx_fix_path(copy), 0777);
                *slash = '/';
                if (err < 0 && errno != EEXIST) {
                    free(copy);
                    YX_POSIX_ERR();
                }
            }
            free(copy);
        }

        int fd = -1;
        bool is_dir = (typeflag == '5');
        switch (typeflag) {
            case '\0':
            case '0':
            case '7':
            case '2':
            case '3':
            case '4':
            case '6': // fifo: stored as an empty regular file, S_IFIFO in db
                fd = openat(root_fd, yx_fix_path(entry_path),
                            O_WRONLY | O_CREAT | O_TRUNC, 0666);
                if (fd < 0) {
                    if (errno == EISDIR) continue; // case-insensitive collision
                    YX_POSIX_ERR();
                }
                break;
            case '5':
                if (mkdirat(root_fd, yx_fix_path(entry_path), 0777) < 0
                    && errno != EEXIST)
                    YX_POSIX_ERR();
                break;
            default: {
                uint64_t total = ((size + YX_BLOCK - 1) / YX_BLOCK) * YX_BLOCK;
                if (!yx_skip(reader, total)) YX_ARCHIVE_ERR("truncated");
                continue;
            }
        }

        // ---- contents ----
        if (typeflag == '\0' || typeflag == '0' || typeflag == '7') {
            uint64_t remaining = size;
            while (remaining > 0) {
                size_t want = remaining > 64 * 1024 ? 64 * 1024 : (size_t)remaining;
                if (!yx_read_exact(reader, chunk, want)) YX_ARCHIVE_ERR("truncated file data");
                ssize_t w = write(fd, chunk, want);
                if (w < 0) YX_POSIX_ERR();
                if ((size_t)w != want) YX_FILL_ERR(YX_ERR_POSIX, EIO, "short write");
                remaining -= want;
            }
        } else if (typeflag == '2') {
            size_t slen = strlen(final_link);
            if (slen > 0 && write(fd, final_link, slen) < 0) YX_POSIX_ERR();
        }
        {
            uint64_t pad = (YX_BLOCK - (size % YX_BLOCK)) % YX_BLOCK;
            if (pad && !yx_skip(reader, pad)) YX_ARCHIVE_ERR("truncated");
        }
        if (fd != -1) { close(fd); fd = -1; }

        if (!is_dir && entry_path[0]) {
            struct timespec times[2] = {
                {.tv_sec = (time_t)mtime, .tv_nsec = 0},
                {.tv_sec = (time_t)mtime, .tv_nsec = 0},
            };
            utimensat(root_fd, yx_fix_path(entry_path), times, 0); // best effort
        }

        // ---- db rows ----
        uint32_t imode;
        switch (typeflag) {
            case '2':  imode = S_IFLNK | (uint32_t)(mode & 07777); break;
            case '3':  imode = S_IFCHR | (uint32_t)(mode & 07777); break;
            case '4':  imode = S_IFBLK | (uint32_t)(mode & 07777); break;
            case '5':  imode = S_IFDIR | (uint32_t)(mode & 07777); break;
            case '6':  imode = S_IFIFO | (uint32_t)(mode & 07777); break;
            default:   imode = S_IFREG | (uint32_t)(mode & 07777); break;
        }
        struct yx_ish_stat istat = {
            .mode = imode,
            .uid = (uint32_t)uid,
            .gid = (uint32_t)gid,
            .rdev = yx_dev_make((uint32_t)devmajor, (uint32_t)devminor),
        };
        sqlite3_bind_blob64(insert_stat, 1, &istat, sizeof(istat), SQLITE_TRANSIENT);
        if (!yx_step_reset(db, insert_stat, err_out)) goto fail;
        sqlite3_bind_blob64(insert_path, 1, entry_path, strlen(entry_path), SQLITE_TRANSIENT);
        sqlite3_bind_int64(insert_path, 2, sqlite3_last_insert_rowid(db));
        if (!yx_step_reset(db, insert_path, err_out)) goto fail;
    }

    if (!archive_has_root) {
        struct yx_ish_stat istat = {.mode = S_IFDIR | 0755};
        sqlite3_bind_blob64(insert_stat, 1, &istat, sizeof(istat), SQLITE_TRANSIENT);
        if (!yx_step_reset(db, insert_stat, err_out)) goto fail;
        sqlite3_bind_blob64(insert_path, 1, "", 0, SQLITE_TRANSIENT);
        sqlite3_bind_int64(insert_path, 2, sqlite3_last_insert_rowid(db));
        if (!yx_step_reset(db, insert_path, err_out)) goto fail;
    }

    {
        char *emsg = NULL;
        if (sqlite3_exec(db, "commit", NULL, NULL, &emsg) != SQLITE_OK) {
            err_out->type = YX_ERR_SQLITE;
            snprintf(err_out->message, sizeof(err_out->message), "%s", emsg ? emsg : "commit failed");
            sqlite3_free(emsg);
            goto fail;
        }
    }
    result = true;

fail:
#undef YX_REPORT
    if (insert_stat) sqlite3_finalize(insert_stat);
    if (insert_path) sqlite3_finalize(insert_path);
    if (insert_hardlink) sqlite3_finalize(insert_hardlink);
    if (db) {
        if (!result) sqlite3_exec(db, "rollback", NULL, NULL, NULL);
        else
            // 显式折叠 WAL 并截断：sqlite3_close 对最后一个连接也会自动
            // checkpoint，但磁盘紧张时可能静默失败留下 -wal/-shm 残留；
            // 显式做一遍保证交给校验/上线的 meta.db 是干净自包含的。
            sqlite3_exec(db, "pragma wal_checkpoint(truncate)", NULL, NULL, NULL);
        sqlite3_close(db);
    }
    if (root_fd >= 0) close(root_fd);
    free(long_name);
    free(long_link);
    free(chunk);
    if (reader) gzclose(reader->gz);
    else if (gz) gzclose(gz); // reader alloc failed but gz was opened
    free(reader);
    return result;
}

// ------------------------------------------------------------------- sha256

bool yx_sha256_file(const char *path, char *out_hex, size_t out_size) {
    if (!path || !out_hex || out_size < 65) return false;
#if YX_HAVE_COMMONCRYPTO
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    unsigned char buf[64 * 1024];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        if (CC_SHA256_Update(&ctx, buf, (CC_LONG)n) != 1) { fclose(f); return false; }
    }
    bool ok = (ferror(f) == 0);
    fclose(f);
    if (!ok) return false;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (CC_SHA256_Final(digest, &ctx) != 1) return false;
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        snprintf(out_hex + i * 2, 3, "%02x", digest[i]);
    }
    out_hex[64] = '\0';
    return true;
#else
    (void)path;
    // non-Apple builds (e.g. local harness tests) don't need the digest
    out_hex[0] = '\0';
    return false;
#endif
}
