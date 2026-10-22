"""引擎自检。不碰钥匙串，不联网。"""

from __future__ import annotations

import os
import shutil
import tarfile
import tempfile
import time
import unittest
import zipfile

from qingya.charset import decode_name, detect
from qingya.compress import CompressOptions, compress
from qingya.errors import ArchiveError
from qingya.extract import CancelToken, ExtractOptions, extract, list_archive, test_archive
from qingya.formats import base_name, volumes_for
from qingya.paths import clean, unique_path


def _noop(_fraction, _message):
    return None


class RawZipInfo(zipfile.ZipInfo):
    """写出没有 UTF-8 标记、文件名是原始字节的 zip。"""

    def _encodeFilenameFlags(self):
        return self.filename.encode("cp437"), 0


def _legacy_zip(path: str, filename: str, data: bytes, encoding: str) -> None:
    info = RawZipInfo(filename=filename.encode(encoding).decode("cp437"))
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(info, data)


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="qingya-test-")
        self.cancel = CancelToken()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _opts(self, dest: str) -> ExtractOptions:
        options = ExtractOptions(dest)
        options.propagate_mark = False
        return options

    def test_clean_rejects_zip_slip(self):
        self.assertIsNone(clean("../outside.txt", True))
        self.assertIsNone(clean("foo/../../outside.txt", True))
        self.assertIsNone(clean("..\\outside.txt", True))
        self.assertEqual(clean("资料/a.txt", True), "资料/a.txt")
        self.assertEqual(clean("CON.txt", True), "_CON.txt")

    def test_unique_name_never_overwrites(self):
        folder = os.path.join(self.tmp, "box")
        os.makedirs(folder)
        open(os.path.join(folder, "资料.txt"), "w").close()
        path = unique_path(folder, "资料.txt")
        self.assertTrue(path.endswith("资料 2.txt"))

    def test_base_name_and_volumes(self):
        self.assertEqual(base_name("/tmp/资料.tar.gz"), "资料")
        self.assertEqual(base_name("/tmp/a.7z.001"), "a")
        folder = os.path.join(self.tmp, "vols")
        os.makedirs(folder)
        for i in (1, 2, 3):
            open(os.path.join(folder, f"pack.zip.{i:03d}"), "w").close()
        found = volumes_for(os.path.join(folder, "pack.zip.002"))
        self.assertEqual([os.path.basename(p) for p in found], ["pack.zip.001", "pack.zip.002", "pack.zip.003"])

    def test_gbk_filename(self):
        name = "压缩包里的中文文件名.txt"
        archive = os.path.join(self.tmp, "gbk.zip")
        _legacy_zip(archive, name, "你好".encode("utf-8"), "gbk")
        listing = list_archive(archive)
        self.assertEqual([item.path for item in listing.items], [name])
        self.assertEqual(listing.legacy_encoding, "gb18030")
        dest = os.path.join(self.tmp, "out-gbk")
        os.makedirs(dest)
        result = extract(archive, self._opts(dest), self.cancel, _noop)
        self.assertTrue(os.path.isfile(os.path.join(dest, name)))
        self.assertEqual(result["file_count"], 1)

    def test_big5_and_shift_jis_explicit(self):
        self.assertEqual(decode_name("繁體檔名.txt".encode("big5"), "big5"), "繁體檔名.txt")
        self.assertEqual(decode_name("日本語.txt".encode("shift_jis"), "shift_jis"), "日本語.txt")
        japanese = ("これは日本語の長いファイル名です" * 3 + ".txt").encode("shift_jis")
        self.assertEqual(detect([japanese]), "shift_jis")
        traditional = ("壓縮檔裡的繁體中文檔名測試" * 3 + ".txt").encode("big5")
        self.assertEqual(detect([traditional]), "big5")
        korean = ("한국어파일이름테스트" * 3 + ".txt").encode("euc_kr")
        self.assertEqual(detect([korean]), "euc_kr")

    def test_zip_slip_is_not_written(self):
        archive = os.path.join(self.tmp, "evil.zip")
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("../outside.txt", b"pwned")
            zf.writestr("ok.txt", b"safe")
        outside = os.path.join(self.tmp, "outside.txt")
        dest = os.path.join(self.tmp, "out-slip")
        os.makedirs(dest)
        extract(archive, self._opts(dest), self.cancel, _noop)
        self.assertFalse(os.path.exists(outside))
        self.assertTrue(os.path.isfile(os.path.join(dest, "ok.txt")))
        for root, dirs, files in os.walk(self.tmp):
            self.assertNotIn("outside.txt", files)

    def test_smart_folder_and_no_overwrite(self):
        archive = os.path.join(self.tmp, "资料.zip")
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("资料/a.txt", b"1")
        dest = os.path.join(self.tmp, "out-smart")
        os.makedirs(dest)
        extract(archive, self._opts(dest), self.cancel, _noop)
        self.assertTrue(os.path.isfile(os.path.join(dest, "资料", "a.txt")))
        self.assertFalse(os.path.isdir(os.path.join(dest, "资料", "资料")))
        extract(archive, self._opts(dest), CancelToken(), _noop)
        self.assertTrue(os.path.isdir(os.path.join(dest, "资料 2")))

        loose = os.path.join(self.tmp, "loose.zip")
        with zipfile.ZipFile(loose, "w") as zf:
            zf.writestr("a.txt", b"a")
            zf.writestr("b.txt", b"b")
        dest2 = os.path.join(self.tmp, "out-loose")
        os.makedirs(dest2)
        extract(loose, self._opts(dest2), CancelToken(), _noop)
        self.assertTrue(os.path.isfile(os.path.join(dest2, "loose", "a.txt")))

    def test_utf8_zip_roundtrip_and_password(self):
        src = os.path.join(self.tmp, "笔记.txt")
        with open(src, "w", encoding="utf-8") as handle:
            handle.write("内容")
        options = CompressOptions()
        options.password = "test-pw"
        archive = compress([src], os.path.join(self.tmp, "笔记.zip"), options, self.cancel, _noop)[0]
        listing = list_archive(archive)
        self.assertTrue(listing.has_encrypted)
        self.assertEqual(listing.items[0].path, "笔记.txt")
        with self.assertRaises(ArchiveError) as caught:
            extract(archive, self._opts(os.path.join(self.tmp, "no-pw")), CancelToken(), _noop)
        self.assertEqual(caught.exception.code, "password")
        dest = os.path.join(self.tmp, "with-pw")
        os.makedirs(dest)
        bad = self._opts(dest)
        bad.password = "wrong"
        with self.assertRaises(ArchiveError) as caught:
            extract(archive, bad, CancelToken(), _noop)
        self.assertEqual(caught.exception.code, "wrong_password")
        good = self._opts(dest)
        good.password = "test-pw"
        extract(archive, good, CancelToken(), _noop)
        with open(os.path.join(dest, "笔记.txt"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "内容")

    def test_7z_roundtrip_and_header_password(self):
        folder = os.path.join(self.tmp, "项目")
        os.makedirs(folder)
        with open(os.path.join(folder, "a.txt"), "w", encoding="utf-8") as handle:
            handle.write("七")
        options = CompressOptions()
        options.format = "7z"
        options.password = "secret"
        archive = compress([folder], os.path.join(self.tmp, "项目.7z"), options, self.cancel, _noop)[0]
        with self.assertRaises(ArchiveError) as caught:
            list_archive(archive)
        self.assertEqual(caught.exception.code, "password")
        listing = list_archive(archive, password="secret")
        self.assertTrue(any(item.path.endswith("a.txt") for item in listing.items))
        dest = os.path.join(self.tmp, "out-7z")
        os.makedirs(dest)
        opts = self._opts(dest)
        opts.password = "secret"
        extract(archive, opts, CancelToken(), _noop)
        self.assertTrue(os.path.isfile(os.path.join(dest, "项目", "a.txt")))

    def test_tar_gz_bz2_xz_and_skip_junk(self):
        folder = os.path.join(self.tmp, "包")
        os.makedirs(os.path.join(folder, "子"))
        with open(os.path.join(folder, "子", "文.txt"), "w", encoding="utf-8") as handle:
            handle.write("tar")
        open(os.path.join(folder, ".DS_Store"), "w").close()
        for fmt, ext in (("tar.gz", "tar.gz"), ("tar.bz2", "tar.bz2"), ("tar.xz", "tar.xz")):
            options = CompressOptions()
            options.format = fmt
            archive = compress([folder], os.path.join(self.tmp, f"包.{ext}"), options, CancelToken(), _noop)[0]
            listing = list_archive(archive)
            paths = [item.path for item in listing.items]
            self.assertTrue(any(path.endswith("文.txt") for path in paths), paths)
            self.assertFalse(any(path.endswith(".DS_Store") for path in paths), paths)
            dest = os.path.join(self.tmp, "out-" + fmt.replace(".", ""))
            os.makedirs(dest)
            extract(archive, self._opts(dest), CancelToken(), _noop)
            self.assertTrue(os.path.isfile(os.path.join(dest, "包", "子", "文.txt")))
            self.assertFalse(os.path.exists(os.path.join(dest, "包", ".DS_Store")))

    def test_split_zip_roundtrip(self):
        src = os.path.join(self.tmp, "big.bin")
        with open(src, "wb") as handle:
            handle.write(os.urandom(8000))
        options = CompressOptions()
        options.level = 0
        options.volume_size = 2500
        parts = compress([src], os.path.join(self.tmp, "big.zip"), options, self.cancel, _noop)
        self.assertGreaterEqual(len(parts), 2)
        self.assertTrue(parts[0].endswith(".001"))
        dest = os.path.join(self.tmp, "out-vol")
        os.makedirs(dest)
        extract(parts[-1], self._opts(dest), CancelToken(), _noop)
        with open(src, "rb") as original, open(os.path.join(dest, "big.bin"), "rb") as restored:
            self.assertEqual(original.read(), restored.read())

    def test_selective_extract(self):
        archive = os.path.join(self.tmp, "sel.zip")
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("keep.txt", b"yes")
            zf.writestr("drop.txt", b"no")
        dest = os.path.join(self.tmp, "out-sel")
        os.makedirs(dest)
        options = self._opts(dest)
        options.selection = {"keep.txt"}
        extract(archive, options, self.cancel, _noop)
        self.assertTrue(os.path.isfile(os.path.join(dest, "keep.txt")))
        self.assertFalse(os.path.exists(os.path.join(dest, "drop.txt")))

    def test_corrupt_archive_leaves_no_temp(self):
        archive = os.path.join(self.tmp, "bad.zip")
        with open(archive, "wb") as handle:
            handle.write(b"PK\x03\x04this is not a real zip")
        dest = os.path.join(self.tmp, "out-bad")
        os.makedirs(dest)
        with self.assertRaises(ArchiveError):
            extract(archive, self._opts(dest), self.cancel, _noop)
        self.assertEqual(os.listdir(dest), [])

    def test_cancel_removes_temp(self):
        archive = os.path.join(self.tmp, "c.zip")
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("a.txt", b"abc")
        dest = os.path.join(self.tmp, "out-cancel")
        os.makedirs(dest)
        token = CancelToken()
        token.cancel()
        with self.assertRaises(ArchiveError) as caught:
            extract(archive, self._opts(dest), token, _noop)
        self.assertEqual(caught.exception.code, "cancelled")
        self.assertEqual(os.listdir(dest), [])

    def test_integrity_detects_damage(self):
        src = os.path.join(self.tmp, "t.txt")
        with open(src, "w", encoding="utf-8") as handle:
            handle.write("hello integrity")
        options = CompressOptions()
        archive = compress([src], os.path.join(self.tmp, "t.zip"), options, self.cancel, _noop)[0]
        report = test_archive(archive, None, [], CancelToken(), _noop)
        self.assertTrue(report["ok"])
        with open(archive, "r+b") as handle:
            handle.seek(-20, os.SEEK_END)
            handle.write(b"\x00" * 8)
        with self.assertRaises(ArchiveError):
            test_archive(archive, None, [], CancelToken(), _noop)

    def test_symlink_escape_is_skipped(self):
        folder = os.path.join(self.tmp, "links")
        os.makedirs(folder)
        outside = os.path.join(self.tmp, "secret.txt")
        with open(outside, "w", encoding="utf-8") as handle:
            handle.write("secret")
        os.symlink(outside, os.path.join(folder, "leak.txt"))
        with open(os.path.join(folder, "ok.txt"), "w", encoding="utf-8") as handle:
            handle.write("ok")
        archive = os.path.join(self.tmp, "links.tar")
        with tarfile.open(archive, "w") as tar:
            tar.add(folder, arcname="links")
        # 再放一个指向包外的符号链接成员
        dest = os.path.join(self.tmp, "out-link")
        os.makedirs(dest)
        extract(archive, self._opts(dest), self.cancel, _noop)
        self.assertFalse(os.path.lexists(os.path.join(dest, "links", "leak.txt")))
        self.assertTrue(os.path.isfile(os.path.join(dest, "links", "ok.txt")))


class GuiTests(unittest.TestCase):
    def test_window_extract_compress_and_browse(self):
        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
        from PySide6.QtCore import QTimer
        from PySide6.QtWidgets import QApplication
        from qingya.browser import Browser
        from qingya.gui import MainWindow

        QApplication.setOrganizationName("tian-qingya-test")
        QApplication.setApplicationName("QingYaTest")
        app = QApplication.instance() or QApplication([])
        window = MainWindow()
        window.settings.setValue("revealExtract", False)
        window.settings.setValue("revealCompress", False)
        folder = tempfile.mkdtemp(prefix="qingya-gui-")
        try:
            archive = os.path.join(folder, "资料.zip")
            with zipfile.ZipFile(archive, "w") as zf:
                zf.writestr("资料/a.txt", "界面")
            note = os.path.join(folder, "笔记.txt")
            with open(note, "w", encoding="utf-8") as handle:
                handle.write("压缩")
            window.extract_archives([archive])
            window.compress_items([note])
            started = time.time()

            def poll():
                tasks = list(window.tasks.values())
                if tasks and all(task.state in ("done", "failed", "cancelled") for task in tasks):
                    app.quit()
                    return
                if time.time() - started > 30:
                    app.quit()
                    return
                QTimer.singleShot(100, poll)

            QTimer.singleShot(50, poll)
            app.exec()
            states = {task.kind: task.state for task in window.tasks.values()}
            summaries = {task.kind: task.summary for task in window.tasks.values()}
            self.assertEqual(states.get("extract"), "done", summaries)
            self.assertEqual(states.get("compress"), "done", summaries)
            self.assertTrue(os.path.isfile(os.path.join(folder, "资料", "a.txt")))
            self.assertTrue(os.path.isfile(os.path.join(folder, "笔记.zip")))
            browser = Browser(os.path.join(folder, "笔记.zip"), window)
            self.assertGreaterEqual(browser.tree.topLevelItemCount(), 1)
            self.assertIn("ZIP", browser.summary.text())
            browser.close()
            window.close()
        finally:
            shutil.rmtree(folder, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
