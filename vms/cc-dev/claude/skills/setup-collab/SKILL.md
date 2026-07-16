---
name: setup-collab
description: Scaffold a multi-agent "mailbox" collaboration for real work. Define the roles that will take part (roles are entirely user-defined, none are assumed), generate one prompt file per role, and set up a shared mailbox plus watch/send scripts so each agent works in its own session and coordinates with the others over the mailbox. Use when the user wants several agents to collaborate on a task, split work across roles, or says "setup collab".
---

# setup-collab

Scaffold a collaboration where N agents work a shared objective, each in its own
session and context, coordinating through a shared **mailbox** file. Each agent
hears the others via a **Monitor**, does its actual work with its own tools, and
posts compact updates to the mailbox when the others need to act.

Roles are NOT predefined. Whatever roles the user wants, you set up. Do not
assume a particular set.

The unit you optimize is the context: every agent keeps its own working context;
the mailbox is the only shared, compact coordination channel between them.

## Inputs

- **objective**: the shared task the group is working toward (inline it; it goes
  into every prompt verbatim).
- **working dir**: the directory/repo where the real work happens (the code, the
  docs, whatever). Shared by all roles. Distinct from the mailbox.
- **roles** (at least 2): for each, gather
  - **id**: short lowercase handle, no spaces (e.g. `arch`). Used in filenames + mailbox.
  - **display**: name shown to the others (e.g. `Architect`).
  - **responsibilities**: what this role does, decides, and is accountable for;
    what it should announce to the others and what it should react to.
  - **kickoff**: exactly ONE role kicks the work off; the rest wait for the first
    relevant message (and may do independent prep meanwhile).

## Workflow

1. **Gather inputs.** Take roles + objective + working dir from the user's prompt
   if given. Otherwise ask. Require at least 2 roles and exactly one kickoff role.

2. **Confirm before writing.** Echo back the objective, the working dir, and the
   full roster (id, display, one-line responsibilities, who kicks off). Ask the
   user to confirm everything is well defined. Do NOT create any file until they
   confirm. Adjust and re-confirm as needed.

3. **Pick the mailbox dir.** Ask if not implied; default to a `collab/` folder
   under the working subject. Use an absolute path from here on.

4. **Scaffold.** In the mailbox dir:
   - Copy `assets/mailbox-watch.sh` and `assets/mailbox-send.sh` there, `chmod +x` both.
   - Create an empty `mailbox.jsonl` (`touch`).
   - For each role, write `prompt-<id>.md` from `assets/role-prompt.md.tmpl`,
     substituting: display, id, the list of OTHER participants (display + id),
     the objective, the working dir, the responsibilities, the absolute paths to
     the two scripts, and the KICKOFF block (kickoff role starts; others wait).
     Strip the `{{...}}` markers.

5. **Report.** Give the launch instructions: one session per role, paste its
   `prompt-<id>.md`. Start the non-kickoff roles first so their monitors are
   armed (the watcher only sees lines written after it starts), then the kickoff
   role last.

## How it works (for your own understanding)

- `mailbox-send.sh <from> <text> [mentions-csv]` appends one JSON line
  `{from, text, mentions:[...]}`. `mentions` flags whose reply/action is expected.
- `mailbox-watch.sh <me>` does `tail -F | jq` and emits only lines where
  `from != <me>` — everything the others say — annotated with the mentions, and
  showing `you` when this agent is mentioned. Run it as a **persistent Monitor**.
- Broadcast with N roles: each agent hears all others. Mentions are a request for
  a specific role to respond, not a gate — any agent may jump in when relevant.
- The mailbox is a coordination channel, not a data store: agents point to
  artifacts in the working dir (paths, diffs) instead of pasting large content.
