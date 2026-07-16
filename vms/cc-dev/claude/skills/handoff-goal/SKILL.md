---
name: handoff-goal
description: Produce a self-contained handoff document that briefs another agent on a goal extracted from the current chat. Use when the user says "handoff", "handoff goal", "prepare a handoff", "write a prompt for another agent", "draft a brief for an implementer", or wants to turn the current discussion into a ready-to-paste task for a fresh-context agent.
argument-hint: <optional extra steer>
---

# Handoff Goal

Turn the current chat into a single, self-contained brief that an agent with **no prior context** can act on. Output the brief as one fenced code block, nothing else around it.

Use `$ARGUMENTS` as extra steer if present. Otherwise infer the goal from the most recent user intent in the conversation.

## Rules

- Self-contained. The receiver did not see this chat. Inline every file path, contract, identifier, and constraint they need. No "see above", no "as discussed".
- High fidelity. Quote exact names, line ranges, schema field names, button labels, route paths from the chat. No paraphrasing of contracts.
- Concise. No preamble, no commentary, no closing notes. Drop sections that genuinely don't apply rather than padding them.
- Separate hint from mandate. HINTS are deviatable; REQUIRED OUTCOME, NON-GOALS, ACCEPTANCE are not.
- Plain text inside the block. No markdown headings, no emojis. ALL-CAPS section labels only.
- Do not invent acceptance criteria, file paths, or constraints that weren't in the chat. If a section would require guessing, omit it.

## Template

Render exactly this shape, dropping any section that doesn't apply:

```
GOAL
<one or two sentences stating the outcome>

CONTEXT
<what the receiver needs upfront: repo paths, current behavior, key files,
relevant contracts, prior decisions from the chat>

REQUIRED OUTCOME
1. <observable result>
2. <observable result>
...

HINTS (not mandates — deviate if better)
- <recommended approach, naming, shape>
- <recommended approach, naming, shape>

FREEDOM
<what the receiver can choose freely; what they cannot — call out contracts,
schemas, public APIs that must stay stable>

NON-GOALS
- <explicit out-of-scope>
- <explicit out-of-scope>

ACCEPTANCE
- <how to verify it's done>
- <how to verify it's done>
```

## After rendering

Output only the fenced code block. No lead-in like "Here is the handoff". No trailing summary. The user copies the block as-is.
