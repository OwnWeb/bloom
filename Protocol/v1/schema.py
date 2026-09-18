#!/usr/bin/env python3
"""The bloom-workspace version 1 JSON Schema, and the check that the Swift types, the schema and
the checked-in vectors all agree.

    python3 Protocol/v1/schema.py            regenerate workspace-v1.schema.json
    python3 Protocol/v1/schema.py --check    fail when the schema is stale, a kind in the Swift
                                             source is missing from it, or a vector does not
                                             validate

The vectors are written by the Swift types themselves (Packages/BloomProtocol, WireVectorTests),
so this is the third corner of a triangle: a change to a Swift type moves the vectors, and this
says whether the schema a client in another language reads still describes them.

No jsonschema package: the validator below covers the subset this schema uses (type, properties,
required, additionalProperties, items, enum, const, oneOf, $ref), so the check runs on any machine
with Python 3 and nothing installed, including CI's Swift container.
"""
import argparse
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCES = ROOT / "Packages/BloomProtocol/Sources/BloomProtocol"
SCHEMA_PATH = HERE / "workspace-v1.schema.json"
VECTORS_PATH = HERE / "vectors.json"

S = {"type": "string"}
I = {"type": "integer"}
N = {"type": "number"}
B = {"type": "boolean"}
DATE = {"type": "string", "format": "date-time"}
BASE64 = {"type": "string", "contentEncoding": "base64"}
ANY = {}


def ref(name):
    return {"$ref": "#/$defs/" + name}


def array(items):
    return {"type": "array", "items": items}


def nullable(value):
    return {"oneOf": [value, {"type": "null"}]}


def obj(required, optional=None):
    """An object with exactly these fields. Optional fields may be absent or null."""
    optional = optional or {}
    properties = dict(required)
    properties.update({key: nullable(value) for key, value in optional.items()})
    return {"type": "object", "properties": properties, "required": sorted(required), "additionalProperties": False}


def tagged(cases):
    """One object per kind: `kind` plus that case's own fields."""
    variants = []
    for kind, (required, optional) in cases.items():
        fields = {"kind": {"const": kind}}
        fields.update(required)
        variants.append(obj(fields, optional))
    return {"oneOf": variants}


def record(kind, name):
    """A case carrying a whole record under a key named after its kind."""
    return ({kind: ref(name)}, {})


def plain(required=None, optional=None):
    return (required or {}, optional or {})


SCOPE = {"enum": ["branch", "uncommitted", "staged", "unstaged"]}

OPERATIONS = {
    "workspace": plain(),
    "transcript": plain({"chat_id": S, "after_seq": I}, {"limit": I}),
    # No `chat_id` asks what a chat that does not exist yet would start with.
    "composer": plain({}, {"chat_id": S}),
    "setup_output": plain(),
    "files": plain(),
    "history": plain({}, {"limit": I, "before": S}),
    "commit_files": plain({"sha": S}),
    "commit_patch": plain({"sha": S, "path": S}),
    "transcript_search": plain({"query": S}, {"limit": I}),
    "file": plain({"path": S}),
    "download": plain({"path": S}),
    "review_snapshot": plain({"scope": SCOPE, "wait": B}, {"known_revision": S}),
    "review_patch": plain({"path": S, "scope": SCOPE}, {"known_revision": S}),
    "run_scripts": plain(),
    "notes": plain(),
    "pull_request": plain(),
    "archive_preview": plain(),
    "new_chat": plain({"controls": ref("ComposerControls")}),
    "rename_chat": plain({"chat_id": S, "title": S}),
    "close_chat": plain({"chat_id": S}),
    "mark_read": plain({"chat_id": S, "seq": I}),
    "set_composer": plain({"chat_id": S, "controls": ref("ComposerControls")}),
    "send": plain({"chat_id": S, "text": S}, {"audience": ref("Audience")}),
    "cancel_queued": plain({"chat_id": S, "prompt_id": S}),
    "stop": plain({"chat_id": S}),
    "answer": plain({"chat_id": S, "request_id": S, "answer": ref("Answer")}),
    "write_file": plain({"path": S, "text": S, "revision": S}),
    "upload_file": plain({"name": S, "data": BASE64}),
    "commit": plain({"message": S}),
    "push": plain(),
    "create_pull_request": plain({"title": S, "body": S, "draft": B}),
    "save_notes": plain({"text": S}),
    "revert_file": plain({"path": S, "scope": SCOPE}),
    "discard_hunk": plain({"path": S, "scope": SCOPE, "patch": S}),
    "rename_workspace": plain({"name": S}),
    "run_setup": plain(),
    "run_script": plain({"id": S}),
    "close_terminal": plain({"name": S}),
    "archive": plain({"confirmation_id": S}),
}

ANSWERS = {
    "allow_once": plain(),
    "allow_session": plain(),
    "allow_project": plain(),
    "deny": plain({"ends_turn": B}, {"message": S}),
    "approve_plan": plain({"permission_mode": S}),
    "question": plain({"input": ANY}),
}

RESULTS = {
    "accepted": plain(),
    "workspace": record("workspace", "WorkspaceSnapshot"),
    "transcript": record("transcript", "Transcript"),
    "composer": record("composer", "Composer"),
    "setup_output": record("setup_output", "SetupOutput"),
    "files": plain({"paths": array(S)}),
    "history": record("history", "History"),
    "commit_files": plain({"files": array(ref("ChangedFile"))}),
    "search": record("search", "Search"),
    "file": record("file", "TextFile"),
    "download": record("download", "Download"),
    "review_snapshot": record("review_snapshot", "ReviewSnapshot"),
    "review_patch": record("review_patch", "PatchSnapshot"),
    "run_scripts": plain({"scripts": array(ref("RunScript"))}),
    "text": plain({"value": S}),
    "chat": record("chat", "Chat"),
    "queued": plain({"prompt_id": S}),
    "archive_preview": record("archive_preview", "ArchivePreview"),
    "terminal": record("terminal", "Terminal"),
}

EVENTS = {
    "message": record("message", "Message"),
    "stream": plain({"chat_id": S, "text": S, "snapshot": B}),
    "chat": record("chat", "Chat"),
    "queue": record("queue", "Queue"),
    "questions": plain({"chat_id": S, "questions": array(ref("Question"))}),
    "composer": plain({"chat_id": S, "controls": ref("ComposerControls")}, {"changed_by": ref("Author")}),
    "setup": record("setup", "Setup"),
    "setup_output": plain({"text": S}),
    # An agent on the machine asking a client to open a browser pane. A request, not an
    # instruction: nobody may be listening, and several may be.
    "pane_requested": plain({}, {"url": S, "chat_id": S}),
    "presence": plain({"users": array(ref("Presence"))}),
    "workspace": record("workspace", "Workspace"),
    "sleeping": plain(),
    "closing": plain({"error": ref("Error")}),
}

TERMINAL_FRAMES = {
    "auth": plain({"token": S}),
    "reauth": plain({"token": S}),
    "resize": plain({"columns": I, "rows": I}),
}

# **A field added after machines shipped is optional here, whatever the machine now sends.**
#
# The schema is the artefact a client reads first and generates types from, so what it says becomes
# what a client refuses. "Every current machine sends this" is a fact about deployment; a schema is
# a promise, and the promise has to hold for the machine somebody is actually connected to. The web
# client met this as a crash rather than a type error: a snapshot from a machine older than
# `members` threw, and **the workspace could not be opened at all**. Marking the addition optional
# would have made that impossible rather than merely documented.
#
# What a current machine sends is in `vectors.json`, which is the right place for it: a vector is an
# example and a schema is a promise. The fields this applies to today are `members`, `services`,
# `setup.enabled` and a service's `http`.
RECORDS = {
    "Error": obj({"code": S, "message": S}),
    # `name` may be empty, and `email` is what a client draws when it is. Not one overloaded field:
    # mention completion matches on these, and picking the wrong person misaddresses a message.
    "Author": obj({"user_id": S, "name": S}, {"email": S}),
    # `enabled` is optional here for the reason at the head of RECORDS: a machine older than the
    # field does not send it, and a client decodes its absence as true.
    "Setup": obj({"state": {"enum": ["pending", "running", "succeeded", "failed", "skipped"]}},
                 {"step": S, "started_at": DATE, "finished_at": DATE, "note": S, "enabled": B}),
    "SetupOutput": obj({"setup": ref("Setup"), "log": S}),
    "PullRequest": obj({"number": I, "url": S, "title": S, "state": S}),
    "Workspace": obj({"id": S, "name": S, "branch": S, "base_branch": S, "setup": ref("Setup")},
                     {"pull_request": ref("PullRequest"), "reporting": ref("Reporting"),
                      "services": array(ref("Service"))}),
    # A service that never started says so here and nowhere else. Empty for a project with none.
    "Service": obj({"name": S, "state": S, "restarts": I}, {"message": S, "http": B}),
    # Present only when the machine has something wrong to say about reaching runbloom.app.
    "Reporting": obj({"shed": I}, {"unreachable_since": DATE}),
    "Chat": obj({"id": S, "title": S, "agent": S, "model": S, "effort": S, "permission_mode": S, "interaction_mode": S,
                 "state": S, "last_seq": I, "created_at": DATE, "updated_at": DATE}, {"parent_chat_id": S}),
    "Message": obj({"cursor": I, "chat_id": S, "seq": I, "kind": S, "payload": ANY, "created_at": DATE},
                   {"author": ref("Author"), "duration_ms": I, "ref_id": S, "audience": ref("Audience")}),
    # Who a message was for. Absent means the agent, which is every message written before mentions
    # existed. A message whose kind is `person` is one the agent is never given.
    "Audience": obj({"kind": {"enum": ["agent", "person"]}}, {"user_id": S, "mention": S}),
    "Blocked": obj({"limit": S, "message": S}),
    "QueuedPrompt": obj({"id": S, "text": S, "state": {"enum": ["queued", "blocked", "uncertain"]}, "created_at": DATE},
                        {"author": ref("Author"), "blocked": ref("Blocked")}),
    "Queue": obj({"chat_id": S, "prompts": array(ref("QueuedPrompt"))}, {"error": S}),
    "Question": obj({"request_id": S, "chat_id": S, "ask": ANY, "asked_at": DATE}),
    "Transcript": obj({"chat": ref("Chat"), "messages": array(ref("Message")), "has_more": B, "questions": array(ref("Question")),
                       "busy": B, "streaming_text": S, "queue": ref("Queue")}),
    "ComposerControls": obj({"agent": S, "model": S, "effort": S, "permission_mode": S, "interaction_mode": S, "fast_mode": B,
                             "output_style": S, "codex_context_window": I}, {"codex_fast_mode": B}),
    "Model": obj({"agent": S, "id": S, "label": S, "efforts": array(S), "is_default": B}, {"default_effort": S}),
    "SlashCommand": obj({"name": S, "description": S}),
    "Composer": obj({"controls": ref("ComposerControls"), "available_agents": array(S), "models": array(ref("Model")),
                     "commands": array(ref("SlashCommand")), "output_styles": array(S)}, {"chat_id": S}),
    "ChangedFile": obj({"path": S, "change": {"enum": ["added", "modified", "deleted", "renamed", "copied", "untracked"]},
                        "additions": I, "deletions": I, "is_binary": B},
                       {"old_path": S, "content_revision": S,
                        "layer": {"enum": ["conflicted", "staged", "unstaged", "untracked"]}}),
    "Commit": obj({"sha": S, "subject": S, "author_name": S, "author_email": S, "date": DATE, "body": S, "parents": array(S)},
                  {"pushed": B}),
    "History": obj({"commits": array(ref("Commit")), "has_more": B}),
    "SearchPiece": obj({"text": S, "is_match": B}),
    "SearchMatch": obj({"chat_id": S, "chat_title": S, "seq": I, "cursor": I, "kind": S, "at": DATE,
                        "excerpt": array(ref("SearchPiece"))}),
    "Search": obj({"matches": array(ref("SearchMatch")), "total": I}),
    "ReviewSnapshot": obj({"revision": S}, {"files": array(ref("ChangedFile"))}),
    "PatchSnapshot": obj({"revision": S}, {"patch": S}),
    "TextFile": obj({"path": S, "text": S, "revision": S}),
    "Download": obj({"path": S, "data": BASE64}),
    "ArchivePreview": obj({"confirmation_id": S, "has_uncommitted_changes": B, "untracked_files": array(S), "unpushed_commits": I,
                           "detached_commits": I, "is_agent_running": B, "is_pull_request_merged": B,
                           "deletes_conversation": {"const": True}, "created_at": DATE}),
    "RunScript": obj({"id": S, "name": S, "command": S}),
    "Terminal": obj({"name": S, "title": S}),
    "Presence": obj({"user_id": S, "name": S}, {"last_input_at": DATE}),
    "WorkspaceSnapshot": obj({"workspace": ref("Workspace"), "chats": array(ref("Chat")), "presence": array(ref("Presence")),
                              "cursor": I, "composer_defaults": ref("ComposerControls")},
                             {"members": array(ref("Member"))}),
    # Who may be addressed with `@`, which is not `presence`: that is who is here, and somebody who
    # is away is exactly who a mention is for. No addresses; a share-link guest reads this too.
    "Member": obj({"user_id": S, "name": S, "handle": S}),
}


def build():
    definitions = dict(RECORDS)
    definitions["Operation"] = tagged(OPERATIONS)
    definitions["Answer"] = tagged(ANSWERS)
    definitions["Result"] = tagged(RESULTS)
    definitions["Event"] = tagged(EVENTS)
    definitions["TerminalFrame"] = tagged(TERMINAL_FRAMES)
    definitions["Request"] = obj({"protocol": {"const": "bloom-workspace"}, "version": {"const": 1}, "command_id": S,
                                  "operation": ref("Operation")})
    definitions["Reply"] = {"oneOf": [
        obj({"version": {"const": 1}, "command_id": S, "result": ref("Result")}),
        obj({"version": {"const": 1}, "command_id": S, "error": ref("Error")}),
    ]}
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://runbloom.app/schemas/bloom-workspace-v1.json",
        "title": "bloom-workspace protocol, version 1",
        "description": "Requests and replies on POST /_bloom/v1/rpc, events on GET /_bloom/v1/events, and text frames on the "
                       "terminal WebSocket. See docs/WORKSPACE-PROTOCOL.md.",
        "$defs": definitions,
    }


def swift_kinds(file_name, type_name):
    """The `case "kind":` strings in one Swift type's decoder, which is what the schema must list."""
    text = (SOURCES / file_name).read_text()
    start = text.index(type_name)
    decoder = text.index("init(from decoder", start)
    end = text.index("default: throw Tagged.unknown", decoder)
    return set(re.findall(r'case "([a-z_]+)":', text[decoder:end]))


# The subset of JSON Schema this file uses.
def validate(value, schema, root, path="$"):
    if "$ref" in schema:
        return validate(value, root["$defs"][schema["$ref"].split("/")[-1]], root, path)
    if "oneOf" in schema:
        matches = [option for option in schema["oneOf"] if not validate(value, option, root, path)]
        if len(matches) != 1:
            return [f"{path}: matched {len(matches)} of {len(schema['oneOf'])} alternatives"]
        return []
    if "const" in schema:
        return [] if value == schema["const"] and type(value) is type(schema["const"]) else [f"{path}: expected {schema['const']!r}"]
    if "enum" in schema:
        return [] if value in schema["enum"] else [f"{path}: {value!r} is not one of {schema['enum']}"]
    kind = schema.get("type")
    checks = {
        "string": lambda v: isinstance(v, str), "boolean": lambda v: isinstance(v, bool), "null": lambda v: v is None,
        "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
        "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
        "array": lambda v: isinstance(v, list), "object": lambda v: isinstance(v, dict),
    }
    if kind and not checks[kind](value):
        return [f"{path}: expected {kind}"]
    errors = []
    if schema.get("format") == "date-time" and not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z", value):
        errors.append(f"{path}: {value!r} is not an ISO 8601 UTC date")
    if kind == "array":
        for index, item in enumerate(value):
            errors += validate(item, schema.get("items", {}), root, f"{path}[{index}]")
    if kind == "object":
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing {key}")
        for key, item in value.items():
            if key in properties:
                errors += validate(item, properties[key], root, f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unexpected field {key}")
    return errors


def check(schema):
    problems = []
    for file_name, type_name, cases in [
        ("WorkspaceOperation.swift", "public enum WorkspaceOperation", OPERATIONS),
        ("WorkspaceOperation.swift", "public enum Answer", ANSWERS),
        ("OperationResult.swift", "public enum OperationResult", RESULTS),
        ("WorkspaceEvent.swift", "public enum WorkspaceEvent", EVENTS),
        ("WorkspaceEvent.swift", "public enum TerminalControlFrame", TERMINAL_FRAMES),
    ]:
        swift = swift_kinds(file_name, type_name)
        if swift != set(cases):
            problems.append(f"{type_name}: Swift has {sorted(swift - set(cases))} the schema lacks, "
                            f"the schema has {sorted(set(cases) - swift)} Swift lacks")
    vectors = json.loads(VECTORS_PATH.read_text())
    for group, definition in [("requests", "Request"), ("replies", "Reply"), ("errors", "Reply"),
                              ("events", "Event"), ("terminal_frames", "TerminalFrame")]:
        for name, value in vectors[group].items():
            for error in validate(value, ref(definition), schema):
                problems.append(f"{group}.{name}: {error}")
    # And the other direction: things a server must never accept.
    malformed = [
        ("an operation from #163", {"protocol": "bloom-workspace", "version": 1, "command_id": "c", "operation": {"kind": "catalogue"}}),
        ("a missing command id", {"protocol": "bloom-workspace", "version": 1, "operation": {"kind": "workspace"}}),
        ("a send with no chat", {"protocol": "bloom-workspace", "version": 1, "command_id": "c", "operation": {"kind": "send", "text": "x"}}),
        ("a workspace id on an operation", {"protocol": "bloom-workspace", "version": 1, "command_id": "c",
                                            "operation": {"kind": "stop", "chat_id": "c", "workspace_id": "w"}}),
        ("another version", {"protocol": "bloom-workspace", "version": 2, "command_id": "c", "operation": {"kind": "workspace"}}),
    ]
    for name, value in malformed:
        if not validate(value, ref("Request"), schema):
            problems.append(f"the schema accepted {name}")
    archive = json.loads(json.dumps(vectors["replies"]["archive_preview"]))
    del archive["result"]["archive_preview"]["unpushed_commits"]
    if not validate(archive, ref("Reply"), schema):
        problems.append("the schema accepted an archive preview without unpushed_commits")
    return problems, sum(len(vectors[group]) for group in vectors)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    schema = build()
    text = json.dumps(schema, indent=2, ensure_ascii=False) + "\n"
    if args.check:
        problems, count = check(schema)
        if not SCHEMA_PATH.exists() or SCHEMA_PATH.read_text() != text:
            problems.insert(0, "workspace-v1.schema.json is stale. Run python3 Protocol/v1/schema.py")
        if problems:
            print("\n".join(problems), file=sys.stderr)
            raise SystemExit(1)
        print(f"Schema, Swift kinds and {count} vectors agree, and 6 malformed values are refused.")
    else:
        SCHEMA_PATH.write_text(text)
        print(f"Wrote {SCHEMA_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
