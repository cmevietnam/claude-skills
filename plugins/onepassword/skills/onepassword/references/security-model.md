# Mô hình bảo mật — bảo vệ được gì, không bảo vệ được gì

Đọc phần "không bảo vệ được gì" trước. Một cơ chế bảo mật bị hiểu sai còn tệ hơn
không có, vì nó tạo ra sự tự tin không có cơ sở.

## Vấn đề thật sự đang giải

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

**Lớp 1 — Touch ID gate (lớp thật).** `touchid-gate` dùng LocalAuthentication với
`touchIDAuthenticationAllowableReuseDuration = 0`, nên macOS không tái dùng lần
unlock gần đây và sheet hiện mỗi lần. Lớp này nằm ở tầng CLI nên nó chặn Claude,
Codex, script, và cả bạn gõ tay như nhau. Không agent nào tự approve thay bạn được.

**Lớp 2 — masking.** `op run` thay giá trị secret bằng `<concealed by 1Password>`
trong stdout/stderr của process con. Nghĩa là ngay cả khi app in secret ra log,
giá trị vẫn không tới transcript. `--no-masking` không bao giờ được dùng.

**Lớp 3 — hook (lớp chống tai nạn).** Chặn `op read` gọi trực tiếp và hỏi trước khi
đọc file secret plaintext. Xem giới hạn bên dưới.

**Lớp 4 — audit log.** `~/.local/state/opgate/access.log`, chmod 600, ghi ai xin gì
lúc nào và bạn trả lời sao. Chỉ chứa tên biến và reference, không chứa giá trị.

## Không bảo vệ được gì

- **Hook không phải sandbox.** Nó khớp mẫu trên chuỗi lệnh. Một agent cố tình lách
  vẫn lách được — mã hoá base64, ghi script rồi chạy, dùng ngôn ngữ khác. Giá trị
  của hook là chặn sai lầm *thường gặp*, không phải chống đối thủ.
- **Sau khi bạn approve, secret nằm trong env của process con.** Process đó làm gì
  với secret là chuyện của nó. `opgate run -- <cmd>` với `<cmd>` do agent soạn nghĩa
  là bạn đang tin `<cmd>`. **Hãy đọc lệnh trên sheet Touch ID** — đó chính là lý do
  nó được ghi ở đó.
- **Không giới hạn phạm vi.** Approve một lần cho `opgate run` là mở toàn bộ biến
  trong `.env.op` đó, không phải một biến. Muốn hẹp hơn thì `opgate exec`.
- **`opgate inject` để lại plaintext trên đĩa.** Đó là mục đích của nó. File được
  chmod 600 và bắt buộc phải git-ignored, nhưng nó vẫn là một file thật cho tới khi
  bạn xoá.
- **Không bảo vệ được nếu 1Password đang unlock và ai đó ngồi trước máy bạn.**
- **`OPGATE_GATE=none` tắt toàn bộ lớp 1.** Nó tồn tại cho CI. Trên máy cá nhân,
  `opgate doctor` báo đỏ nếu thấy nó được bật.

## Vì sao không có `opgate read`

Đây là câu hỏi sẽ quay lại. Câu trả lời: một lệnh in secret ra stdout thì *mọi* cách
dùng nó đều đẩy giá trị vào transcript. Không có cách dùng an toàn, nên không có lệnh.

Ba nhu cầu mà người ta định dùng `read` để giải, và cách giải đúng:

| Muốn | Dùng |
|---|---|
| Chạy lệnh cần secret | `opgate run -- <cmd>` |
| Dán secret vào đâu đó bằng tay | `opgate copy <ref>` |
| Công cụ bắt buộc có file | `opgate inject -i tpl -o out` (out phải gitignored) |

Nếu có nhu cầu thứ tư thật sự, hãy thêm một lệnh chuyên biệt đưa secret tới đúng
nơi cần — đừng thêm `read`.

## Đánh đổi của `OPGATE_TTL`

Mặc định `0`: hỏi mỗi lần. Đặt `OPGATE_TTL=300` sẽ tái dùng approval trong 5 phút
cho cùng một (thư mục, hành động) — đỡ mỏi tay khi chạy lệnh liên tiếp, đổi lại tạo
ra cửa sổ 5 phút mà agent lấy được secret không cần hỏi. `opgate doctor` cảnh báo
vàng khi TTL > 0. Đừng đặt nó chỉ vì thấy phiền; hãy đặt khi bạn hiểu cửa sổ đó.

## Nếu nghi ngờ secret đã lộ

Rotate. Không có bước nào khác đáng làm trước bước đó. Một giá trị đã vào transcript
không rút lại được, và `opgate audit` cho biết secret nào bị chạm tới lúc nào để
biết cần rotate cái gì.
