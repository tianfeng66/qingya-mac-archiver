"""解压密码本。Windows 用系统凭据管理器，macOS 用钥匙串，测试可换成内存。"""

from __future__ import annotations

import json

SERVICE = "com.tian.qingya"
ACCOUNT = "saved-passwords"


class MemoryStore:
    def __init__(self):
        self._items: list[str] = []

    def candidates(self) -> list[str]:
        return list(self._items)

    def add(self, password: str) -> None:
        if password and password not in self._items:
            self._items.insert(0, password)
            del self._items[60:]

    def remove(self, password: str) -> None:
        self._items = [item for item in self._items if item != password]

    def clear(self) -> None:
        self._items.clear()


class KeyringStore:
    def __init__(self):
        self._ok = True

    def _load(self) -> list[str]:
        try:
            import keyring
            raw = keyring.get_password(SERVICE, ACCOUNT)
        except Exception:
            self._ok = False
            return []
        if not raw:
            return []
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return []
        if isinstance(data, list):
            return [item for item in data if isinstance(item, str)]
        return []

    def _save(self, items: list[str]) -> None:
        import keyring
        keyring.set_password(SERVICE, ACCOUNT, json.dumps(items[:60], ensure_ascii=False))

    def candidates(self) -> list[str]:
        if not self._ok:
            return []
        try:
            return self._load()
        except Exception:
            self._ok = False
            return []

    def add(self, password: str) -> None:
        if not password:
            return
        items = [password] + [item for item in self.candidates() if item != password]
        try:
            self._save(items[:60])
        except Exception:
            self._ok = False

    def remove(self, password: str) -> None:
        try:
            self._save([item for item in self.candidates() if item != password])
        except Exception:
            self._ok = False

    def clear(self) -> None:
        try:
            import keyring
            keyring.delete_password(SERVICE, ACCOUNT)
        except Exception:
            pass
