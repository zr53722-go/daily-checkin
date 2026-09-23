#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
decrypt-trae.py —— 解密 Trae 桌面客户端存储的登录态

用法：
    python decrypt-trae.py <base64密文>
    或
    python decrypt-trae.py --file <storage.json路径>

输出：解密后的 JSON（含 token / refreshToken / host / expiredAt）

加密格式（逆向自 Trae 桌面端）：
    [6 字节头 74 63 05 10 00 00][32 字节密钥材料][AES-CBC 密文]
密钥派生：
    n = SHA512(keyMaterial) || (Woe[i] ^ Voe[i])     // 128 字节
    n[0..64] = SHA512(n)
    aesKey = n[0..16]，iv = n[16..32]
    明文 = SHA512(payload) || payload（前 64 字节为校验和）
"""

import base64
import hashlib
import json
import os
import sys

# Woe / Voe 掩码表（与 C# 版 PlatformAuth.cs 完全一致）
WOE = [
    82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251,
    124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203,
    84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78,
    8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37,
]
VOE = [
    31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95,
    96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239,
    160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97,
    23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125,
]
HEADER = bytes([116, 99, 5, 16, 0, 0])

_KEY_NAME = "iCubeAuthInfo://icube.cloudide"
_DEVICE_PREFIX = "iCubeAuthInfo://icube-dc:"


def _aes_cbc_decrypt(key: bytes, iv: bytes, data: bytes) -> bytes:
    """AES-CBC 解密（优先 pycryptodome，回退到 cryptography）。"""
    try:
        from Crypto.Cipher import AES
        return AES.new(key, AES.MODE_CBC, iv).decrypt(data)
    except ImportError:
        pass
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        return dec.update(data) + dec.finalize()
    except ImportError:
        raise RuntimeError(
            "需要加密库。请执行以下任一命令：\n"
            "    pip install pycryptodome\n"
            "    pip install cryptography"
        )


def decrypt_blob(encoded: str) -> dict:
    """解密 base64 密文，返回解析后的 JSON dict。"""
    blob = base64.b64decode(encoded.strip())
    if len(blob) <= 102:
        raise ValueError("密文过短")
    if blob[:6] != HEADER:
        raise ValueError("头部不匹配，可能不是 Trae 的加密数据")

    key_material = blob[6:38]
    mask = bytes(a ^ b for a, b in zip(WOE, VOE))

    n = hashlib.sha512(key_material).digest() + mask
    derived = hashlib.sha512(n).digest()
    aes_key, iv = derived[:16], derived[16:32]

    plain = _aes_cbc_decrypt(aes_key, iv, blob[38:])
    plain = plain[:-plain[-1]]  # 去 PKCS7 填充

    if hashlib.sha512(plain[64:]).digest() != plain[:64]:
        raise ValueError("校验和不匹配，密钥或数据有误")

    return json.loads(plain[64:].decode("utf-8"))


def extract_from_storage(path: str):
    """从 storage.json 中提取并解密登录态。"""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    encoded = data.get(_KEY_NAME)
    if not encoded:
        raise ValueError("storage.json 中未找到 {}".format(_KEY_NAME))

    device_id = ""
    for key in data:
        if key.startswith(_DEVICE_PREFIX):
            device_id = key[len(_DEVICE_PREFIX):]

    info = decrypt_blob(encoded)
    info["_deviceId"] = device_id
    return info


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)

    try:
        if args[0] == "--file":
            if len(args) < 2:
                print("用法: python decrypt-trae.py --file <storage.json路径>")
                sys.exit(1)
            result = extract_from_storage(args[1])
        else:
            result = decrypt_blob(args[0])
    except Exception as e:
        print("解密失败: {}".format(e), file=sys.stderr)
        sys.exit(1)

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
