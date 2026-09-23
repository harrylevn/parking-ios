---
name: ai-log
description: Draft an entry for docs/ai-workflow.md about how AI helped or failed on the current change, and suggest the AI-Assisted commit trailer. Only when the user invokes it.
disable-model-invocation: true
---

# AI workflow log entry

`docs/ai-workflow.md` is an honest account, written as the fortnight goes, of where AI
helped and where it failed. This skill keeps it current. It is **the author's** account, so
the facts come from the author. Claude's job is to ask the right questions and draft the
prose. It does not supply the verdict.

## Steps

1. **Read the change.** `git log main..HEAD` and `git diff main...HEAD`, or the range
   given as an argument. Then read `docs/ai-workflow.md` in full, both for its voice and so
   the new entry does not repeat an existing one.
2. **Ask, don't infer.** Use AskUserQuestion to find out:
   - How was AI involved: drafted, reviewed, or not at all?
   - What did you keep, what did you rewrite, and why?
   - Did anything it produced turn out wrong? What caught it, and how long did it cost?

   Never invent a failure to make the account look balanced. Never leave one out to make it
   look better. If nothing notable happened, say so and stop; most changes do not earn an
   entry.
3. **Draft in the document's voice.** British spelling. It opens with a bold sentence that
   states the lesson, then gives the concrete incident: the file, the symptom, what caught
   it. Say *what caught it* rather than *what fixed it*, because the catching is the
   transferable part. No bullet lists, no hedging, no self-congratulation.

   Put it under **Where it helped** or **Where it failed me**. Change **What I take from
   it** only if the incident actually changes that conclusion.
4. **Show the draft and wait.** Present it as a draft for the author to rewrite. CLAUDE.md
   requires the rationale to be in their words. Edit the file only after they approve, and
   use their edits verbatim.
5. **Suggest the trailer** for the commit that carries the change:

   ```
   AI-Assisted: drafted | reviewed | none
   ```

## Limits

Nothing from CLAUDE.md's "Never" list goes into the entry: no real plates, tokens, log
payloads or security findings. Describe the *shape* of an incident, not its payload.
