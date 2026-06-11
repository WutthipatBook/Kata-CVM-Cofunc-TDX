#!/bin/python
from base64 import b64encode
from urllib.error import HTTPError
from urllib.request import Request, urlopen

credentials = b64encode(b"admin:password").decode("ascii")
req = Request(
    "http://localhost:5984/wage-statistics",
    data=b"",
    headers={"Authorization": f"Basic {credentials}"},
    method="PUT",
)
try:
    with urlopen(req) as resp:
        resp.read()
except HTTPError as exc:
    if exc.code != 412:
        raise
