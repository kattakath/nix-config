---
name: map
description: Birds-eye architecture map of the current repo with an ASCII diagram. Use when I want the grand scheme of a codebase.
context: fork
agent: cartographer
allowed-tools: Bash(gh:*), Bash(git:*), Bash(mermaid-ascii:*), Read, Grep, Glob
---
Produce a birds-eye map of this repository.
1. One-paragraph BLUF: what this system is and does.
2. ASCII architecture diagram (boxed nodes, --> arrows) of the main components.
3. Table: component | path | responsibility.
4. Key data/control flows in prose.
5. Where to start reading, and the 3 riskiest areas.
