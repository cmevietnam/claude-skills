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

| Plugin | Làm gì |
|---|---|
| [`onepassword`](plugins/onepassword) | Truy cập secrets từ 1Password với Touch ID gate mỗi lần dùng, và giữ giá trị secret không lọt vào transcript của model. |
| [`linode`](plugins/linode) | Làm việc với Linode trong ranh giới tag của project: resource tạo ra luôn mang tag project, và mọi thao tác ghi lên resource của project khác đều bị chặn. |

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
