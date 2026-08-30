---
name: onepassword
description: Truy cập secrets của project từ 1Password qua `opgate`, có Touch ID gate mỗi lần dùng. Dùng khi cần API key / DB URL / token để chạy lệnh, khi app lỗi vì thiếu biến môi trường, khi setup secrets cho project mới, hoặc khi thấy secret plaintext trong repo.
---

# 1Password secrets qua `opgate`

Secrets của project nằm trong 1Password, không nằm trên đĩa. Mỗi lần chạm vào một
secret sẽ hiện sheet Touch ID trên máy của người dùng — bạn không thể tự approve
thay họ, và điều đó là cố ý.

## Luật quan trọng nhất

**Không bao giờ để giá trị secret đi ra stdout.** Mọi thứ in ra terminal đều vào
transcript của cuộc hội thoại và được gửi lên model provider. Một secret đã lọt vào
đó coi như đã lộ và phải rotate — vault trở nên vô nghĩa.

Vì vậy `opgate` **không có lệnh `read`**. Secret chỉ đi tới ba nơi: env của một
process con, clipboard, hoặc một file đã được git ignore.

## Việc không được làm

- `op read …`, `op item get …`, `op run …` gọi trực tiếp → dùng `opgate` thay thế.
  Hook sẽ chặn, nhưng đừng để nó phải chặn.
- `cat .env`, `grep TOKEN .env`, đọc `.env` bằng tool Read → giá trị vào transcript.
  Cần biết project có biến gì thì `opgate list`.
- In secret ra "để kiểm tra". Muốn kiểm tra thì so sánh bên trong process con:
  `opgate run -- sh -c '[ -n "$JWT_SECRET" ] && echo present'`.
- Viết secret vào file bạn tạo, vào commit message, vào comment, vào issue.
- Thêm secret vào `.claude/settings*.json` dưới dạng allow-rule.

## Lệnh

| Lệnh | Dùng khi |
|---|---|
| `opgate list` | Xem project có secret gì. **Không hiện giá trị**, không cần Touch ID — cứ gọi thoải mái. |
| `opgate run -- <cmd>` | Lệnh chủ đạo. Chạy `<cmd>` với toàn bộ secrets nạp vào env. 1Password tự mask giá trị trong output. |
| `opgate exec VAR=op://… -- <cmd>` | Chỉ cần đúng một secret. |
| `opgate copy op://…` | Người dùng cần tự dán secret vào đâu đó. Vào clipboard, tự xoá sau 90s. |
| `opgate inject -i tpl -o out` | Công cụ bắt buộc phải có file thật. Từ chối ghi nếu `out` chưa được git ignore. |
| `opgate put <ITEM> <FIELD>` | Đưa một secret **vào** 1Password. Đọc giá trị từ stdin. Thêm `--multiline` cho PEM key / JSON nhiều dòng. |
| `opgate doctor` | Có gì đó không chạy. Kiểm tra toàn bộ setup và in cách sửa. |
| `opgate audit -n 20` | Xem gần đây đã truy cập secret nào. |

## Quy trình thường gặp

**App cần secret để chạy** — đừng đi tìm `.env`:

```bash
opgate list                  # xem có gì
opgate run -- npm run dev    # chạy; Touch ID hiện một lần lúc khởi động
```

**Một lệnh dùng đúng một secret**:

```bash
opgate exec DATABASE_URL=op://Dev/cme-api/DATABASE_URL -- \
  sh -c 'psql "$DATABASE_URL" -c "\dt"'
```

`sh -c '…'` là bắt buộc: viết `-- psql "$DATABASE_URL"` sẽ để shell **bên ngoài**
expand biến trước khi opgate kịp nạp secret, và psql nhận chuỗi rỗng.

**Thiếu một biến**: thêm dòng `VAR=op://Dev/<project>/VAR` vào `.env.op`, rồi bảo
người dùng chạy `opgate put <project> VAR` để nhập giá trị. Đừng tự hỏi họ giá trị
qua chat — nó sẽ nằm trong transcript.

**Thấy `.env` plaintext trong repo**: nói với người dùng, đề xuất chuyển sang
`.env.op`. Xem `references/project-setup.md` cho quy trình đầy đủ. Đừng tự đọc file
đó để "xem có gì".

**Lệnh trả về exit 77**: người dùng đã từ chối ở sheet Touch ID. Đó là câu trả lời
"không" — dừng lại và hỏi, đừng thử lại hay tìm đường vòng. Exit 78 nghĩa là không
hiện được prompt (hoặc gate binary bị thay đổi) — chạy `opgate doctor`.

## Quy ước lưu trữ

Vault `Dev`, mỗi project một item (Secure Note), mỗi biến môi trường một field:

```
op://Dev/<tên-project>/<TÊN_BIẾN>
```

File `.env.op` nằm trong repo và **commit được** vì chỉ chứa reference:

```
DATABASE_URL=op://Dev/cme-api/DATABASE_URL
JWT_SECRET=op://Dev/cme-api/JWT_SECRET
```

## Đọc thêm

- `references/project-setup.md` — đưa một project từ `.env` plaintext lên 1Password
- `references/secret-references.md` — cú pháp `op://`, `.env.op`, lỗi thường gặp
- `references/security-model.md` — gate bảo vệ được gì và **không** bảo vệ được gì
