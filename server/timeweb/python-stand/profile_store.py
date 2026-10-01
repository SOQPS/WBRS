"""Narrow, read-only MySQL access for an authenticated account's own profile.

This module never accepts SQL, a table name, or a target UID from an HTTP
request. The caller supplies only the UID returned by Firebase verification.
"""

import ipaddress
import os
import ssl
from urllib.parse import parse_qs, unquote, urlsplit


class DatabaseUnavailable(Exception):
    """Configuration or connection is unavailable; never expose its detail."""


class AccountUnavailable(Exception):
    """The verified UID has no active local account/profile."""


PROFILE_QUERY = """
SELECT a.disabled, a.lifecycle, p.full_name, p.country, p.city,
       p.primary_group
FROM clrs_staging.accounts AS a
LEFT JOIN clrs_staging.profiles AS p ON p.uid = a.uid
WHERE a.uid = %s
LIMIT 1
"""

BUNDLED_CA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "timeweb-ca.pem")
PROBE_QUERY = "SELECT 1"


def _database_config(env):
    raw = env.get("CLRS_DB_URL", "")
    ca_file = env.get("CLRS_DB_CA_FILE", BUNDLED_CA_FILE)
    if (not isinstance(raw, str) or not raw or
            not isinstance(ca_file, str) or not ca_file or
            not os.path.isabs(ca_file) or not os.path.isfile(ca_file)):
        raise DatabaseUnavailable()
    try:
        url = urlsplit(raw)
        query = parse_qs(url.query, strict_parsing=True)
        host = url.hostname
        port = url.port or 3306
        username = unquote(url.username or "")
        password = unquote(url.password or "")
        database = unquote(url.path)
        if (
            url.scheme != "mysql"
            or not host
            or not username
            or not password
            or not 1 <= port <= 65535
            or database != "/clrs_staging"
            or url.fragment
            or query != {"sslmode": ["verify-full"]}
        ):
            raise ValueError("invalid DB URL")
        # Verify a DNS name against the certificate, never accept an IP or
        # a local host as a shortcut around certificate identity checking.
        if host.lower() == "localhost":
            raise ValueError("local host")
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass
        else:
            raise ValueError("IP host")
        context = ssl.create_default_context(cafile=ca_file)
        context.check_hostname = True
        context.verify_mode = ssl.CERT_REQUIRED
        return {
            "host": host,
            "port": port,
            "user": username,
            "password": password,
            "database": database[1:],
            "ssl": context,
            "connect_timeout": 3,
            "read_timeout": 3,
            "write_timeout": 3,
            "autocommit": True,
        }
    except (TypeError, ValueError, OSError, ssl.SSLError):
        raise DatabaseUnavailable() from None


def probe_database(*, env=None, connect=None):
    """Check only TLS/authentication and SELECT 1; never read user tables."""
    if env is None:
        env = os.environ
    try:
        config = _database_config(env)
    except DatabaseUnavailable:
        return False
    if connect is None:
        try:
            import pymysql
        except ImportError:
            return False
        connect = pymysql.connect
    connection = None
    try:
        connection = connect(**config)
        with connection.cursor() as cursor:
            cursor.execute(PROBE_QUERY)
            return cursor.fetchone() == (1,)
    except Exception:
        return False
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass


def read_own_profile(uid, *, env=None, connect=None):
    """Return whitelisted own-profile fields or fail closed.

    The DB role must have SELECT only on accounts and profiles in
    clrs_staging. No table holding credentials or token material is used.
    """
    if not isinstance(uid, str) or not uid or len(uid) > 191:
        raise AccountUnavailable()
    if env is None:
        env = os.environ
    config = _database_config(env)
    if connect is None:
        try:
            import pymysql
        except ImportError:
            raise DatabaseUnavailable() from None
        connect = pymysql.connect
    try:
        connection = connect(**config)
        try:
            with connection.cursor() as cursor:
                cursor.execute(PROFILE_QUERY, (uid,))
                row = cursor.fetchone()
        finally:
            connection.close()
    except Exception:
        raise DatabaseUnavailable() from None
    if row is None or row[0] != 0 or row[1] != "active" or row[2] is None:
        raise AccountUnavailable()
    return {
        "uid": uid,
        "fullName": row[2],
        "country": row[3],
        "city": row[4],
        "group": row[5],
    }
