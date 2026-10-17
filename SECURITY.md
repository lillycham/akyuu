# Security

Akyuu is a tool for one user on their own machine. Its trust model is in the
README ("Trust and safety").

## Reporting a problem

Please report a security problem privately, with GitHub's "Report a
vulnerability" button on the Security tab of this repository (private
vulnerability reporting). If that is not available, write to
me@lillycham.com. Do not open a public issue for it.

Say what you did, what you expected and what happened. I will answer within a
week, and I will tell you when a fix is released.

## What is in scope

- The web view (`akyuu serve`) and the MCP server (`akyuu mcp`): a way to
  read or change the store without the person's agent doing so, for example
  through a web page that the person visits.
- A way to make akyuu write outside the root of the store, or to run a command
  that the person did not set.
- A memory file that makes akyuu crash, hang or corrupt the store.

## What is not

- An agent that you connected to the MCP server changing your memories. That is
  the purpose of the tool.
- The commands of the embedding profiles in `~/.config/akyuu/config.toml`, or
  in `AKYUU_EMBED_COMMAND` or the older `embed.env`. They are run as you.
