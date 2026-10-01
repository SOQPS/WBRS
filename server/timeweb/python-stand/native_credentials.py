"""Server-only Node-compatible AES-GCM credential storage and Firebase SCRYPT.

No network, password changes, credential writes or session creation. All public
errors are generic. A timed-out KDF keeps its worker slot until work completes.
"""
from __future__ import annotations

import base64
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from dataclasses import dataclass
import hashlib
import hmac
import json
import re
import threading

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MEMORY_LIMIT = 64 * 1024 * 1024
PARAMETER_FIELDS = {"material_format", "config_ref", "config_identity", "password_version",
                    "providers", "disabled", "email_verified", "valid_since"}


class CredentialUnavailable(Exception):
    """Private material/configuration cannot safely be used."""


class KdfBusy(CredentialUnavailable):
    """All bounded password work slots are occupied."""


def compact_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def decode_base64(value, *, allow_empty=False, max_bytes=256):
    if (not isinstance(value, str) or (not value and not allow_empty)
            or len(value) > ((max_bytes + 2) // 3) * 4
            or re.fullmatch(r"[A-Za-z0-9+/_-]*={0,2}", value) is None or len(value) % 4 == 1):
        raise CredentialUnavailable()
    try:
        raw = base64.b64decode(value.replace("-", "+").replace("_", "/") + "=" * (-len(value) % 4), validate=True)
    except (ValueError, TypeError):
        raise CredentialUnavailable() from None
    normalized = value.replace("-", "+").replace("_", "/").rstrip("=")
    if (len(raw) > max_bytes or base64.b64encode(raw).decode().rstrip("=") != normalized
            or raw == b"REDACTED"):
        raise CredentialUnavailable()
    return raw


def unique_json(raw):
    def unique(pairs):
        result = {}
        for name, value in pairs:
            if name in result:
                raise ValueError()
            result[name] = value
        return result
    try:
        value = json.loads(raw, object_pairs_hook=unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (TypeError, ValueError, UnicodeError, RecursionError):
        raise CredentialUnavailable() from None
    if not isinstance(value, dict):
        raise CredentialUnavailable()
    return value


@dataclass(frozen=True, repr=False)
class CredentialMaterial:
    uid: str
    password_hash: str
    password_salt: str
    password_version: object
    providers: tuple
    disabled: bool
    email_verified: bool
    valid_since: object


class CredentialCodec:
    def __init__(self, hash_config, config_ref, wrapping_key):
        if (not isinstance(hash_config, dict) or hash_config.get("algorithm") != "SCRYPT"
                or not isinstance(config_ref, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,128}", config_ref) is None
                or not isinstance(wrapping_key, bytes) or len(wrapping_key) != 32):
            raise CredentialUnavailable()
        rounds = hash_config.get("rounds")
        memory_cost = hash_config.get("memoryCost")
        if (type(rounds) is not int or not 1 <= rounds <= 32
                or type(memory_cost) is not int or not 1 <= memory_cost <= 18
                or 128 * (2 ** memory_cost) * rounds + 128 * rounds + 1024 > MEMORY_LIMIT):
            raise CredentialUnavailable()
        self.signer_key = decode_base64(hash_config.get("signerKey"))
        self.salt_separator = decode_base64(hash_config.get("saltSeparator"), allow_empty=True)
        if len(self.signer_key) < 16:
            raise CredentialUnavailable()
        self.n = 2 ** memory_cost
        self.r = rounds
        self.config_ref = config_ref
        self._wrapping_key = wrapping_key
        self.config_identity = hashlib.sha256(compact_json([hash_config["algorithm"],
            hash_config["signerKey"], hash_config["saltSeparator"], rounds, memory_cost]).encode()).hexdigest()

    def _aad(self, uid, parameters, part):
        return compact_json(["clrs_staging", "auth_credentials", uid, part,
            parameters["material_format"], parameters["config_ref"], parameters["config_identity"],
            parameters["password_version"], parameters["providers"], parameters["disabled"],
            parameters["email_verified"], parameters["valid_since"]]).encode("utf-8")

    def decode(self, row):
        try:
            uid = row["uid"]
            parameters = row["parameters"]
            if isinstance(parameters, (str, bytes)):
                parameters = unique_json(parameters)
            if (not isinstance(uid, str) or not 1 <= len(uid) <= 191 or "\0" in uid
                    or row["scheme"] != "firebase_scrypt" or not isinstance(parameters, dict)
                    or set(parameters) != PARAMETER_FIELDS
                    or parameters["material_format"] != "aes256gcm-v1"
                    or parameters["config_ref"] != self.config_ref
                    or parameters["config_identity"] != self.config_identity
                    or type(parameters["disabled"]) is not bool
                    or type(parameters["email_verified"]) is not bool
                    or not isinstance(parameters["providers"], list)
                    or any(not isinstance(p, str) or not p for p in parameters["providers"])
                    or "password" not in parameters["providers"]
                    or not ((type(parameters["password_version"]) is int and parameters["password_version"] == 0)
                            or parameters["password_version"] == "0")):
                raise CredentialUnavailable()
            since = parameters["valid_since"]
            if not (since is None or (type(since) is int and 0 <= since <= 2 ** 53 - 1)
                    or (isinstance(since, str) and re.fullmatch(r"\d{1,20}", since))):
                raise CredentialUnavailable()
            values = []
            for field, part in [("password_hash", "hash"), ("password_salt", "salt")]:
                blob = row[field]
                if not isinstance(blob, (bytes, bytearray, memoryview)) or not 28 <= len(blob) <= 1024:
                    raise CredentialUnavailable()
                blob = bytes(blob)
                # Node layout is nonce(12), tag(16), ciphertext. AESGCM's
                # decrypt API expects ciphertext followed by the tag.
                plain = AESGCM(self._wrapping_key).decrypt(blob[:12], blob[28:] + blob[12:28],
                                                          self._aad(uid, parameters, part))
                values.append(plain.decode("utf-8"))
            expected = decode_base64(values[0])
            decode_base64(values[1], allow_empty=True)
            if len(expected) != len(self.signer_key):
                raise CredentialUnavailable()
            return CredentialMaterial(uid, values[0], values[1], parameters["password_version"],
                tuple(parameters["providers"]), parameters["disabled"], parameters["email_verified"], since)
        except CredentialUnavailable:
            raise
        except Exception:
            raise CredentialUnavailable() from None

    def dummy(self):
        return CredentialMaterial("synthetic-dummy", base64.b64encode(bytes(len(self.signer_key))).decode(),
            base64.b64encode(bytes(16)).decode(), 0, ("password",), False, False, None)


def credential_row_identity(row):
    """Bind the later session INSERT to the ciphertext used for this KDF."""
    try:
        parameters = row["parameters"]
        if isinstance(parameters, (str, bytes)):
            parameters = unique_json(parameters)
        data = [row["uid"], row["scheme"], bytes(row["password_hash"]).hex(),
                bytes(row["password_salt"]).hex(), parameters]
        # SQL JSON key order is irrelevant for this internal Python binding.
        return hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False,
                                         separators=(",", ":")).encode()).digest()
    except Exception:
        raise CredentialUnavailable() from None


class FirebaseScryptVerifier:
    def __init__(self, codec, *, workers=2, derive=hashlib.scrypt):
        if not isinstance(codec, CredentialCodec) or type(workers) is not int or not 1 <= workers <= 2:
            raise CredentialUnavailable()
        self.codec = codec
        self._derive = derive
        self._slots = threading.BoundedSemaphore(workers)
        self._pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="clrs-kdf")
        self._closed = False

    def _verify(self, material, password_bytes):
        if not ((type(material.password_version) is int and material.password_version == 0)
                or material.password_version == "0") or "password" not in material.providers:
            raise CredentialUnavailable()
        expected = decode_base64(material.password_hash)
        if len(expected) != len(self.codec.signer_key):
            raise CredentialUnavailable()
        salt = decode_base64(material.password_salt, allow_empty=True) + self.codec.salt_separator
        derived = self._derive(password_bytes, salt=salt, n=self.codec.n, r=self.codec.r,
                               p=1, dklen=64, maxmem=MEMORY_LIMIT)
        encryptor = Cipher(algorithms.AES(derived[:32]), modes.CTR(bytes(16))).encryptor()
        generated = encryptor.update(self.codec.signer_key) + encryptor.finalize()
        return hmac.compare_digest(generated, expected)

    def verify(self, material, password, *, timeout=1.5):
        try:
            password_bytes = password.encode("utf-8") if isinstance(password, str) else None
        except UnicodeError:
            raise CredentialUnavailable() from None
        if (self._closed or not isinstance(material, CredentialMaterial)
                or password_bytes is None or len(password_bytes) > 4096
                or not isinstance(timeout, (int, float)) or not 0 < timeout <= 1.5):
            raise CredentialUnavailable()
        if material.disabled:
            return False
        if not self._slots.acquire(blocking=False):
            raise KdfBusy()
        try:
            future = self._pool.submit(self._verify, material, password_bytes)
        except Exception:
            self._slots.release()
            raise CredentialUnavailable() from None
        future.add_done_callback(lambda _: self._slots.release())
        try:
            return future.result(timeout=timeout)
        except (FutureTimeout, Exception):
            # The worker remains counted until done, including after timeout.
            raise CredentialUnavailable() from None

    def close(self):
        self._closed = True
        self._pool.shutdown(wait=False, cancel_futures=True)
