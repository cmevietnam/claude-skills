# Mô hình bảo mật — bảo vệ được gì, không bảo vệ được gì

Đọc phần "không bảo vệ được gì" trước. Một cơ chế bảo mật bị hiểu sai còn tệ hơn
không có, vì nó tạo ra sự tự tin không có cơ sở.

## Phát biểu đúng về công cụ này

`opgate` là một **kiểm soát hợp tác** (cooperative control) cộng một lớp **chống tai
nạn**. Nó ràng buộc những ai gọi nó. Nó **không** phải sandbox và **không** ép buộc
được một tiến trình cố tình lách.

Lý do là bản chất, không phải do triển khai kém: 1Password ủy quyền cho `op` theo
**phiên terminal**, kéo dài khoảng mười phút và tự gia hạn mỗi lần dùng, và quyền đó
lan xuống mọi tiến trình con. Bất kỳ thứ gì chạy lệnh được với tư cách bạn đều có thể
gọi thẳng `/opt/homebrew/bin/op` và bỏ qua toàn bộ công cụ này. Ép buộc thật sự đòi
hỏi một broker mà agent không cấu hình lại, thay thế hay đi vòng được, và môi trường
đó phải chặn agent thấy `op` — đó là một kiến trúc khác, không phải một bản vá.

Vậy nên phát biểu đúng là: **mỗi lần `opgate` chạm vào secret đều cần Touch ID của
bạn.** Không phải "mọi truy cập secret trên máy này đều cần Touch ID".

## Hai vấn đề đang được giải

Hai vấn đề khác nhau, thường bị gộp làm một:

1. **Secret nằm plaintext trên đĩa.** Bất kỳ process nào, bất kỳ agent nào đọc được
   file đều lấy được. Giải bằng cách chuyển vào 1Password.
2. **Secret lọt vào context của model.** Đây là vấn đề mới mà `.env` truyền thống
   không có. Khi agent chạy `cat .env` hoặc `op read`, giá trị vào transcript và
   được gửi lên model provider, có thể bị lưu lại. Giải bằng cách secret không bao
   giờ đi qua stdout của agent.

Vấn đề 2 là lý do `opgate` không có lệnh `read`, và là lý do `op run` (tự mask
output) được chọn làm primitive chính thay vì `op read`.

## Các lớp

**Lớp 1 — Touch ID gate.** `touchid-gate` dùng LocalAuthentication với
`touchIDAuthenticationAllowableReuseDuration = 0`, nên macOS không tái dùng lần
unlock gần đây và sheet hiện mỗi lần. Không có TTL, không có cache, không có biến
môi trường nào tắt được nó. Đường dẫn tới binary được chốt cứng ở
`~/.local/share/opgate/bin/` — không đọc `XDG_DATA_HOME`, vì nếu không thì bất kỳ ai
đặt được biến môi trường đều trỏ nó sang một gate giả `exit 0`.

**Lớp 2 — masking.** `op run` thay giá trị secret bằng `<concealed by 1Password>`
trong stdout/stderr của process con. `--no-masking` không bao giờ được dùng.

**Lớp 3 — hook.** Chặn `op read` gọi trực tiếp và hỏi trước khi đọc file secret
plaintext. Chống tai nạn, không phải sandbox.

**Lớp 4 — audit log.** `~/.local/state/opgate/access.log`, chmod 600. Chỉ chứa tên
biến và reference, không chứa giá trị. Không có khoá và không chống sửa; `OPGATE_CALLER`
do người gọi đặt nên trường caller là gợi ý, không phải danh tính đã xác thực.

## Những đường đi vòng đã biết

Liệt kê ở đây thay vì để bạn tự phát hiện sau.

**Không vá được ở tầng này:**

- **Gọi thẳng `op`.** Sau khi phiên 1Password được ủy quyền, `op read op://…` chạy
  được mà không qua gate. Hook chặn được đường này trong Claude Code; Codex không có
  hook system nên không có gì chặn.
- **Lệnh con là mã tuỳ ý.** Sau khi bạn approve, `opgate run -- npm run dev` giao
  secret cho một process mà agent có thể vừa sửa `package.json` của nó. Sheet ghi
  "npm run dev", không ghi thứ thực sự sẽ chạy. **Hãy đọc lệnh trên sheet**, và
  nhớ rằng approve một lệnh nghĩa là tin lệnh đó.
- **`PATH` được tin.** Một `pbcopy` giả nhận được secret của `opgate copy`.
- **Secret trong env của process con nhìn thấy được** bởi các process khác cùng
  user. Đây là bản chất của `op run`, và [1Password nói rõ điều này](https://www.1password.dev/cli/secrets-environment-variables).
  Không phải khiếm khuyết của `opgate`, nhưng bạn nên biết.
- **Giá trị literal trong `.env.op`** không phải secret do 1Password phân giải, nên
  `op run` không che chúng. `opgate list`, `run` và `doctor` đều cảnh báo.

**Đã vá, nhưng chỉ là gờ giảm tốc:**

- **Thay gate binary.** Nó nằm trong thư mục bạn sở hữu nên bất kỳ thứ gì chạy với
  tư cách bạn đều ghi đè được. `opgate build` ghi lại sha256 và gate kiểm tra trước
  khi chạy, ghi bản ghi `TAMPER` vào audit và thoát 78 khi lệch. Đây là **bằng chứng
  can thiệp, không phải chống can thiệp** — kẻ nào ghi được binary thì cũng ghi được
  file hash. Giá trị của nó là biến một thao tác đổi-một-biến-môi-trường thành một
  hành động cố ý và để lại dấu vết.

**Đã gỡ bỏ hẳn:**

- `OPGATE_GATE=none` và fallback `sudo` — cả hai đều tắt được lớp 1 bằng một biến
  môi trường, đúng thứ cần chống. `sudo` còn tệ hơn: với cấu hình `NOPASSWD` thì
  `sudo -v` thành công im lặng, không hỏi gì.
- `OPGATE_TTL` — marker là file đoán trước được trong thư mục ghi được, nên tự tạo
  marker là bỏ qua được prompt. Khoá marker cũng không gồm lệnh hay reference, nên
  approve một `exec` là mở cho mọi `exec` khác trong cùng thư mục.

## Prompt nói gì và không nói gì

Sheet Touch ID ghi project, file `.env.op`, danh sách biến và lệnh sẽ chạy. Nó
**không** ràng buộc bằng mật mã với thao tác sau đó: file được đọc lại sau khi bạn
approve, nên một tiến trình nền có thể thay nó trong lúc bạn đang quyết định. Với
threat model ở đây (agent làm rò vô ý, không phải kẻ tấn công chủ động) thì chấp
nhận được — nhưng đừng nhầm nó với một cam kết.

`opgate exec` hiển thị **toàn bộ reference**, không chỉ tên biến, vì
`DATABASE_URL=op://Prod/admin/root` và một reference dev trông y hệt nhau nếu chỉ
hiện tên.

## Vì sao không có `opgate read`

Đây là câu hỏi sẽ quay lại. Câu trả lời: một lệnh in secret ra stdout thì *mọi* cách
dùng nó đều đẩy giá trị vào transcript. Không có cách dùng an toàn, nên không có lệnh.

| Muốn | Dùng |
|---|---|
| Chạy lệnh cần secret | `opgate run -- <cmd>` |
| Dán secret vào đâu đó bằng tay | `opgate copy <ref>` |
| Công cụ bắt buộc có file | `opgate inject -i tpl -o out` (out phải gitignored) |

Nếu có nhu cầu thứ tư thật sự, hãy thêm một lệnh chuyên biệt đưa secret tới đúng
nơi cần — đừng thêm `read`.

## `inject` — thao tác duy nhất để lại plaintext

Đó là mục đích của nó. Các chốt chặn:

- Từ chối `/dev/*` và `/proc/*` kể cả khi có `--force`, vì `-o /dev/stdout` biến một
  lệnh "ghi file" thành ghi thẳng vào transcript.
- Từ chối symlink, FIFO, socket và mọi thứ không phải file thường.
- Đường dẫn được phân giải (`..` và thư mục symlink) trước khi kiểm tra.
- Bắt buộc `git check-ignore` trừ khi `--force`.
- `umask 077` + `chmod 600`.

Những gì `git check-ignore` **không** nói: file có nằm trong Docker build context
không, có bị backup/đồng bộ cloud/đánh chỉ mục không, có bị `git add -f` không, và
`.gitignore` sau này có đổi không. Xoá file khi dùng xong.

## Nếu nghi ngờ secret đã lộ

Rotate. Không có bước nào khác đáng làm trước bước đó. Một giá trị đã vào transcript
không rút lại được, và `opgate audit` cho biết secret nào bị chạm tới lúc nào để
biết cần rotate cái gì.
