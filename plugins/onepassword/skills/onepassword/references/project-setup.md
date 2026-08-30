# Đưa một project lên 1Password

Làm một lần cho mỗi project. Quy trình này cố ý **không** tự động hoá bằng script:
mỗi secret cần một quyết định của con người về việc nó có nên tồn tại hay không,
và một số trong đó nên được rotate thay vì chép nguyên sang chỗ mới.

## 0. Chuẩn bị một lần cho cả máy

```bash
op vault create Dev          # nếu chưa có
opgate doctor                # phải xanh hết trước khi đi tiếp
```

## 1. Liệt kê các biến cần có

Lấy **tên biến** từ `.env.example` nếu có — không cần mở `.env` thật:

```bash
grep -oE '^[A-Za-z_][A-Za-z0-9_]*' .env.example | sort -u
```

Nếu không có `.env.example`, lấy tên biến từ code (`process.env.X`, `os.Getenv("X")`,
`os.environ["X"]`) thay vì đọc `.env`.

## 2. Đưa từng giá trị vào vault

Người dùng tự chạy, giá trị đi qua stdin nên không nằm trong shell history hay argv:

```bash
opgate put cme-api DATABASE_URL     # nhập giá trị ở prompt ẩn
opgate put cme-api JWT_SECRET
```

Từ một `.env` có sẵn, vẫn nên làm từng dòng một cách có ý thức:

```bash
# đọc tên biến, nhập lại giá trị bằng tay
awk -F= '/^[A-Za-z_]/ {print $1}' .env | while read -r v; do
  printf 'Nhập giá trị cho %s: ' "$v"
  opgate put cme-api "$v"
done
```

Với secret cần rotate (key đã từng nằm trong git, trong settings file, trong log):
**tạo key mới ở nhà cung cấp trước**, rồi mới `opgate put` giá trị mới.

## 3. Tạo `.env.op`

File này commit được — nó chỉ chứa reference, không chứa giá trị:

```
DATABASE_URL=op://Dev/cme-api/DATABASE_URL
JWT_SECRET=op://Dev/cme-api/JWT_SECRET
REDIS_URL=op://Dev/cme-api/REDIS_URL
```

Kiểm tra:

```bash
opgate list                                       # tên + ref, không có giá trị
opgate run -- sh -c 'echo "${DATABASE_URL:+ok}"'  # in "ok" nếu biến tới nơi
```

## 4. Dọn plaintext

```bash
git check-ignore .env || echo ".env" >> .gitignore
mv .env ~/.local/share/opgate/backup-$(basename "$PWD")-$(date +%Y%m%d).env
chmod 600 ~/.local/share/opgate/backup-*.env
```

Giữ backup vài ngày cho tới khi chắc chắn mọi thứ chạy, rồi xoá. **Không xoá `.env`
ngay** — nếu bỏ sót một biến thì không có đường quay lại.

Nếu `.env` từng bị commit thì giá trị vẫn nằm trong lịch sử git; thêm vào
`.gitignore` không xoá nó. Những secret đó phải rotate.

## 5. Đổi cách chạy app

```diff
-npm run dev
+opgate run -- npm run dev
```

Trong `package.json`, nếu muốn `npm run dev` tự đi qua gate:

```json
{ "scripts": { "dev": "opgate run -- vite", "dev:raw": "vite" } }
```

Docker Compose và các công cụ bắt buộc có file thật:

```bash
opgate inject -i .env.op -o .env.local && docker compose up
rm .env.local
```

`.env.local` phải nằm trong `.gitignore` — `opgate inject` từ chối ghi nếu chưa.

## 6. Cho Codex

Codex không có hook system, nên luật phải nằm trong `AGENTS.md` của project:

```markdown
## Secrets

Secrets nằm trong 1Password, không có trên đĩa. Chạy app bằng `opgate run -- <cmd>`.
Không đọc `.env`, không gọi `op` trực tiếp, không in giá trị secret ra stdout.
`opgate list` cho biết project có biến gì mà không lộ giá trị.
```

Touch ID gate vẫn chặn Codex như chặn Claude — nó nằm ở tầng CLI chứ không ở tầng hook.
