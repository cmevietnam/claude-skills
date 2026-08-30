# onepassword

Truy cập secrets của project từ 1Password. Mỗi lần `opgate` đọc hoặc ghi **vault**,
macOS hiện sheet Touch ID và nói rõ project nào đang xin biến nào để chạy lệnh gì.
Không approve thì lệnh không chạy.

Nói chính xác: gate bảo vệ việc **đọc hoặc ghi giá trị secret trong vault**. Những
thứ không qua gate, cố ý:

- `scan`, `import --dry-run`: đọc file `.env` plaintext trên đĩa. File đó vốn nằm
  sẵn và `cat` cũng đọc được; chặn ở đây không thêm gì. Chúng không **in** giá trị.
- `scan`, `items`, `doctor`, và bước kiểm tra trước khi `import`/`put` hỏi vân tay:
  đọc **metadata** vault (tên item, category, tag) qua `op item list` — không có
  giá trị field nào trong đó. `import` còn đọc riêng field `opgate_source` (một
  đường dẫn) để phát hiện hai file trùng tên item. Toàn bộ giá trị secret chỉ được
  đọc **sau** khi bạn approve.

Ngoài ra `op run` tự resolve mọi biến `op://` đã có sẵn trong môi trường (ví dụ
`export GITHUB_TOKEN=op://…` trong `.zshrc`). `opgate run`/`exec` liệt kê chúng
trên sheet dưới nhãn "từ môi trường" để bạn biết chúng cũng được resolve.

**Phạm vi, nói thẳng:** đây là *kiểm soát hợp tác* cộng lớp chống tai nạn, không phải
sandbox. Nó ràng buộc những ai gọi `opgate`. 1Password ủy quyền cho `op` theo phiên
terminal (khoảng 10 phút, tự gia hạn, lan xuống tiến trình con), nên bất kỳ thứ gì
chạy lệnh được với tư cách bạn đều có thể gọi thẳng `op` và bỏ qua công cụ này. Ép
buộc thật cần một broker mà agent không thấy được `op` — kiến trúc khác, không phải
bản vá. Danh sách đầy đủ các đường đi vòng đã biết nằm trong
`skills/onepassword/references/security-model.md`; đọc nó trước khi tin vào công cụ.

## Vì sao cần thêm một lớp nữa

1Password desktop app integration uỷ quyền cho `op` **theo phiên terminal**: sau lần
Touch ID đầu tiên, mọi lệnh `op` sau đó trong cùng phiên đều đi lọt. Với một người
ngồi gõ thì hợp lý; với một agent chạy hàng trăm lệnh thì không. `opgate` tự dựng
lớp xác thực riêng, đặt ở tầng CLI — nghĩa là Claude, Codex và script đều phải qua nó
*khi chúng dùng `opgate`*. Không có gì buộc chúng dùng; xem phần phạm vi ở trên.

Vấn đề thứ hai, riêng của thời agent: nếu agent chạy `op read` thì giá trị secret in
ra stdout → vào transcript → gửi lên model provider. Vì vậy `opgate` **không có lệnh
`read`**, và dùng `op run` (tự che giá trị trong output) làm primitive chính.

## Cài

```bash
claude plugin marketplace add hieuvo/claude-skills
claude plugin install onepassword@hieuvo-skills
```

Chuẩn bị một lần:

```bash
op vault create Dev     # nơi để secrets của project
opgate build            # compile Touch ID gate (cần Xcode CLT)
opgate doctor           # phải xanh hết
```

Yêu cầu: macOS có Touch ID, 1Password 8 với **Settings ▸ Developer ▸ Integrate with
1Password CLI** đã bật, `op` CLI, Xcode command line tools.

## Dùng

```bash
opgate scan                   # tìm .env + secret nhúng trong cả project
opgate import api/.env        # đưa một file vào vault, sinh .env.op
opgate items -p cme           # xem project có những item nào trong vault
opgate list                   # project có secret gì (không hiện giá trị)
opgate run -- npm run dev     # chạy app với secrets nạp vào env
opgate copy op://Dev/x/API_KEY
opgate put myapp DB_URL       # đưa secret VÀO vault (--multiline cho PEM/JSON)
opgate audit -n 20            # gần đây đã truy cập gì
```

Yêu cầu thêm: `jq` (`brew install jq`) cho `opgate put` và `opgate import`.
`opgate doctor` kiểm tra.

Bốn bộ test, không cần vân tay. Ba bộ đầu không cần vault; `test-parser.sh` có
thêm phần **đối chiếu trực tiếp với `op run`** — chạy khi 1Password đang mở, tự bỏ
qua khi khoá:

```bash
bash plugins/onepassword/scripts/test-guards.sh    # ba PreToolUse hook
bash plugins/onepassword/scripts/test-classify.sh  # phân loại secret / config
bash plugins/onepassword/scripts/test-scan.sh      # quét + đặt tên item
bash plugins/onepassword/scripts/test-parser.sh    # parser dotenv vs op run
```

## Đưa một project lên vault

```bash
opgate scan                    # xem có gì, không đọc giá trị ra ngoài
opgate import api/.env         # một lần Touch ID cho cả file
opgate run -f api/.env.op -- npm run dev
```

`import` tạo item `<project>-<thư mục>-<môi trường>` (ví dụ `cme-api`,
`cme-web-production`) mang tag `opgate` và `project:<tên>`, rồi sinh file reference
cạnh file gốc: `.env` → `.env.op`, `.env.production` → `.env.production.op`. Nó
**không xoá và không sao lưu** bản gốc — bản gốc vẫn nằm đó, nên một bản sao
plaintext thứ hai chỉ nới rộng vùng lộ chứ không thêm an toàn. Cần bản sao thì
`--backup`, và nhớ tự xoá.

`import` từ chối ghi đè khi item đã tồn tại nhưng không do opgate tạo (thiếu tag
`opgate`), khi hai file khác nhau cùng suy ra một tên item, và khi file `.op` đích
đang được sinh từ nguồn khác. `--force` bỏ qua các chốt đó.

Chỉ biến có **tên nằm trong một allowlist khớp chính xác** (`NODE_ENV`, `PORT`,
`LOG_LEVEL`, `API_URL`…) mới ở lại file `.op` dạng literal. Không có wildcard, và
không có quy tắc nào xét *giá trị* để hạ một biến xuống literal — ba vòng review
liên tiếp đã phá ba phiên bản có quy tắc như vậy (`DB_PASS=hunter2` từng thành
"config", `PUBLIC_PASSCODE` từng khớp `PUBLIC_*`). Mọi biến khác mà không nhận ra
là secret thì `import` **hỏi bạn**, và câu hỏi chỉ mô tả hình dạng giá trị —
`30 ký tự · thường/HOA/ký hiệu` — chứ không in giá trị. Không có terminal thì nó
dừng thay vì đoán, trừ khi bạn thêm `--yes` (đưa hết vào vault). Bạn sẽ được hỏi
nhiều hơn; đó là cái giá của việc file `.op` thật sự commit được.

`opgate scan` cũng báo secret nằm **trong file cấu hình hoặc source** (AWS key trong
một `settings.local.json`, JWT trong một file JSON). Nó chỉ báo `file:dòng` và loại
credential, không in giá trị, và không tự sửa — sửa những chỗ đó cần đổi code, và
nếu là credential thật thì việc đầu tiên là rotate.

Xem `skills/onepassword/references/project-setup.md` để đưa một project từ `.env`
plaintext lên 1Password.

## Cho Codex và shell thường

`opgate` là shell script thuần, không phụ thuộc Claude Code:

```bash
ln -s "$(claude plugin path onepassword 2>/dev/null || echo ~/.claude/plugins/cache/hieuvo-skills/onepassword/*/)"/bin/opgate ~/.local/bin/opgate
```

Codex không có hook system, nên thêm luật vào `AGENTS.md` của project (mẫu có trong
`project-setup.md`). Touch ID gate chặn Codex **khi Codex dùng `opgate`** — nó nằm ở
tầng CLI nên không phân biệt ai gọi. Nhưng Codex gọi thẳng `op` thì không có gì chặn,
y như với bất kỳ tiến trình nào chạy dưới tài khoản của bạn. Xem phần phạm vi ở đầu
file và `references/security-model.md`.

## Cấu hình

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `OPGATE_VAULT` | `Dev` | Vault chứa secrets project |
| `OPGATE_ENV_FILE` | `.env.op` | Tên file secret reference mặc định |
| `OPGATE_ALLOW_PASSWORD` | tắt | Đặt `1` để chấp nhận mật khẩu máy thay vân tay |

Không có biến nào tắt hay nới lỏng được gate. Phiên bản trước có `OPGATE_GATE=none`
và `OPGATE_TTL`; cả hai đều bỏ qua được prompt chỉ bằng một biến môi trường, nên đã
bị gỡ.

## Hook

Plugin cài ba `PreToolUse` hook và một `PostToolUse` hook:

- **Bash** — chặn `op read` / `op item get` / `op run` / `--reveal` / `--raw` /
  `op item share` / `op service-account create` / `op connect token create` gọi
  trực tiếp (kể cả qua `bash -c`), và hỏi trước khi `cat`/`grep`/`sort`/`diff`/
  `cp`/`source` một file secret plaintext.
- **Read** — hỏi trước khi tool Read mở `.env`, `.envrc`, `*.pem`, `id_rsa`,
  `.netrc`, `.git-credentials`… Bỏ qua `.env.example`, `.env.op`, `*.pub`.
- **Grep** — hỏi khi Grep trỏ thẳng vào một file secret. Grep cả thư mục thì
  **không** bị hỏi (quá ồn), và nó vẫn đọc được `.env` bên trong — xem
  `security-model.md`.

- **PostToolUse (Bash|Read|Grep)** — khi bạn approve một prompt ở trên, hook này
  ghi lại quyết định đó thành một **cửa sổ 60 phút cho đúng file đó**, để lần sau
  không hỏi lại. Nó không tự phân loại gì cả: PreToolUse hook đã ghi sẵn key vào
  `pending/<tool_use_id>`, việc duy nhất ở đây là chuyển nó thành grant.

Hook là lớp **chống tai nạn**, không phải sandbox. Lớp bảo vệ thật là Touch ID gate.
Chi tiết: `skills/onepassword/references/security-model.md`.

## Cửa sổ approve (`unlock` / `grants` / `lock`)

```bash
opgate grants                          # đang mở cửa sổ nào, còn bao lâu
opgate unlock --minutes 60 .env        # mở trước, một lần Touch ID
opgate lock                            # đóng tất cả ngay
opgate lock .env                       # đóng đúng một file
```

Chỉ tác động tới lớp hook. Không bỏ qua được Touch ID, không chạm tới vault, và
không biến `deny` thành `allow` — gọi `op` trực tiếp vẫn bị chặn như cũ. Cửa sổ tính
theo **đường dẫn đã resolve**, nên approve `.env` không mở `.env.production`, và một
lệnh đọc hai file secret thì cần cả hai cửa sổ.

`opgate doctor` cảnh báo nếu còn cửa sổ nào đang mở. Vì sao chuyện này khác với
`OPGATE_TTL` đã bị gỡ: xem `security-model.md`.

## Có thể gặp hai prompt liên tiếp

Phiên uỷ quyền của 1Password hết hạn khá nhanh. Khi đó một lệnh `opgate` sẽ hiện
**hai** hộp thoại: sheet Touch ID của `opgate` (nói rõ project + biến + lệnh), rồi
prompt riêng của 1Password để mở lại phiên CLI. Đó là hai lớp khác nhau, không phải
lỗi. Nếu `op` báo `authorization timeout` thì unlock lại app 1Password.

Sheet Touch ID hiện mỗi lần, không tái dùng lần unlock trước — đã kiểm chứng bằng
`touchIDAuthenticationAllowableReuseDuration = 0`. Nếu hai sheet xuất hiện cách nhau
vài giây, dễ chạm nhầm; đọc dòng mô tả trên sheet trước khi chạm.

## Exit codes

| Code | Nghĩa |
|---|---|
| `77` | Bạn từ chối ở sheet Touch ID — lệnh không chạy |
| `78` | Không hiện được prompt, hoặc gate binary khác hash đã ghi lúc build → `opgate doctor` |

## Nhật ký

`~/.local/state/opgate/access.log` (chmod 600), tab-separated:
`thời gian · trạng thái · caller · project · hành động · tên biến`. Không chứa giá trị.

Trạng thái liên quan tới cửa sổ approve: `GRANT` (mở, hành động là `unlock` hoặc
`auto`), `GRANT-USED` (một lần hook cho qua nhờ cửa sổ), `GRANT-REVOKED`. Một grant
tồn tại mà không có bản ghi `GRANT` tương ứng là dấu hiệu có người tự tạo file —
đây là **bằng chứng**, không phải cơ chế chặn.
