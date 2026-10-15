# Domain Docs

This repo uses a single-context layout: root `GLOSSARY.md` and `docs/adr/`.

## Before exploring, read these

- `GLOSSARY.md` at the repo root for domain vocabulary.
- ADRs in `docs/adr/` that touch the area you are about to work in.

If these files do not exist, proceed silently. Do not flag their absence or suggest creating them upfront. The `/domain-modeling` skill creates them lazily when terms or decisions get resolved.

## Use the glossary's vocabulary

When naming a domain concept in an issue title, refactor proposal, hypothesis, or test name, use the term defined in `GLOSSARY.md`. Avoid synonyms the glossary explicitly rejects.

If a concept is missing, reconsider whether it belongs to the project vocabulary; note a real gap for `/domain-modeling`.

## Flag ADR conflicts

If your output contradicts an existing ADR, surface the conflict explicitly rather than silently overriding the decision. Identify the ADR and explain why it may need reopening.
