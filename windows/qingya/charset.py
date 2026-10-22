"""老式 zip 的文件名编码。同一个包只判断一次，样本越多越准。"""

from __future__ import annotations

import locale
import os
import unicodedata

from charset_normalizer import from_bytes

# 界面上的选项 -> Python 编码名
CHOICES = [
    ("auto", "自动识别"),
    ("gb18030", "简体中文（GBK / GB18030）"),
    ("big5", "繁体中文（Big5）"),
    ("shift_jis", "日文（Shift_JIS）"),
    ("euc_kr", "韩文（EUC-KR）"),
    ("cp437", "DOS 西文（CP437）"),
    ("cp1252", "西欧（Windows-1252）"),
]
CODECS = {
    "gb18030": "gb18030",
    "big5": "big5",
    "shift_jis": "shift_jis",
    "euc_kr": "euc_kr",
    "cp437": "cp437",
    "cp1252": "cp1252",
}
ALIASES = {
    "gbk": "gb18030",
    "gb2312": "gb18030",
    "hz": "gb18030",
    "big5hkscs": "big5",
    "cp950": "big5",
    "cp932": "shift_jis",
    "shift_jis_2004": "shift_jis",
    "shift_jisx0213": "shift_jis",
    "euc_jp": "shift_jis",
    "johab": "euc_kr",
    "cp949": "euc_kr",
    "iso2022_kr": "euc_kr",
    "windows-1252": "cp1252",
    "iso8859-1": "cp1252",
    "latin-1": "cp1252",
    "ibm437": "cp437",
    "ibm866": "cp437",
}


def short_title(encoding: str | None) -> str:
    if not encoding or encoding == "auto":
        return "自动"
    for key, title in CHOICES:
        if key == encoding:
            return title.split("（")[0]
    return encoding


def language_order() -> list[str]:
    blob = " ".join(
        filter(None, [
            os.environ.get("LANG", ""),
            os.environ.get("LC_ALL", ""),
            locale.getlocale()[0] or "",
            locale.getdefaultlocale()[0] or "",
        ])
    ).lower().replace("-", "_")
    if any(token in blob for token in ("zh_tw", "zh_hk", "hant")):
        return ["big5", "gb18030", "shift_jis", "euc_kr"]
    if blob.startswith("ja") or "ja_" in blob:
        return ["shift_jis", "gb18030", "big5", "euc_kr"]
    if blob.startswith("ko") or "ko_" in blob:
        return ["euc_kr", "gb18030", "big5", "shift_jis"]
    return ["gb18030", "big5", "shift_jis", "euc_kr"]


def _decodes(data: bytes, codec: str) -> str | None:
    try:
        return data.decode(CODECS.get(codec, codec))
    except (UnicodeDecodeError, LookupError):
        return None


def _score(text: str) -> int:
    score = 0
    for ch in text:
        code = ord(ch)
        if ch == "\ufffd" or (code < 32 and ch not in "\n\r\t"):
            score -= 8
        elif 0x4E00 <= code <= 0x9FFF or 0x3400 <= code <= 0x4DBF:
            score += 4
        elif 0x3040 <= code <= 0x30FF:
            score += 4
        elif 0xAC00 <= code <= 0xD7A3:
            score += 4
        elif ch in "，。、；：？！「」『』（）【】《》":
            score += 2
        elif code > 0xFFFF:
            score -= 1
    return score


def canonical(name: str | None) -> str | None:
    if not name:
        return None
    key = name.lower().replace("-", "_")
    key = ALIASES.get(key, key)
    if key in CODECS:
        return key
    return None


def _script_score(text: str) -> int:
    """平手时看文字像不像那种语言。偶然夹杂的假名/谚文不加分，避免乱码抢赢。"""
    common = set("的一是不了在有人我中大为上来说国和到地出要于就下得可你年生自会那后能对着事文件名压缩包测试里")
    trad = set("檔裡體測試壓縮這為與門國說後過還對時個東們無應經發開關問電")
    kana = hangul = cjk = common_hits = 0
    for ch in text:
        code = ord(ch)
        if 0x3040 <= code <= 0x30FF or 0xFF66 <= code <= 0xFF9D:
            kana += 1
        elif 0xAC00 <= code <= 0xD7A3:
            hangul += 1
        elif 0x4E00 <= code <= 0x9FFF or 0x3400 <= code <= 0x4DBF:
            cjk += 1
            if ch in common or ch in trad:
                common_hits += 1
        elif ch == "\ufffd" or (code < 32 and ch not in "\n\r\t"):
            common_hits -= 2
    score = common_hits * 4 + cjk
    if kana >= 2 and kana * 2 > cjk:
        score += kana * 8
    if hangul >= 2 and hangul * 2 > cjk:
        score += hangul * 8
    return score


def detect(samples: list[bytes]) -> str:
    usable = [s for s in samples if s][:400]
    if not usable:
        return language_order()[0]
    order = language_order()
    joined = b"\n".join(usable)
    isolation = order + ["cp437", "cp1252"]
    try:
        matches = list(from_bytes(joined, cp_isolation=isolation, enable_fallback=False))
    except Exception:
        matches = []
    # 短文件名经常多种编码都能解、chaos 打成平手。平手时按系统语言选
    # （简体中文优先 GBK），只有某一家明显更准时才用那一家。
    close: list[str] = []
    best_chaos = None
    for match in matches:
        codec = canonical(match.encoding)
        if not codec or any(_decodes(sample, codec) is None for sample in usable):
            continue
        chaos = float(getattr(match, "chaos", 0) or 0)
        if best_chaos is None or chaos < best_chaos - 1e-6:
            best_chaos = chaos
            close = [codec]
        elif chaos <= best_chaos + 1e-6 and codec not in close:
            close.append(codec)
    if close:
        if len(close) == 1:
            return close[0]
        best_codec = close[0]
        best_score = None
        for codec in close:
            text = "".join(_decodes(sample, codec) or "" for sample in usable)
            score = _script_score(text)
            if codec in order:
                score += len(order) - order.index(codec)
            if best_score is None or score > best_score:
                best_score = score
                best_codec = codec
        return best_codec

    best_codec = "cp437"
    best_score = None
    for index, codec in enumerate(order + ["cp437", "cp1252"]):
        texts = [_decodes(sample, codec) for sample in usable]
        if any(text is None for text in texts):
            continue
        score = sum(_score(text or "") for text in texts) - index
        if best_score is None or score > best_score:
            best_score = score
            best_codec = codec
    return best_codec


def decode_name(raw: str | bytes, encoding: str | None) -> str:
    if isinstance(raw, str):
        return unicodedata.normalize("NFC", raw)
    codec = None if not encoding or encoding == "auto" else encoding
    if codec is None:
        codec = detect([raw])
    text = _decodes(raw, codec)
    if text is None:
        text = raw.decode("latin-1")
    return unicodedata.normalize("NFC", text)
