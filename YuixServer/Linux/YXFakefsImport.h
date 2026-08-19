//
//  YXFakefsImport.h
//  YuixServer
//
//  libarchive-free Alpine rootfs importer.
//  Streams a .tar.gz with zlib, parses ustar/GNU/pax tar entries, and
//  materializes the same fakefs layout the ish kernel expects:
//      {fs}/data/    real files
//      {fs}/meta.db  sqlite path/inode/stat database
//

#ifndef YXFakefsImport_h
#define YXFakefsImport_h

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct yx_import_error {
    int line;
    enum {
        YX_ERR_ARCHIVE,
        YX_ERR_SQLITE,
        YX_ERR_POSIX,
        YX_ERR_CANCELLED,
        YX_ERR_FORMAT,
    } type;
    int code;
    char message[512];
};

struct yx_import_progress {
    void *cookie;
    // return false from callback to cancel; fraction in [0,1]
    bool (*callback)(void *cookie, double fraction, const char *message);
};

// Import `archive_path` (.tar.gz) into fakefs root directory `fs`.
// `fs` must not already exist. On failure, fills err_out.
bool yx_fakefs_import(const char *archive_path, const char *fs,
                      struct yx_import_error *err_out,
                      struct yx_import_progress progress);

// Verify the SHA256 of a file. Returns true and writes lowercase hex digest
// into out_hex (must be >= 65 bytes) on success.
bool yx_sha256_file(const char *path, char *out_hex, size_t out_size);

#ifdef __cplusplus
}
#endif

#endif /* YXFakefsImport_h */
