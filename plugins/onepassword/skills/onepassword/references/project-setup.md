# Đưa một project lên 1Password

Làm một lần cho mỗi project. `opgate scan` và `opgate import` lo phần cơ học, còn
hai quyết định vẫn là của bạn và không tự động hoá được: biến nào thật sự là bí mật,
và secret nào nên **rotate** thay vì chép nguyên sang chỗ mới. Bất cứ giá trị nào
từng nằm trong git, trong log, hay trong một settings file thì coi như đã lộ.

## 0. Chuẩn bị một lần cho cả máy

```bash
op vault create Dev          # nếu chưa có
opgate doctor                # phải xanh hết trước khi đi tiếp
```

## 1. Xem project có gì

```bash
opgate scan
```

Liệt kê mọi `.env`, đếm biến theo phân loại, đề xuất tên item — và báo cả secret
nằm trong file cấu hình hoặc source. Không đọc giá trị nào ra ngoài, và chạy được
cả khi 1Password đang khoá.

## 2. Import từng file

```bash
opgate import api/.env
```

Một lần Touch ID cho cả file; sheet liệt kê mọi biến sắp được ghi. Việc nó làm:

- tạo/cập nhật item `<project>-<thư mục>-<môi trường>` trong vault `Dev`, tag
  `opgate` và `project:<tên>`
- sinh file reference cạnh file gốc: `.env` → `.env.op`,
  `.env.production` → `.env.production.op`. Secret thành `op://` ref, biến không
  bí mật giữ nguyên literal (được quote khi cần)
- **không** xoá và **không** sao lưu bản gốc. Bản gốc vẫn nằm đó, nên một bản sao
  plaintext thứ hai chỉ nới rộng vùng lộ. Cần thì `--backup`, rồi tự xoá.

Nó dừng lại thay vì ghi đè khi: item đã tồn tại nhưng không do opgate tạo, hai file
khác nhau cùng suy ra một tên item, hoặc file `.op` đích đang được sinh từ nguồn
khác. `--force` bỏ qua các chốt đó.

Biến nó không chắc thì nó hỏi, và câu hỏi chỉ mô tả hình dạng giá trị chứ không in
giá trị. Không có terminal thì nó dừng thay vì đoán — `--yes` để đưa hết những ca
mơ hồ vào vault. Chỉ tên nằm trong allowlist khớp chính xác (`NODE_ENV`, `PORT`,
`API_URL`…) mới tự động ở lại dạng literal; bạn sẽ được hỏi khá nhiều ở lần đầu.

`import` **từ chối** file mà `op run` cũng từ chối, thay vì đoán: BOM ở đầu, dấu
nháy không đóng, byte NUL. Nó cũng từ chối giá trị chứa `$VAR` ngoài nháy đơn —
`op run` sẽ expand nó còn vault thì không, nên import sẽ đổi nghĩa giá trị. Bọc
trong nháy đơn nếu muốn giữ nguyên chữ `$`.

Xem trước mà không ghi gì: `opgate import api/.env --dry-run`.

Với secret cần rotate (key đã từng nằm trong git, trong settings file, trong log):
**tạo key mới ở nhà cung cấp trước**, sửa `.env`, rồi mới import.

### Thêm một biến lẻ về sau

```bash
opgate put cme-api NEW_TOKEN                    # prompt ẩn
opgate put cme-api GOOGLE_SA_JSON --multiline < service-account.json
```

Rồi thêm dòng `NEW_TOKEN=op://Dev/cme-api/NEW_TOKEN` vào `.env.op`.

## 3. Kiểm tra `.env.op`

`import` đã sinh file này cạnh file gốc. Nó commit được — secret là `op://` ref,
biến không bí mật giữ nguyên literal:

```
NODE_ENV=development
DATABASE_URL=op://Dev/cme-api/DATABASE_URL
JWT_SECRET=op://Dev/cme-api/JWT_SECRET
```

Xác nhận trước khi bỏ bản gốc:

```bash
opgate list -f api/.env.op                    # tên + ref, không có giá trị
opgate run -f api/.env.op -- npm run dev      # app phải chạy được
```

`opgate list` cảnh báo nếu còn biến nào mang tên kiểu secret mà vẫn là literal —
đó là dấu hiệu phân loại sai, và là thứ duy nhất có thể biến `.env.op` từ file
commit được thành file rò rỉ.

## 4. Dọn plaintext

`import` giữ nguyên bản gốc. Sau khi chắc chắn app chạy được bằng file `.op`:

```bash
git check-ignore .env || echo ".env" >> .gitignore
rm api/.env
```

Đừng xoá sớm. Nếu sót một biến mà không còn bản gốc thì không có đường quay lại —
đó là lý do `import` giữ nguyên file thay vì tự dọn.

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
