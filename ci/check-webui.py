#!/usr/bin/env python3
"""Static checks of the web interface (lint stage of ci/run-local.sh).

- rpcd ACL: valid JSON, limited to the rut360gw object, methods present in the rpcd module.
- Page (index.html + app.js + app.css):
  * compatible with the Content-Security-Policy sent by RutOS uhttpd
    (script-src/style-src 'self' + a few Teltonika hashes): NO inline <script> or <style>,
    no style="..." attribute nor on...="..." handler; everything goes in app.js / app.css;
  * no external resource (the router may have no Internet access);
  * no innerHTML (any text coming from the router goes through textContent);
  * called methods are a subset of the ACL methods.
"""
import json
import re
import sys

WWW = "package/rut360gw/files/www/rut360gw/"
ACL = "package/rut360gw/files/usr/share/rpcd/acl.d/rut360gw.json"
PLUGIN = "package/rut360gw/files/usr/libexec/rpcd/rut360gw"
err = []

acl = json.load(open(ACL, encoding="utf-8"))["rut360gw"]
allowed = set()
for mode in ("read", "write"):
    objs = acl.get(mode, {}).get("ubus", {})
    if set(objs) != {"rut360gw"}:
        err.append(f"ACL {mode}: ubus objects other than rut360gw: {sorted(objs)}")
    allowed |= set(objs.get("rut360gw", []))

html = open(WWW + "index.html", encoding="utf-8").read()
js = open(WWW + "app.js", encoding="utf-8").read()
css = open(WWW + "app.css", encoding="utf-8").read()

# RutOS CSP: nothing inline
if re.search(r"<style", html, re.I):
    err.append("index.html: inline <style> blocked by the RutOS CSP (use app.css)")
for m in re.finditer(r"<script\b([^>]*)>(.*?)</script>", html, re.I | re.S):
    if "src=" not in m.group(1) or m.group(2).strip():
        err.append("index.html: inline <script> blocked by the RutOS CSP (use app.js)")
if re.search(r"\sstyle\s*=", html, re.I):
    err.append("index.html: style=\"...\" attribute blocked by the RutOS CSP (use a class)")
if re.search(r"\son[a-z]+\s*=", html, re.I):
    err.append("index.html: on...=\"...\" handler blocked by the RutOS CSP (use addEventListener)")
if re.search(r"setAttribute\(\s*['\"](style|on[a-z]+)['\"]|\beval\(|new Function\(", js):
    err.append("app.js: style/handler set as attribute, or eval: blocked by the CSP")
for f in ("app.css", "app.js"):
    if not re.search(rf'(href|src)="{re.escape(f)}"', html):
        err.append(f"index.html: {f} not loaded")

everything = html + js + css
if re.search(r'(src|href)\s*=\s*["\']?(https?:)?//', everything, re.I) or re.search(r"@import|url\(\s*['\"]?https?:|fetch\(\s*['\"]https?:", everything):
    err.append("page: external resource forbidden")
if re.search(r"\.(innerHTML|outerHTML)\s*=|insertAdjacentHTML|document\.write", js):
    err.append("app.js: HTML injection forbidden (use textContent)")
called = set(re.findall(r'\bapi\(\s*["\'](\w+)["\']', js))
if not called or called - allowed:
    err.append(f"app.js: methods outside the ACL {sorted(called - allowed)} (called: {sorted(called)})")

plugin = open(PLUGIN, encoding="utf-8").read()
listed = set(re.findall(r'"(\w+)"\s*:\s*\{', plugin.split("list)", 1)[-1].split(";;", 1)[0]))
if allowed - listed:
    err.append(f"ACL: methods missing from the plugin {sorted(allowed - listed)}")

for e in err:
    print("ERROR", e)
print(f"webui: ACL {len(allowed)} methods, page {len(called)} methods, RutOS CSP, {len(err)} error(s)")
sys.exit(1 if err else 0)
