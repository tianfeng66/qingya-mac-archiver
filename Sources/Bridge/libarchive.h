// macOS SDK 带 libarchive.tbd 但不带头文件；这里只声明用到的那部分。
// 签名照抄 libarchive 3.7 的 archive.h / archive_entry.h，ABI 稳定。
#ifndef QINGYA_LIBARCHIVE_H
#define QINGYA_LIBARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>
#include <locale.h>
#include <sys/xattr.h>

typedef int64_t la_int64_t;
typedef ssize_t la_ssize_t;

struct archive;
struct archive_entry;

#define ARCHIVE_EOF       1
#define ARCHIVE_OK        0
#define ARCHIVE_RETRY   (-10)
#define ARCHIVE_WARN    (-20)
#define ARCHIVE_FAILED  (-25)
#define ARCHIVE_FATAL   (-30)

#define QY_AE_IFMT   0170000
#define QY_AE_IFREG  0100000
#define QY_AE_IFLNK  0120000
#define QY_AE_IFDIR  0040000

#define QY_EXTRACT_PERM             0x0002
#define QY_EXTRACT_TIME             0x0004
#define QY_EXTRACT_SECURE_SYMLINKS  0x0100
#define QY_EXTRACT_SECURE_NODOTDOT  0x0200
#define QY_EXTRACT_NO_HFS_COMPRESSION 0x4000

typedef la_ssize_t archive_write_callback(struct archive *, void *_client_data,
                                          const void *_buffer, size_t _length);
typedef int archive_open_callback(struct archive *, void *_client_data);
typedef int archive_close_callback(struct archive *, void *_client_data);
typedef int archive_free_callback(struct archive *, void *_client_data);

// 通用
int archive_version_number(void);
const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);
int archive_format(struct archive *);
const char *archive_format_name(struct archive *);
int archive_filter_count(struct archive *);
int archive_filter_code(struct archive *, int);
const char *archive_filter_name(struct archive *, int);
la_int64_t archive_filter_bytes(struct archive *, int);

// 读
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_format_empty(struct archive *);
int archive_read_set_options(struct archive *, const char *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_open_filenames(struct archive *, const char **, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
la_ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_block(struct archive *, const void **, size_t *, la_int64_t *);
int archive_read_data_skip(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);

// 写磁盘
struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int);
int archive_write_disk_set_standard_lookup(struct archive *);

// 写归档
struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_7zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_add_filter_none(struct archive *);
int archive_write_add_filter_gzip(struct archive *);
int archive_write_add_filter_bzip2(struct archive *);
int archive_write_add_filter_xz(struct archive *);
int archive_write_set_options(struct archive *, const char *);
int archive_write_set_passphrase(struct archive *, const char *);
int archive_write_set_bytes_per_block(struct archive *, int);
int archive_write_set_bytes_in_last_block(struct archive *, int);
int archive_write_open2(struct archive *, void *,
                        archive_open_callback *, archive_write_callback *,
                        archive_close_callback *, archive_free_callback *);
int archive_write_header(struct archive *, struct archive_entry *);
la_ssize_t archive_write_data(struct archive *, const void *, size_t);
la_ssize_t archive_write_data_block(struct archive *, const void *, size_t, la_int64_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

// 条目
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
void archive_entry_set_symlink_utf8(struct archive_entry *, const char *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_hardlink_utf8(struct archive_entry *);
void archive_entry_set_hardlink_utf8(struct archive_entry *, const char *);
la_int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
void archive_entry_set_size(struct archive_entry *, la_int64_t);
mode_t archive_entry_filetype(struct archive_entry *);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
mode_t archive_entry_perm(struct archive_entry *);
void archive_entry_set_perm(struct archive_entry *, mode_t);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
void archive_entry_set_mtime(struct archive_entry *, time_t, long);
int archive_entry_is_encrypted(struct archive_entry *);

#endif
