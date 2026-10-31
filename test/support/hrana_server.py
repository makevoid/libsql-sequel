"""Run the official Hrana v3 fixture with Rust-compatible base64 handling.

The upstream Python fixture requires padded input and returns padded output.
libsql-hrana uses STANDARD_NO_PAD. Normalize only the blob envelope; all SQL,
stream, cursor, and transaction handling remains upstream code.
"""
import asyncio
import os
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "tmp/upstream/libsql-client-ts/testing/hrana-test-server"))
os.environ["ENCODING"] = "json"
os.environ.setdefault("LOG_LEVEL", "WARNING")
import server_v3 as server

decode_value = server.value_to_sqlite
encode_value = server.value_from_sqlite


def value_to_sqlite(value):
    if value["type"] == "blob":
        value = dict(value)
        value["base64"] += "=" * (-len(value["base64"]) % 4)
    return decode_value(value)


def value_from_sqlite(value):
    encoded = encode_value(value)
    if encoded["type"] == "blob":
        encoded["base64"] = encoded["base64"].rstrip("=")
    return encoded


server.value_to_sqlite = value_to_sqlite
server.value_from_sqlite = value_from_sqlite
sys.exit(asyncio.run(server.main(sys.argv[1:])))
