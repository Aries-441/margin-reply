# Questions to try

The bot answers from the document body only. Good questions point at a section, a term or a decision in the doc.

## 中文

- 这份文档的核心结论是什么？用三句话概括。
- 第 2 节里提到的「灰度窗口」具体指什么？文档里有定义吗？
- 文档里的部署步骤，如果我只想跑本地环境，哪几步可以跳过？
- 这个方案有哪些没写出来的前提假设？
- 把「常见问题」那一节改写成给新同事看的三条要点。

## English

- Summarize the decisions in this document in three bullet points.
- What does the document say happens when the upstream returns a 429?
- Which steps of the rollout plan assume a staging environment?
- What is left unspecified in the "error handling" section?
- Rewrite the acceptance criteria as a checklist a QA engineer could run.

## Tips

- Mention the bot explicitly: `@文档解答机器人` in the comment box.
- Ask one question per comment — the bot answers in the same thread, so follow-ups work.
- The bot reads the whole docx (up to ~30k characters, head and tail kept). Very long docs are truncated in the middle.
- Solved comments are skipped; unresolved the comment first if you want another answer.
