"""轻压 Windows 版入口。双击打开；把文件拖到图标上也可以。"""

from __future__ import annotations

import json
import os
import sys
import tempfile


def _paths_from_argv(argv: list[str]) -> list[str]:
    paths = []
    for item in argv:
        if item.startswith("-"):
            continue
        if os.path.exists(item):
            paths.append(os.path.abspath(item))
    return paths


def run_selftest(result_path: str) -> int:
    from PySide6.QtWidgets import QApplication
    from qingya.compress import CompressOptions, compress
    from qingya.extract import CancelToken, ExtractOptions, extract
    from qingya.gui import MainWindow

    app = QApplication.instance() or QApplication([])
    folder = tempfile.mkdtemp(prefix="qingya-selftest-")
    try:
        src = os.path.join(folder, "中文.txt")
        with open(src, "w", encoding="utf-8") as handle:
            handle.write("ok")
        options = CompressOptions()
        archive = compress([src], os.path.join(folder, "a.zip"), options, CancelToken(), lambda *_a: None)[0]
        dest = os.path.join(folder, "out")
        os.makedirs(dest)
        extract(archive, ExtractOptions(dest), CancelToken(), lambda *_a: None)
        with open(os.path.join(dest, "中文.txt"), encoding="utf-8") as handle:
            text = handle.read()
        window = MainWindow()
        window.close()
        ok = text == "ok"
        with open(result_path, "w", encoding="utf-8") as handle:
            handle.write("OK\n" if ok else "FAIL\n")
        return 0 if ok else 1
    except Exception as exc:
        with open(result_path, "w", encoding="utf-8") as handle:
            handle.write("FAIL\n" + str(exc))
        return 1
    finally:
        app.quit()


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv if argv is None else argv)
    if os.name == "nt":
        try:
            import ctypes
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("com.tian.qingya")
        except Exception:
            pass

    if "--self-test" in argv:
        target = os.environ.get("QINGYA_SELFTEST") or os.path.join(os.getcwd(), "selftest-result.txt")
        return run_selftest(target)

    from PySide6.QtCore import Qt
    from PySide6.QtNetwork import QLocalServer, QLocalSocket
    from PySide6.QtWidgets import QApplication

    from qingya.gui import STYLESHEET, MainWindow, apply_font, install_excepthook

    install_excepthook()
    QApplication.setOrganizationName("tian")
    QApplication.setOrganizationDomain("tian.qingya")
    QApplication.setApplicationName("QingYa")
    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(argv)
    apply_font(app)
    app.setStyleSheet(STYLESHEET)

    paths = _paths_from_argv(argv[1:])
    flags = {"--extract", "--compress"}
    mode = next((item for item in argv[1:] if item in flags), "")

    socket = QLocalSocket()
    socket.connectToServer("QingYa")
    if socket.waitForConnected(250):
        socket.write(json.dumps({"mode": mode, "paths": paths}).encode("utf-8"))
        socket.flush()
        socket.waitForBytesWritten(1000)
        return 0

    window = MainWindow()
    server = QLocalServer()
    QLocalServer.removeServer("QingYa")
    server.listen("QingYa")

    def incoming() -> None:
        client = server.nextPendingConnection()
        if client is None:
            return
        if not client.waitForReadyRead(1000):
            client.disconnectFromServer()
            return
        try:
            payload = json.loads(bytes(client.readAll()).decode("utf-8"))
        except json.JSONDecodeError:
            payload = {}
        client.disconnectFromServer()
        got = payload.get("paths") or []
        got_mode = payload.get("mode") or ""
        if got_mode == "--compress":
            window.compress_items(got)
        elif got_mode == "--extract":
            window.extract_archives(got)
        else:
            window.open_paths(got)
        window.show()
        window.raise_()
        window.activateWindow()

    server.newConnection.connect(incoming)
    window.show()
    if "--screenshot" in argv:
        index = argv.index("--screenshot")
        target = argv[index + 1] if index + 1 < len(argv) else "windows.png"
        app.processEvents()
        window.grab().save(target)
        print(target)
        return 0
    if mode == "--compress":
        window.compress_items(paths)
    elif mode == "--extract":
        window.extract_archives(paths)
    elif paths:
        window.open_paths(paths)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
