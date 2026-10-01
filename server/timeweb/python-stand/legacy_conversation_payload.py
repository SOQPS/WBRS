"""Bounded legacy Firestore decoding. Never return an entire raw document.

Only the reviewed conversation fields become API data. Source blobs stay in
legacy_documents; malformed/unknown optional fields are explicitly unavailable.
"""
from __future__ import annotations

import base64
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import math
import re
from urllib.parse import unquote, urlsplit

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import secrets


class LegacyInvalid(Exception):
    """Safe error with no payload, path, user or connector details."""


MAX_DOCUMENT_BYTES = 131_072
STAMP = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z")
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def _canonical_json(value):
    """Match import-core payloadHash's JSON.stringify(canonical(raw)).

    Firestore int64 values are strings. Finite JSON doubles use ECMAScript's
    fixed/exponent boundaries; keys follow UTF-16 sort and JS integer-key order.
    A mismatch is refused instead of treating a changed parent as authorized.
    """
    if value is None or isinstance(value, (str, bool)):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    if type(value) is int:
        # Imported JSON came from Node, so unsafe integers must already be its
        # serialized shortest Number spelling. Round-trip catches alterations.
        return _canonical_json(float(value)) if abs(value) >= 10 ** 21 else str(value)
    if type(value) is float:
        if not math.isfinite(value):
            raise LegacyInvalid()
        if value == 0:
            return "0"
        raw = repr(value).lower()
        if 1e-6 <= abs(value) < 1e21:
            fixed = format(Decimal(raw), "f")
            return fixed.rstrip("0").rstrip(".") if "." in fixed else fixed
        mantissa, exponent = raw.split("e") if "e" in raw else (raw, "0")
        mantissa = mantissa.rstrip("0").rstrip(".") if "." in mantissa else mantissa
        exponent_number = int(exponent)
        return mantissa + "e" + ("+" if exponent_number >= 0 else "-") + str(abs(exponent_number))
    if isinstance(value, list):
        return "[" + ",".join(_canonical_json(item) for item in value) + "]"
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise LegacyInvalid()
        def array_index(key):
            return (key == "0" or (key.isascii() and key.isdecimal() and not key.startswith("0"))) and int(key) < 2 ** 32 - 1
        numeric = sorted((key for key in value if array_index(key)), key=int)
        rest = sorted((key for key in value if not array_index(key)), key=lambda key: key.encode("utf-16-be", "strict"))
        return "{" + ",".join(_canonical_json(key) + ":" + _canonical_json(value[key]) for key in numeric + rest) + "}"
    raise LegacyInvalid()


def payload_digest(value):
    try:
        return hashlib.sha256(_canonical_json(value).encode("utf-8", "strict")).hexdigest()
    except (ValueError, TypeError, UnicodeError, OverflowError, RecursionError):
        raise LegacyInvalid() from None


def text(value, maximum=191, *, required=False):
    if value is None and not required:
        return None
    if not isinstance(value, str) or len(value) > maximum or (required and not value):
        raise LegacyInvalid()
    try:
        value.encode("utf-8", "strict")
    except UnicodeError:
        raise LegacyInvalid() from None
    return value


def identifier(value, *, uid=False):
    value = text(value, 191 if uid else 1500, required=True)
    if value in {".", ".."} or "/" in value or len(value.encode()) > (764 if uid else 1500):
        raise LegacyInvalid()
    return value


def timestamp_ns(value):
    if not isinstance(value, str):
        raise LegacyInvalid()
    match = STAMP.fullmatch(value)
    if not match:
        raise LegacyInvalid()
    try:
        date = datetime.strptime(match[1], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        raise LegacyInvalid() from None
    delta = date - EPOCH
    return (delta.days * 86_400 + delta.seconds) * 1_000_000_000 + int((match[2] or "").ljust(9, "0"))


def message_time(payload, field):
    value = payload["fields"].get(field)
    if isinstance(value, dict) and set(value) == {"timestampValue"}:
        return timestamp_ns(value["timestampValue"]), value["timestampValue"], field
    if isinstance(value, dict) and set(value) == {"integerValue"}:
        raw = value["integerValue"]
        if isinstance(raw, str) and re.fullmatch(r"[0-9]+", raw):
            millis = int(raw)
            if 100_000_000_000 <= millis <= 253_402_300_799_999:
                seconds, fraction = divmod(millis, 1000)
                date = datetime.fromtimestamp(seconds, timezone.utc)
                iso = date.strftime("%Y-%m-%dT%H:%M:%S") + f".{fraction:03d}Z"
                return millis * 1_000_000, iso, field + "_legacy_milliseconds"
    # Never guess seconds, a local timezone, or the current clock. The actual
    # exported document creation time is preserved and labelled as a fallback.
    return timestamp_ns(payload["createTime"]), payload["createTime"], "document_create_time"


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise LegacyInvalid()
        result[key] = value
    return result


def document(value):
    try:
        if isinstance(value, (bytes, bytearray)):
            value = bytes(value).decode("utf-8", "strict")
        if isinstance(value, str):
            if len(value.encode()) > MAX_DOCUMENT_BYTES:
                raise LegacyInvalid()
            value = json.loads(value, object_pairs_hook=_pairs,
                parse_constant=lambda _: (_ for _ in ()).throw(LegacyInvalid()))
        if (not isinstance(value, dict) or set(value) != {"fields", "createTime", "updateTime"}
                or not isinstance(value["fields"], dict)):
            raise LegacyInvalid()
        encoded = json.dumps(value, ensure_ascii=False, allow_nan=False).encode()
        if len(encoded) > MAX_DOCUMENT_BYTES:
            raise LegacyInvalid()
        timestamp_ns(value["createTime"]); timestamp_ns(value["updateTime"])
        return value
    except (ValueError, TypeError, UnicodeError, OverflowError, RecursionError):
        raise LegacyInvalid() from None


def field(fields, name, tag, *, required=False):
    value = fields.get(name)
    if value is None:
        if required:
            raise LegacyInvalid()
        return None
    if not isinstance(value, dict) or len(value) != 1:
        raise LegacyInvalid()
    if "nullValue" in value:
        if required:
            raise LegacyInvalid()
        return None
    if tag not in value:
        raise LegacyInvalid()
    return value[tag]


def string_field(fields, name, maximum=191, *, required=False):
    return text(field(fields, name, "stringValue", required=required), maximum, required=required)


def uid_list(fields, name, maximum=1000):
    array = field(fields, name, "arrayValue")
    if array is None:
        return []
    if (not isinstance(array, dict) or set(array) - {"values"}
            or not isinstance(array.get("values", []), list) or len(array.get("values", [])) > maximum):
        raise LegacyInvalid()
    values = []
    for item in array.get("values", []):
        if not isinstance(item, dict) or set(item) != {"stringValue"}:
            raise LegacyInvalid()
        uid = identifier(item["stringValue"], uid=True)
        if uid not in values:
            values.append(uid)
    return values


class OpaqueReferences:
    """Separate domains; encrypted cursor/media values contain no public URL."""
    def __init__(self, key, *, random_bytes=secrets.token_bytes):
        if not isinstance(key, bytes) or len(key) != 32:
            raise LegacyInvalid()
        self._cipher = AESGCM(key); self._random = random_bytes

    def seal(self, purpose, value):
        if purpose not in {"cursor", "media"}:
            raise LegacyInvalid()
        plain = json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
        if len(plain) > 2800:
            raise LegacyInvalid()
        nonce = self._random(12)
        encrypted = self._cipher.encrypt(nonce, plain, ("clrs-legacy-read-v1/" + purpose).encode())
        return base64.urlsafe_b64encode(nonce + encrypted).decode().rstrip("=")

    def open(self, purpose, value):
        if purpose not in {"cursor", "media"} or not isinstance(value, str) or len(value) > 4096:
            raise LegacyInvalid()
        try:
            if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
                raise LegacyInvalid()
            raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
            if len(raw) < 29 or base64.urlsafe_b64encode(raw).decode().rstrip("=") != value:
                raise LegacyInvalid()
            result = json.loads(self._cipher.decrypt(raw[:12], raw[12:],
                ("clrs-legacy-read-v1/" + purpose).encode()), object_pairs_hook=_pairs)
            if not isinstance(result, dict):
                raise LegacyInvalid()
            return result
        except Exception:
            raise LegacyInvalid() from None


def media_reference(value, *, bucket, codec, binding, now):
    value = text(value, 4096)
    if value is None or value == "":
        return None
    # Gift assets are logical bundle names, never disk paths fetched by server.
    if re.fullmatch(r"assets/gifts/[A-Za-z0-9 _().-]+\.(?:png|webp|jpg|jpeg|gif)", value, re.IGNORECASE) and ".." not in value:
        return {"kind": "bundled_gift", "asset": value}
    try:
        url = urlsplit(value)
        path = None
        if url.username or url.password or url.fragment or url.port:
            raise LegacyInvalid()
        if url.scheme == "gs" and url.netloc == bucket:
            path = unquote(url.path.lstrip("/"), errors="strict")
        elif url.scheme == "https" and url.netloc == "firebasestorage.googleapis.com":
            prefix = "/v0/b/" + bucket + "/o/"
            if url.path.startswith(prefix):
                path = unquote(url.path[len(prefix):], errors="strict")
        elif url.scheme == "https" and url.netloc == "storage.googleapis.com":
            prefix = "/" + bucket + "/"
            if url.path.startswith(prefix):
                path = unquote(url.path[len(prefix):], errors="strict")
        if path is None or not path or len(path.encode()) > 1024 or any(part in {".", "..", ""} for part in path.split("/")):
            return {"kind": "unavailable", "reason": "unmapped_external_media"}
        return {"kind": "legacy_storage", "status": "quarantined",
            "reference": codec.seal("media", {**binding, "bucket": bucket, "path": path, "exp": now + 300})}
    except (ValueError, UnicodeError, LegacyInvalid):
        return {"kind": "unavailable", "reason": "unmapped_external_media"}


def message_view(payload, message_id, *, uid, group, bucket, codec, binding, now):
    fields = payload["fields"]; unavailable = []
    def optional(name, maximum=191):
        try:
            return string_field(fields, name, maximum)
        except LegacyInvalid:
            unavailable.append(name); return None
    # Deleted-for flags affect visibility, never authorization. A malformed
    # flag fails closed instead of revealing a possibly hidden message.
    if string_field(fields, "deleteFor") == uid or uid in uid_list(fields, "deletedFor"):
        return None
    _, sent_at, basis = message_time(payload, "time" if group else "ts")
    view = {"id": message_id, "sentAt": sent_at, "timestampBasis": basis,
        "senderUid": optional("sender" if group else "sendByID"),
        "senderName": optional("name" if group else "sendBy"),
        "text": optional("message", MAX_DOCUMENT_BYTES), "unavailableFields": unavailable}
    read = field(fields, "isRead", "booleanValue")
    if read is not None and type(read) is not bool:
        raise LegacyInvalid()
    view["legacyIsRead"] = read
    notice = optional("giftNoticeName", 1000)
    if notice is not None:
        view["giftNoticeName"] = notice
    image = optional("image", 4096)
    if image is not None:
        view["image"] = media_reference(image, bucket=bucket, codec=codec, binding=binding, now=now)
        if not group:
            view["giftName"] = optional("name", 1000)
    quote = field(fields, "replyMessage", "mapValue")
    if quote is not None:
        if not isinstance(quote, dict) or set(quote) - {"fields"} or not isinstance(quote.get("fields", {}), dict):
            raise LegacyInvalid()
        quote_fields = quote.get("fields", {})
        view["quote"] = {name: string_field(quote_fields, name, MAX_DOCUMENT_BYTES if name == "message" else 191)
            for name in ["message", "name", "sendBy", "sender", "sendByID"] if name in quote_fields}
        # Historical quotes have no message ID. Never manufacture a link.
        view["quote"]["messageId"] = None
    shared = field(fields, "sharedContent", "mapValue")
    if shared is not None:
        if not isinstance(shared, dict) or set(shared) - {"fields"} or not isinstance(shared.get("fields", {}), dict):
            raise LegacyInvalid()
        source = shared.get("fields", {})
        view["sharedContent"] = {name: string_field(source, name, MAX_DOCUMENT_BYTES if name == "text" else 1000)
            for name in ["kind", "postId", "commentId", "text", "authorName", "group"] if name in source}
        image_url = string_field(source, "imageUrl", 4096)
        if image_url is not None:
            view["sharedContent"]["image"] = media_reference(image_url, bucket=bucket, codec=codec, binding=binding, now=now)
        view["sharedContent"]["linkAvailable"] = False  # Wall access is outside this service.
    return view


def profile_view(fields):
    result = {}
    group_field = "группа" if "группа" in fields else "group"
    for source, target in [("fullName", "name"), ("city", "city"), (group_field, "group")]:
        try:
            value = string_field(fields, source, 1000)
        except LegacyInvalid:
            value = None
        result[target] = value
    age = fields.get("age")
    result["age"] = None
    if isinstance(age, dict) and len(age) == 1:
        raw_age = age.get("integerValue", age.get("stringValue"))
        if isinstance(raw_age, str) and re.fullmatch(r"[0-9]{1,3}", raw_age) and 0 <= int(raw_age) <= 150:
            result["age"] = int(raw_age)
    result["deleted"] = (field(fields, "deleted", "booleanValue") is True
        or string_field(fields, "status") == "deleted"
        or string_field(fields, "registrationStatus") == "deleted")
    return result
