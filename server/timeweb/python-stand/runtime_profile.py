"""Own current profile reads and edits under native SQL authority only.

The mutation store revalidates the access token in the same transaction. This
module does not modify the retained Firebase archive, onboarding completion,
roles, balance, media or geography. Updated-at CAS prevents one device from
silently overwriting another device's edit; an operation receipt handles an
uncertain response without a second mutation.
"""
from __future__ import annotations

from datetime import datetime
import re

from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable


class ProfileEditInvalid(ValueError):
    pass


PROFILE_EDIT_OPERATION = "profile.edit.v1"
_STAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z")
_FIELDS = {
    "fullName": "full_name", "age": "age", "rost": "height_cm",
    "about": "about_text", "hobbi": "interests_text", "deti": "has_children",
    "pol": "gender", "relationStatus": "relationship_status",
}
_SELECT = """SELECT full_name, age, height_cm, about_text, interests_text,
 has_children, gender, relationship_status, profile_details_saved,
 registration_complete, DATE_FORMAT(updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')
 FROM clrs_staging.profiles WHERE uid = %s LIMIT 1 FOR UPDATE"""

# Current projection maps the exact legacy `группа` to primary_group. Keep the
# accepted cases local: importing a snapshot reader would mix authorities.
_CURRENT_GROUPS = frozenset({
    "коричнево-красная", "коричнево-синяя", "коричневая", "коричнево-белая",
    "бело-коричневая", "бело-красная", "бело-синяя", "белая", "сине-белая",
    "красно-синяя", "красно-белая", "красная", "красно-коричневая", "синяя",
    "сине-коричневая", "сине-красная",
})
_FULL_FIELDS = {
    **_FIELDS, "country": "country", "countryCode": "country_code",
    "region": "region", "city": "city", "languageCode": "language_code",
    "primaryGroup": "primary_group", "secondaryGroup": "secondary_group",
    "profileDetailsSaved": "profile_details_saved",
    "isRegistrationEnd": "registration_complete",
}
_FULL_TEXT_LIMITS = {
    "fullName": 1000, "about": 4096, "hobbi": 4096, "pol": 191,
    "relationStatus": 191, "country": 191, "countryCode": 191,
    "region": 191, "city": 191, "languageCode": 191,
    "primaryGroup": 191, "secondaryGroup": 191,
}


def _full_select():
    # TEXT/LONGTEXT values are bounded before crossing the SQL connector. The
    # extra validity bit distinguishes a real SQL NULL from oversized content.
    columns = []
    valid = []
    for name, column in _FULL_FIELDS.items():
        if name in _FULL_TEXT_LIMITS:
            maximum = _FULL_TEXT_LIMITS[name]
            predicate = (f"({column} IS NULL OR (CHAR_LENGTH({column}) <= {maximum}"
                         f" AND OCTET_LENGTH({column}) <= {maximum * 4}))")
            columns.append(f"CASE WHEN {predicate} THEN {column} ELSE NULL END")
            valid.append(predicate)
        else:
            columns.append(column)
    columns.append("DATE_FORMAT(updated_at, '%%Y-%%m-%%dT%%H:%%i:%%s.%%fZ')")
    columns.append("(" + " AND ".join(valid) + ")")
    return ("SELECT " + ",\n ".join(columns) +
            " FROM clrs_staging.profiles WHERE uid = %s AND CAST(uid AS BINARY) = CAST(%s AS BINARY)"
            " LIMIT 1 FOR SHARE")


_FULL_SELECT = _full_select()


def _full_profile(row):
    if (not isinstance(row, (tuple, list)) or len(row) != len(_FULL_FIELDS) + 2
            or type(row[-1]) is not int or row[-1] != 1):
        raise RuntimeUnavailable()
    result = dict(zip(_FULL_FIELDS, row))
    for name, maximum in _FULL_TEXT_LIMITS.items():
        value = result[name]
        if value is None:
            continue
        if (not isinstance(value, str) or len(value) > maximum
                or any((ord(c) < 32 and c not in "\n\r\t") or ord(c) == 127
                       or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
            raise RuntimeUnavailable()
        try:
            if len(value.encode("utf-8")) > maximum * 4:
                raise RuntimeUnavailable()
        except UnicodeError:
            raise RuntimeUnavailable() from None
    for name, maximum in (("age", 130), ("rost", 300)):
        value = result[name]
        if value is not None and (type(value) is not int or not 0 <= value <= maximum):
            raise RuntimeUnavailable()
    for name in ("deti", "profileDetailsSaved", "isRegistrationEnd"):
        value = result[name]
        if value is not None and (type(value) is not int or value not in (0, 1)):
            raise RuntimeUnavailable()
        result[name] = None if value is None else bool(value)
    try:
        result["updatedAt"] = _stamp(row[-2])
    except ProfileEditInvalid:
        raise RuntimeUnavailable() from None
    return result


def _full_onboarding(profile):
    if profile is None:
        return "registration"
    primary = profile["primaryGroup"]
    if (profile["isRegistrationEnd"] is True
            or (primary is not None and primary.strip().lower() in _CURRENT_GROUPS)):
        return "search"
    if (profile["profileDetailsSaved"] is True
            or (profile["fullName"] is not None and profile["fullName"].strip()
                and profile["age"] is not None
                and all(profile[name] is not None and profile[name] != ""
                        for name in ("pol", "about", "hobbi")))):
        return "test"
    return "registration"


def _stamp(value):
    if not isinstance(value, str) or _STAMP.fullmatch(value) is None:
        raise ProfileEditInvalid()
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError:
        raise ProfileEditInvalid() from None
    return value


def _text(value, minimum, maximum, *, multiline):
    if not isinstance(value, str):
        raise ProfileEditInvalid()
    value = value.strip()
    if (not minimum <= len(value) <= maximum
            or any((ord(c) < 32 and (not multiline or c not in "\n\r\t"))
                   or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise ProfileEditInvalid()
    return value


def validate_profile_edit(payload):
    if (type(payload) is not dict or set(payload) != {"expectedUpdatedAt", "changes"}
            or type(payload["changes"]) is not dict
            or not payload["changes"] or set(payload["changes"]) - _FIELDS.keys()):
        raise ProfileEditInvalid()
    expected = _stamp(payload["expectedUpdatedAt"])
    changes = {}
    for name in sorted(payload["changes"]):
        value = payload["changes"][name]
        if name == "deti":
            if type(value) is not bool:
                raise ProfileEditInvalid()
        elif name in {"age", "rost"}:
            lower, upper = (18, 100) if name == "age" else (1, 300)
            if type(value) is not int or not lower <= value <= upper:
                raise ProfileEditInvalid()
        else:
            minimum, maximum = (20, 4096) if name in {"about", "hobbi"} else (
                (1, 1000) if name == "fullName" else (1, 191))
            value = _text(value, minimum, maximum, multiline=name in {"about", "hobbi"})
        changes[name] = value
    return {"expectedUpdatedAt": expected, "changes": changes}


def _profile(row):
    if not isinstance(row, (tuple, list)) or len(row) != 11:
        raise ProfileEditInvalid()
    result = dict(zip(_FIELDS, row[:8]))
    # Source absence is retained. bool conversion must not interpret a malformed
    # string or an unknown status as completed registration.
    for index in (5, 8, 9):
        if row[index] is not None and (type(row[index]) is not int or row[index] not in (0, 1)):
            raise ProfileEditInvalid()
    result["deti"] = None if row[5] is None else bool(row[5])
    result["profileDetailsSaved"] = None if row[8] is None else bool(row[8])
    result["isRegistrationEnd"] = None if row[9] is None else bool(row[9])
    result["updatedAt"] = _stamp(row[10])
    return result


class RuntimeProfileService:
    def __init__(self, store):
        self._store = store

    def read_full(self, identity, *, access_token):
        def action(cursor, execute, uid):
            execute(_FULL_SELECT, (uid, uid))
            row = cursor.fetchone()
            profile = None if row is None else _full_profile(row)
            return {"uid": uid, "profileExists": row is not None,
                    "profile": profile, "onboarding": _full_onboarding(profile),
                    "profileAuthority": "canonical-current-v1", "mediaReady": False}
        try:
            return self._store.read_authenticated(identity, action, access_token=access_token)
        except RuntimeInvalidRequest:
            # This GET accepts no JSON input. A store serialization/budget error
            # is unavailable server content rather than a malformed request.
            raise RuntimeUnavailable() from None

    def read_for_edit(self, identity, *, access_token):
        def action(cursor, execute, uid):
            # SHARE locks are compatible with the primitive's READ ONLY
            # transaction; the edit route obtains its own exclusive lock.
            execute(_SELECT.replace("FOR UPDATE", "FOR SHARE"), (uid,))
            row = cursor.fetchone()
            return {"uid": uid, "profile": None if row is None else _profile(row),
                    "profileExists": row is not None,
                    "profileAuthority": "canonical-current-v1",
                    "editableFields": list(_FIELDS)}
        return self._store.read_authenticated(identity, action, access_token=access_token)

    def edit(self, identity, operation_id, payload, *, access_token):
        checked = validate_profile_edit(payload)
        request = {"expectedUpdatedAt": payload["expectedUpdatedAt"],
                   "changes": dict(payload["changes"])}

        def action(cursor, execute, uid):
            execute(_SELECT, (uid,))
            before = cursor.fetchone()
            if before is None:
                return 404, {"error": "profile_not_found"}, None
            before_view = _profile(before)
            if before_view["updatedAt"] != checked["expectedUpdatedAt"]:
                return 409, {"error": "profile_changed", "updatedAt": before_view["updatedAt"]}, None
            # A true no-op keeps the revision rather than causing spurious CAS
            # failures on the second device. The receipt still completes.
            changed = {name: value for name, value in checked["changes"].items()
                       if before_view[name] != value}
            if changed:
                names = sorted(changed)
                assignments = ", ".join(_FIELDS[name] + " = %s" for name in names)
                execute("UPDATE clrs_staging.profiles SET " + assignments +
                        ", updated_at = GREATEST(UTC_TIMESTAMP(6), updated_at + INTERVAL 1 MICROSECOND)"
                        " WHERE uid = %s", tuple(changed[name] for name in names) + (uid,))
                if cursor.rowcount != 1:
                    raise ProfileEditInvalid()
            execute(_SELECT, (uid,))
            after = _profile(cursor.fetchone())
            if (any(after[name] != value for name, value in checked["changes"].items())
                    or (changed and after["updatedAt"] <= before_view["updatedAt"])
                    or after["profileDetailsSaved"] != before_view["profileDetailsSaved"]
                    or after["isRegistrationEnd"] != before_view["isRegistrationEnd"]):
                raise ProfileEditInvalid()
            return 200, {"uid": uid, "profile": after, "operationId": operation_id,
                         "profileAuthority": "canonical-current-v1"}, None

        return self._store.mutate(identity, PROFILE_EDIT_OPERATION, operation_id,
                                  request, action, access_token=access_token)

    def reconcile(self, identity, operation_id, payload, *, access_token):
        validate_profile_edit(payload)
        request = {"expectedUpdatedAt": payload["expectedUpdatedAt"],
                   "changes": dict(payload["changes"])}
        return self._store.lookup(identity, PROFILE_EDIT_OPERATION, operation_id,
                                  payload=request, access_token=access_token)
