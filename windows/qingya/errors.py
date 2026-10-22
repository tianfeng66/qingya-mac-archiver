"""给人看的错误。code 用来区分密码、格式和取消，界面据此决定下一步。"""


class ArchiveError(Exception):
    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


class Cancelled(ArchiveError):
    def __init__(self):
        super().__init__("cancelled", "已取消")


def password_required() -> ArchiveError:
    return ArchiveError("password", "这个压缩包有密码")


def wrong_password() -> ArchiveError:
    return ArchiveError("wrong_password", "密码不对")


def unsupported(message: str) -> ArchiveError:
    return ArchiveError("unsupported", message)


def failed(message: str) -> ArchiveError:
    return ArchiveError("failed", message)


def not_writable(path: str) -> ArchiveError:
    return ArchiveError("not_writable", f"这个位置写不进去：{path}")
