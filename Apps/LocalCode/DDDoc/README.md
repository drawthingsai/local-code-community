# Local Code Design Decision Documents

`DDDoc` records major Local Code design decisions, their rationale, the
implemented contract, and the invariants future changes preserve.

| Document | Status | Decision |
| --- | --- | --- |
| [Remote Access](RemoteAccess.md) | Implemented (v0); verified end to end through staging | Work in a Mac's threads from an iPhone or iPad on the same Local Code account, over a WebRTC data channel the two open through a per-account room. |
| [Remote Access Services](RemoteAccessServices.md) | Implemented | Run gRPC over the Remote Access link, with one service for the Mac's projects and threads, worked on from a phone as on the Mac. |
| [CodeAgent Scheduling](CodeAgentScheduling.md) | Implemented | Cooperatively pause, resume, and hibernate local CodeAgents while one model-specific scheduler prioritizes the foreground thread and preserves bounded background work. |
| [Context Compaction](ContextCompaction.md) | Implemented | Keep model continuation within a useful context budget through model-family-specific deterministic reduction and semantic checkpoints; currently documents the Qwen 3.5 family. |
| [Project History Persistence](ProjectHistoryPersistence.md) | Implemented | Store each project's thread history and adjacent pending prompts in a project-local Dflat/SQLite database. |
| [Memory](ProjectMemory.md) | First local draft | Keep USER.md and MEMORY.md in each project's .localc directory, with frozen prompt inclusion and review using temporary ask to restore the existing KV prefix while displaying Reviewing Memory feedback. |
| [Memory Prompt Study](MemoryPromptStudy.md) | Source study; integrated prompts | Compare DS4/DSH, Qwen, Hermes, and OpenCode memory behavior, with the implemented combined-context and temporary-review wording and source rationale. |
| [MCP Integration Hand-off](MCPIntegrationHandoff.md) | Source investigation; proposed integration | Record MCP fundamentals, Pi's landed direct/deferred implementation, Local Code integration points, schema/cache experiments, and a phased integration and validation plan. |
| [MCP Integration Harness](../Tests/MCPIntegrationHarness/README.md) | Proposed harness; live auth discovery checked | Define real GitHub/Linear fixtures, JSON configuration, same-session runtime toggles, auth and model test stages, and setup requirements. |
| [Browser Use Handoff](BrowserUseHandoff.md) | Proposed investigation; Liu Liu is not fully onboard | Record browser and computer-use implementation evidence, open architecture decisions, Local Code integration points, executable experiments, and MVP acceptance criteria. |
| [Bash Inline Image Support Handoff](BashImageSupportHandoff.md) | Handoff; bash transport landed | Record the proposed OSC 1337 PNG transport checklist, the landed bash image path, and browser screenshot/snapshot integration. |
| [Local Code Computer](LocalCodeComputer.md) | Proposed; decisions agreed | Run Bash on the user's Mac through a separately downloaded menu-bar companion that runs zsh under Seatbelt and asks for approval only when a command needs more than the default sandbox. |
