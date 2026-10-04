#!/usr/bin/env python3
"""A stand-in for `gh` that keeps a project board in a JSON state file.

FAKE_GH_STATE: the state file. FAKE_GH_LOG: every invocation is appended as one JSON line.
State keys: project, fields, items, issues, labels, fail (map "verb noun" -> times to fail
before succeeding), missing_scope (bool).
"""
import json
import os
import sys

STATE, LOG = os.environ["FAKE_GH_STATE"], os.environ["FAKE_GH_LOG"]
args = sys.argv[1:]
with open(LOG, "a") as fh:
    fh.write(json.dumps(args) + "\n")
with open(STATE) as fh:
    s = json.load(fh)


def save():
    with open(STATE, "w") as fh:
        json.dump(s, fh)


def opt(name):
    return args[args.index(name) + 1] if name in args else None


def out(obj):
    print(json.dumps(obj))
    sys.exit(0)


if s.get("missing_scope") and args[0] == "project":
    print("error: your authentication token is missing required scopes [read:project]",
          file=sys.stderr)
    sys.exit(1)

verb = " ".join(args[:2])
if s.get("fail", {}).get(verb, 0) > 0:
    s["fail"][verb] -= 1
    save()
    print(f"GraphQL: transient failure ({verb})", file=sys.stderr)
    sys.exit(1)

if verb == "api graphql":
    vals, ids = {}, []
    for i, a in enumerate(args):
        if a == "-f":
            k, _, v = args[i + 1].partition("=")
            if k == "f[]":
                ids.append(v)
            else:
                vals[k] = v
    q, views = vals["query"], s.setdefault("views", [])
    if "createProjectV2View" in q:
        v = {"id": f"V_{len(views) + 1}", "name": vals["n"], "layout": vals["l"],
             "filter": None, "fieldIds": ids}
        views.append(v)
        save()
        out({"data": {"createProjectV2View": {"projectV2View": {"id": v["id"]}}}})
    if "updateProjectV2View" in q:
        next(v for v in views if v["id"] == vals["v"])["filter"] = vals["f"]
        save()
        out({"data": {"updateProjectV2View": {"projectV2View": {"id": vals["v"]}}}})
    if "views(" in q:
        out({"data": {"node": {"views": {"nodes": [
            {k: v[k] for k in ("id", "name", "layout", "filter")} for v in views]}}}})
if verb == "project view":
    out({"id": "PVT_1", "title": s["project"], "url": "https://github.com/orgs/o/projects/1",
         "items": {"totalCount": len(s["items"])}})
if verb == "project field-list":
    out({"fields": s["fields"], "totalCount": len(s["fields"])})
if verb == "project item-list":
    out({"items": s["items"], "totalCount": len(s["items"])})
if verb == "project field-create":
    name = opt("--name")
    if name.lower() in ("type", "status") or any(f["name"] == name for f in s["fields"]):
        print("GraphQL: Name cannot have a reserved value, Name has already been taken",
              file=sys.stderr)
        sys.exit(1)
    f = {"id": f"F_{name}", "name": name}
    if opt("--data-type") == "SINGLE_SELECT":
        f["type"] = "ProjectV2SingleSelectField"
        f["options"] = [{"id": f"O_{name}_{o}", "name": o}
                        for o in opt("--single-select-options").split(",")]
    else:
        f["type"] = "ProjectV2Field"
    s["fields"].append(f)
    save()
    out(f)
if verb in ("project item-add", "project item-create"):
    if verb == "project item-add":
        url = opt("--url")
        for it in s["items"]:
            if it["content"].get("url") == url:
                out({"id": it["id"]})
        known = next((i for i in s["issues"] if i["url"] == url), None)
        typ = "PullRequest" if "/pull/" in url else "Issue"
        num = int(url.rsplit("/", 1)[1])
        title = known["title"] if known else f"PR {num}"
        content = {"type": typ, "url": url, "number": num, "title": title}
    else:
        title = opt("--title")
        content = {"type": "DraftIssue", "title": title, "body": opt("--body")}
    it = {"id": f"I_{len(s['items']) + 1}", "title": title, "content": content}
    s["items"].append(it)
    save()
    out({"id": it["id"]})
if verb == "project item-edit":
    item = next(i for i in s["items"] if i["id"] == opt("--id"))
    field = next(f for f in s["fields"] if f["id"] == opt("--field-id"))
    key = field["name"][:1].lower() + field["name"][1:]
    if opt("--text") is not None:
        item[key] = opt("--text")
    else:
        item[key] = next(o["name"] for o in field["options"]
                         if o["id"] == opt("--single-select-option-id"))
    save()
    sys.exit(0)
if verb == "issue list":
    out([{"title": i["title"], "url": i["url"], "number": i["number"]} for i in s["issues"]])
if verb == "issue create":
    num = 100 + len(s["issues"])
    url = f"https://github.com/o/r/issues/{num}"
    s["issues"].append({"title": opt("--title"), "url": url, "number": num,
                        "labels": [args[i + 1] for i, a in enumerate(args) if a == "--label"]})
    save()
    print("Creating issue in o/r\n\n" + url)
    sys.exit(0)
if verb == "label list":
    out([{"name": n} for n in s["labels"]])
if verb == "label create":
    s["labels"].append(args[2])
    save()
    sys.exit(0)
print(f"fake gh: unsupported {args}", file=sys.stderr)
sys.exit(3)
