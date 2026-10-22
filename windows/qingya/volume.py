"""把多个分卷当成一个可来回 seek 的文件。"""

from __future__ import annotations

import io
import os


class MultiVolume(io.RawIOBase):
    def __init__(self, paths: list[str]):
        self.paths = list(paths)
        self.sizes = [os.path.getsize(p) for p in paths]
        self.total = sum(self.sizes)
        self._pos = 0
        self._idx = -1
        self._fh = None
        self.name = paths[0] if paths else ""

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def writable(self) -> bool:
        return False

    def tell(self) -> int:
        return self._pos

    def close(self) -> None:
        if self._fh is not None:
            self._fh.close()
            self._fh = None
        super().close()

    def seek(self, offset: int, whence: int = os.SEEK_SET) -> int:
        if whence == os.SEEK_CUR:
            offset = self._pos + offset
        elif whence == os.SEEK_END:
            offset = self.total + offset
        self._pos = max(0, min(self.total, offset))
        return self._pos

    def _open_at(self, pos: int) -> None:
        offset = pos
        index = 0
        for i, size in enumerate(self.sizes):
            if offset < size or i == len(self.sizes) - 1:
                index = i
                break
            offset -= size
        if self._idx != index or self._fh is None:
            if self._fh is not None:
                self._fh.close()
            self._fh = open(self.paths[index], "rb")
            self._idx = index
        self._fh.seek(offset)

    def read(self, size: int = -1) -> bytes:
        if self.closed or self._pos >= self.total:
            return b""
        if size is None or size < 0:
            size = self.total - self._pos
        chunks = []
        remaining = size
        while remaining > 0 and self._pos < self.total:
            self._open_at(self._pos)
            left = self.sizes[self._idx] - self._fh.tell()
            data = self._fh.read(min(remaining, max(0, left)))
            if not data:
                break
            chunks.append(data)
            remaining -= len(data)
            self._pos += len(data)
        return b"".join(chunks)

    def readinto(self, b) -> int:
        data = self.read(len(b))
        n = len(data)
        b[:n] = data
        return n
