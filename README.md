# claude-skills

Claude Code plugin marketplace cá nhân — skills dùng chung cho mọi project, cài một
lần ở user scope.

## Cài

```bash
claude plugin marketplace add hieuvo/claude-skills
claude plugin install onepassword@hieuvo-skills
```

Phát triển tại chỗ, không qua marketplace:

```bash
claude --plugin-dir ./plugins/onepassword
# sau khi sửa: /reload-plugins
```

## Plugins

| Plugin                               | Làm gì                                                                                                                                                                                                           |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`onepassword`](plugins/onepassword) | Truy cập secrets từ 1Password với Touch ID gate mỗi lần dùng, và giữ giá trị secret không lọt vào transcript của model.                                                                                          |
| [`linode`](plugins/linode)           | Work with Linode inside the project's tag boundary: resources are created with the project tag, and writes to another project's resources are refused.                                                           |
| [`review`](plugins/review)           | Quy trình review đối kháng bằng nhiều model Claude độc lập, và script chẩn đoán sub-agent im lặng hay treo thật.                                                                                                 |
| [`codex`](plugins/codex)             | Run OpenAI's Codex CLI as a second opinion, and require every finding to reach the user verbatim before any code is changed.                                                                                     |
| [`k8s-local`](plugins/k8s-local)     | Run a project's whole stack on a local Kubernetes cluster: build straight into the cluster's image store, refuse any context whose name and API server address are not local, and keep the datastores throwaway. |

## Thêm một skill mới

```
plugins/<tên>/
├── .claude-plugin/plugin.json     # name, description, version
├── skills/<tên>/SKILL.md          # frontmatter: name + description
│   └── references/*.md            # chi tiết dài, load khi cần
├── hooks/hooks.json               # tuỳ chọn
├── bin/                           # tuỳ chọn; vào PATH của Bash tool khi plugin bật
└── scripts/                       # tuỳ chọn
```

Rồi thêm một entry vào `.claude-plugin/marketplace.json` và kiểm tra:

```bash
claude plugin validate ./plugins/<tên>
```

Giữ `SKILL.md` ngắn — nó nằm trong context mọi session. Chi tiết đẩy sang
`references/`, Claude tự đọc khi cần.
