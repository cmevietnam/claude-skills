# onepassword

Truy cập secrets của project từ 1Password. Mỗi lần `opgate` chạm vào một secret,
macOS hiện sheet Touch ID và **nói rõ project nào đang xin biến nào để chạy lệnh gì**.
Không approve thì lệnh không chạy.

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
opgate list                   # project có secret gì (không hiện giá trị)
opgate run -- npm run dev     # chạy app với secrets nạp vào env
opgate copy op://Dev/x/API_KEY
opgate put myapp DB_URL       # đưa secret VÀO vault (--multiline cho PEM/JSON)
opgate audit -n 20            # gần đây đã truy cập gì
```

Yêu cầu thêm: `jq` (`brew install jq`) cho `opgate put`. `opgate doctor` kiểm tra.

Chạy lại bộ test của hook bất cứ lúc nào — không cần vault, không cần mạng:

```bash
bash plugins/onepassword/scripts/test-guards.sh
```

Xem `skills/onepassword/references/project-setup.md` để đưa một project từ `.env`
plaintext lên 1Password.

## Cho Codex và shell thường

`opgate` là shell script thuần, không phụ thuộc Claude Code:

```bash
ln -s "$(claude plugin path onepassword 2>/dev/null || echo ~/.claude/plugins/cache/hieuvo-skills/onepassword/*/)"/bin/opgate ~/.local/bin/opgate
```

Codex không có hook system, nên thêm luật vào `AGENTS.md` của project (mẫu có trong
`project-setup.md`). Touch ID gate vẫn chặn Codex — đó là lý do nó nằm ở tầng CLI.

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

Plugin cài hai `PreToolUse` hook:

- **Bash** — chặn `op read` / `op item get` / `op run` gọi trực tiếp (kể cả qua
  `bash -c`), và hỏi trước khi `cat`/`grep` một file secret plaintext.
- **Read** — hỏi trước khi tool Read mở `.env`, `*.pem`, `id_rsa`, `.netrc`… Bỏ qua
  `.env.example`, `.env.op`, `*.pub`.

Hook là lớp **chống tai nạn**, không phải sandbox. Lớp bảo vệ thật là Touch ID gate.
Chi tiết: `skills/onepassword/references/security-model.md`.

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
