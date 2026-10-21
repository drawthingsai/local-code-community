---
name: skill-creator
description: Guide for creating, importing, updating, disabling, deleting, and validating workspace skills. Use when users want reusable specialized workflows, knowledge, or tool integrations, or ask how skills work.
---

# Skill Creator

## Skill operation routing

- Set `SKILLS_ROOT=.agents/skills` relative to the project. Create, import, edit, and validate workspace skills there. A complete directory under this root is installed.
- Resolve a named skill by matching its `name` frontmatter in `SKILLS_ROOT/*/SKILL.md`; never ask the user for an internal identifier.
- App-bundled skills under `/app_bundle/Skills` are read-only. Do not edit or copy one into the workspace unless the user asks to customize it.
- Disable a skill by moving its complete directory outside `SKILLS_ROOT`. Permanently delete it only when explicitly requested.
- Work only inside the selected workspace, use project-relative paths, and preserve unrelated files. A skill does not grant permission for unrelated publishing, purchases, messages, or destructive actions.

## About skills

Skills are self-contained folders for reusable workflows, tool integrations, domain knowledge, and supporting resources. Relevant skills are selected automatically; users can invoke one with `$skill-name`.

## Core principles

### Concise is key

Context is shared with the system prompt, conversation, other skills, and task. Assume the model is capable. Include only information that improves decisions or execution; prefer concise examples to generic explanation.

### Set appropriate degrees of freedom

- **High freedom — text instructions:** use when several approaches are valid or judgment depends on context.
- **Medium freedom — pseudocode or parameterized scripts:** use when a preferred pattern exists but variation is acceptable.
- **Low freedom — specific scripts and a fixed sequence:** use when the operation is fragile, error-prone, or must be consistent.

Implement exactly the requested behaviors first. Do not invent directory recursion, ordering rules, output formats, or convenience flags. Test that version, then add behavior only when the request or a failed test requires it.

For a new skill, do not inspect sibling projects or previously generated skills for examples unless the user asks. Build directly from the request and this guide.

### Protect validation integrity

Test observable behavior in fresh tasks with raw fixtures and minimal context. Do not reveal intended answers or prior conclusions. Isolate evaluation artifacts from later runs.

## Anatomy of a skill

```text
skill-name/
|-- SKILL.md       Required YAML frontmatter and Markdown instructions
|-- scripts/       Optional deterministic executable helpers
|-- references/    Optional documentation loaded only when relevant
`-- assets/        Optional templates or files used in generated output
```

`SKILL.md` frontmatter contains only string fields `name` and `description`. The description is the primary trigger: say what the skill does and when to use it. Put instructions in the body. Quote YAML punctuation such as `:`.

Use `scripts/` for repeated or deterministic code, `references/` for schemas and conditional detail, and `assets/` for output templates or media. Link each resource from `SKILL.md` and say when to use it. Do not add a README, changelog, empty directory, or placeholder. The skill format does not use provider metadata such as `agents/openai.yaml`.

## Progressive disclosure

Skills load in three stages: metadata, `SKILL.md`, then linked resources as needed. Keep `SKILL.md` below the 8,000-byte direct-injection limit. Move variant detail into one-level-deep references.

## Skill creation process

1. Understand the skill through concrete examples.
2. Plan reusable scripts, references, and assets.
3. Create the skill under `SKILLS_ROOT`.
4. Implement resources and write `SKILL.md`.
5. Validate the skill and run its scripts.
6. Use the created skill on realistic tasks and iterate.
7. Confirm that the validated directory is installed under `SKILLS_ROOT`.

### 1. Understand concrete examples

Establish likely requests, triggers, expected output, and forbidden behavior. Use the user's examples or propose a few. Ask one important question at a time until the behavior is clear.

### 2. Plan reusable contents

For each example, consider how to complete it from scratch and what is reusable. PDF rotation may justify `scripts/rotate_pdf.py`; data queries may need `references/schema.md`; a web app may need `assets/starter/`. Create only purposeful resources.

### 3. Create or update the skill

Inspect only the requested skill path. If it exists, use `list` and `read` before editing; if it is absent, create it directly without inspecting unrelated project contents. Use `write` and `edit` under `SKILLS_ROOT/<skill-name>/`; never replace blindly. Use lowercase letters, digits, and single hyphens, at most 64 characters. Match folder and frontmatter names.

### 4. Implement resources and instructions

Start with reusable resources, then write imperative instructions. Describe capabilities and constraints in terms of the current environment, not the app's product name. Capabilities are reported by interface. For Bash, the Shell Commands list is authoritative: a listed `python3` is usable even if a separate `Python: unavailable` field means no embedded Python integration. Verify it once with `python3 --version`; if that succeeds, stop probing. Do not test optional imports unless the new resource requires them. Do not try version-suffixed alternatives or use `command -v`, `which`, shell startup files, or filesystem searches. Prefer a listed runtime with no new dependencies; on failure, use a reported alternative or state the limitation.

For each required tool or script, give its skill-relative path, exact invocation, and usage condition. Use reported capabilities; prefer pure Python without child processes or native builds. Test each script on a representative fixture.

### 5. Validate the skill

Validate manually with the available file tools: read changed files back and check frontmatter, name/path agreement, byte size, links, placeholders, runtime compatibility, scope, and absence of provider metadata. The bundled `/app_bundle/Skills/skill-creator/scripts/validate_skill.py` path is readable by file tools but not executable from Bash in the current environment. Do not try to run, locate, copy, or reimplement it; do not search for PyYAML, create a YAML shim, or install dependencies. Report the manual checks and fix every issue found.

### 6. Iterate and forward-test

Use the skill on realistic requests in fresh threads. Every Bash call starts at the selected workspace root. Never use `cd`; pass workspace-root-relative or absolute paths, for example `python3 .agents/skills/<skill-name>/scripts/<script>.py ...`. Path resolution in the current environment can ignore shell directory changes. Use the smallest fixture that proves the requested outcomes, usually a few records or files rather than a realistic large dataset. Test the required happy path before adding optional polish. Review tool use, outputs, diffs, logs, and artifacts. Update only what evidence supports, revalidate, and retest. Complex or risky skills need positive, failure, and boundary or adversarial cases. Directly exercise every safety claim; do not infer one refusal path from a different test.

### 7. Confirm installation

Confirm `SKILLS_ROOT/<skill-name>/SKILL.md` is the validated file. Report purpose, files, validation and forward-test results, and untested capabilities. Existing threads may need restarting to see changes.

## Uploaded skills

When asked to import an uploaded skill, inspect its claims and files, validate it, then place the complete directory under `SKILLS_ROOT`. Explain discrepancies before installation. Mere upload is not an installation request.
