#!/usr/bin/env python3
"""Proves authentik works, from inside the server container, where Python and
PyJWT already are. It's safe to run again: it reuses what it made last time.

  ssh ... podman exec -i -e AK_TOKEN -e AK_PASSWORD authentik-server python3 - < check.py

Logs in as akadmin with the bootstrap token and with the password through the
default authentication flow, makes an OIDC provider and gets a signed token
from it, makes a SAML provider and reads its metadata, and checks that a user
without rights is refused.
"""
import http.cookiejar
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

import jwt

BASE = os.environ.get("AK_URL", "http://127.0.0.1:9000")
TOKEN = os.environ["AK_TOKEN"]
PASSWORD = os.environ["AK_PASSWORD"]
TIMEOUT = int(os.environ.get("AK_TIMEOUT", "600"))


def call(path, method=None, body=None, token=TOKEN, form=None, opener=urllib.request.urlopen, headers=None):
    h = dict(headers or {})
    data = None
    if token:
        h["Authorization"] = f"Bearer {token}"
    if body is not None:
        data, h["Content-Type"] = json.dumps(body).encode(), "application/json"
    if form is not None:
        data, h["Content-Type"] = urllib.parse.urlencode(form).encode(), "application/x-www-form-urlencoded"
    req = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with opener(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def ok(path, **kw):
    status, text = call(path, **kw)
    if not 200 <= status < 300:
        sys.exit(f"{path}: {status} {text[:500]}")
    return json.loads(text) if text else None


def ensure(path, field, value, body):
    """The object at path whose field is value, made from body if it's missing."""
    q = urllib.parse.urlencode({field: value})
    found = ok(f"{path}?{q}")["results"]
    return found[0] if found else ok(path, method="POST", body=body)


# The worker applies the bootstrap and default-flow blueprints and makes the
# self-signed certificate after the server starts answering, so a fresh install
# needs a while before all of it is there.
NEEDED = [
    "/api/v3/flows/instances/?slug=default-authentication-flow",
    "/api/v3/flows/instances/?slug=default-provider-authorization-implicit-consent",
    "/api/v3/flows/instances/?slug=default-provider-invalidation-flow",
    "/api/v3/crypto/certificatekeypairs/?has_key=true&name=authentik+Self-signed+Certificate",
]
deadline = time.time() + TIMEOUT
while True:
    try:
        status, text = call("/api/v3/core/users/me/")
        if status == 200 and all(json.loads(call(p)[1])["results"] for p in NEEDED):
            break
    except (OSError, ValueError, KeyError):
        status, text = "no answer", ""
    if time.time() > deadline:
        sys.exit(f"authentik not ready in {TIMEOUT}s: {status} {text[:300]}")
    time.sleep(5)

me = json.loads(text)["user"]
assert me["username"] == "akadmin" and me["is_superuser"], me
print("token: logged in as akadmin")

status, _ = call("/api/v3/core/users/me/", token="wrong-token-wrong-token")
assert status == 403, f"wrong token answered {status}"
print("token: a wrong one is refused")

# Password login through the flow executor, the same API the web page uses.
jar = http.cookiejar.CookieJar()
web = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar)).open
flow = "/api/v3/flows/executor/default-authentication-flow/?query="


def step(body=None):
    status, text = call(flow, method="POST" if body else "GET", body=body, token=None, opener=web)
    assert status == 200, f"flow: {status} {text[:300]}"
    return json.loads(text)


c = step()
for _ in range(6):
    comp = c.get("component")
    if comp == "ak-stage-identification":
        c = step({"uid_field": "akadmin", **({"password": PASSWORD} if c.get("password_fields") else {})})
    elif comp == "ak-stage-password":
        c = step({"password": PASSWORD})
    elif comp == "xak-flow-redirect":
        break
    else:
        sys.exit(f"flow stopped at {comp}: {json.dumps(c)[:400]}")
else:
    sys.exit("flow didn't finish")
who = ok("/api/v3/core/users/me/", token=None, opener=web)["user"]["username"]
assert who == "akadmin", who
print("password: signed in through default-authentication-flow")

auth_flow = ok("/api/v3/flows/instances/?slug=default-provider-authorization-implicit-consent")["results"][0]["pk"]
end_flow = ok("/api/v3/flows/instances/?slug=default-provider-invalidation-flow")["results"][0]["pk"]
key = ok("/api/v3/crypto/certificatekeypairs/?has_key=true&name=authentik+Self-signed+Certificate")["results"][0]["pk"]
scopes = [m["pk"] for m in ok("/api/v3/propertymappings/provider/scope/?page_size=50")["results"]
          if m["scope_name"] in ("openid", "profile", "email")]

# OIDC: a provider and application, discovery, and a token signed by the key
# its JWKS publishes. Client credentials, since there's no browser here.
oidc = ensure("/api/v3/providers/oauth2/", "name", "conn3x-check-oidc", {
    "name": "conn3x-check-oidc", "client_type": "confidential", "authorization_flow": auth_flow,
    "invalidation_flow": end_flow, "signing_key": key, "property_mappings": scopes,
    "grant_types": ["authorization_code", "client_credentials"],
    "redirect_uris": [{"matching_mode": "strict", "url": "https://app.example.com/callback"}],
})
ensure("/api/v3/core/applications/", "slug", "conn3x-check-oidc", {
    "name": "conn3x-check-oidc", "slug": "conn3x-check-oidc", "provider": oidc["pk"]})
disc = ok("/application/o/conn3x-check-oidc/.well-known/openid-configuration", token=None)
assert disc["issuer"].endswith("/application/o/conn3x-check-oidc/"), disc["issuer"]
print("oidc: discovery document served, issuer", disc["issuer"])

svc = ensure("/api/v3/core/users/", "username", "conn3x-check-svc", {
    "username": "conn3x-check-svc", "name": "conn3x check", "path": "conn3x-check", "type": "service_account"})
ensure("/api/v3/core/tokens/", "identifier", "conn3x-check-svc", {
    "identifier": "conn3x-check-svc", "user": svc["pk"], "intent": "app_password", "expiring": False})
svc_pw = ok("/api/v3/core/tokens/conn3x-check-svc/view_key/")["key"]
tok = ok("/application/o/token/", method="POST", token=None, form={
    "grant_type": "client_credentials", "client_id": oidc["client_id"], "client_secret": oidc["client_secret"],
    "username": "conn3x-check-svc", "password": svc_pw, "scope": "openid"})["access_token"]
path = urllib.parse.urlparse(disc["jwks_uri"]).path
jwks = ok(path, token=None)
kid = jwt.get_unverified_header(tok)["kid"]
pub = next(jwt.PyJWK(k) for k in jwks["keys"] if k["kid"] == kid)
claims = jwt.decode(tok, pub.key, algorithms=[jwt.get_unverified_header(tok)["alg"]],
                    audience=oidc["client_id"], issuer=disc["issuer"])
assert claims.get("sub"), claims
print("oidc: client-credentials token issued and verified against JWKS")

status, _ = call("/application/o/token/", method="POST", token=None, form={
    "grant_type": "client_credentials", "client_id": oidc["client_id"], "client_secret": oidc["client_secret"],
    "username": "conn3x-check-svc", "password": "wrong", "scope": "openid"})
assert status in (400, 401), f"wrong service password answered {status}"
print("oidc: a wrong service password gets no token")

# SAML: a provider and application, and IdP metadata for it.
saml = ensure("/api/v3/providers/saml/", "name", "conn3x-check-saml", {
    "name": "conn3x-check-saml", "authorization_flow": auth_flow, "invalidation_flow": end_flow,
    "acs_url": "https://app.example.com/saml/acs", "signing_kp": key, "sign_assertion": True})
ensure("/api/v3/core/applications/", "slug", "conn3x-check-saml", {
    "name": "conn3x-check-saml", "slug": "conn3x-check-saml", "provider": saml["pk"]})
status, xml = call(f"/api/v3/providers/saml/{saml['pk']}/metadata/?download", headers={"Accept": "application/xml"})
assert status == 200, f"saml metadata: {status} {xml[:300]}"
if xml.lstrip().startswith("{"):
    xml = json.loads(xml)["metadata"]
root = ET.fromstring(xml)
assert root.tag.endswith("EntityDescriptor") and any(e.tag.endswith("X509Certificate") for e in root.iter()), root.tag
print("saml: provider made, metadata has an EntityDescriptor and signing certificate")

# Authorization: an ordinary user's token can't read other users or make providers.
user = ensure("/api/v3/core/users/", "username", "conn3x-check-user", {
    "username": "conn3x-check-user", "name": "conn3x check user", "path": "conn3x-check", "type": "internal"})
ensure("/api/v3/core/tokens/", "identifier", "conn3x-check-user", {
    "identifier": "conn3x-check-user", "user": user["pk"], "intent": "api", "expiring": False})
utok = ok("/api/v3/core/tokens/conn3x-check-user/view_key/")["key"]
assert ok("/api/v3/core/users/me/", token=utok)["user"]["username"] == "conn3x-check-user"
status, _ = call("/api/v3/providers/saml/", method="POST", token=utok, body={
    "name": "nope", "authorization_flow": auth_flow, "invalidation_flow": end_flow,
    "acs_url": "https://example.com/acs"})
assert status == 403, f"ordinary user made a provider: {status}"
status, _ = call("/api/v3/core/users/", token=utok)
assert status == 403, f"ordinary user listed users: {status}"
print("rbac: an ordinary user can't make providers or list users")
print("All checks passed.")
