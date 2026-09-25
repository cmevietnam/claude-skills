# claude-skills

A personal Claude Code plugin marketplace: skills shared across every project, installed
once at user scope.

## Install

```bash
claude plugin marketplace add cmevietnam/claude-skills
claude plugin install onepassword@hieuvo-skills
```

Local development, without going through the marketplace:

```bash
claude --plugin-dir ./plugins/onepassword
# after editing: /reload-plugins
```

## Plugins

| Plugin                               | What it does                                                                                                                                                                                                     |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`onepassword`](plugins/onepassword) | Reach secrets in 1Password behind a Touch ID gate on every use, and keep secret values out of the model's transcript.                                                                                            |
| [`linode`](plugins/linode)           | Work with Linode inside the project's tag boundary: resources are created with the project tag, and writes to another project's resources are refused.                                                           |
| [`review`](plugins/review)           | Adversarial review with several independent Claude models, plus a script that tells a quiet sub-agent from a hung one.                                                                                           |
| [`codex`](plugins/codex)             | Run OpenAI's Codex CLI as a second opinion, and require every finding to reach the user verbatim before any code is changed.                                                                                     |
| [`antigravity`](plugins/antigravity) | Run Google's Antigravity CLI (`agy`) headless as a second-opinion reviewer — and refuse to trust its exit code, which reports SUCCESS on runs whose every tool was denied and whose output is empty.             |
| [`k8s-local`](plugins/k8s-local)     | Run a project's whole stack on a local Kubernetes cluster: build straight into the cluster's image store, refuse any context whose name and API server address are not local, and keep the datastores throwaway. |

## Adding a new skill

```
plugins/<name>/
├── .claude-plugin/plugin.json     # name, description, version
├── skills/<name>/SKILL.md         # frontmatter: name + description
│   └── references/*.md            # long details, loaded on demand
├── hooks/hooks.json               # optional
├── bin/                           # optional; on the Bash tool PATH while the plugin is on
└── scripts/                       # optional
```

Then add an entry to `.claude-plugin/marketplace.json` and validate:

```bash
claude plugin validate ./plugins/<name>
```

Keep `SKILL.md` short: it sits in the context of every session. Push details into
`references/`, which Claude reads when it needs them.
