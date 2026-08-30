# Biến finding thành test

## Nguyên tắc

Bộ test xanh chỉ chứng minh những gì nó có kiểm tra. Kích thước bộ test không nói
lên điều gì; độ phủ của **chế độ hỏng** mới nói.

Thứ tự bắt buộc: **viết test trước, xem nó fail, rồi mới sửa.** Sửa trước rồi viết
test sau thì bạn chỉ chứng minh được là code hiện tại làm điều code hiện tại làm.

## Vì sao input của reviewer là nguồn tốt nhất

Bạn viết test từ những hình dạng bạn nghĩ ra khi viết code — đó chính là tập hợp đã
bỏ sót con bug. Reviewer nghĩ ra hình dạng khác. Input tấn công của nó là thứ duy
nhất bạn có mà chắc chắn nằm ngoài trí tưởng tượng của mình.

Trong lần chạy sinh ra skill này: 38 test phân loại secret đều xanh, trong khi
`DB_PASS=hunter2` bị xếp là "config" và ghi thẳng vào file mà tài liệu bảo là commit
được — vì mọi test đều dùng giá trị mà tác giả đã nghĩ tới. Reviewer đưa `hunter2`
trong ba giây.

## Cách làm

Với mỗi finding đã tái hiện được:

1. Thêm case với **đúng input reviewer đưa**, không phải phiên bản đã dọn dẹp.
2. Chạy — phải fail. Nếu nó pass, bạn chưa hiểu bug.
3. Sửa.
4. Chạy lại — phải pass, và **mọi case cũ vẫn phải pass**.

Đặt các case này thành một nhóm có nhãn theo vòng review, để lần sau đọc lại biết
chúng từ đâu ra:

```bash
echo "VÒNG 3: wildcard allowlist đã bỏ — chỉ tên khớp chính xác mới thành config"
t PUBLIC_PASSCODE     '1234'   secret
t NEXT_PUBLIC_PINCODE '1234'   secret
```

## Chạy test đúng môi trường production

Test chạy trong shell khác với lúc chạy thật thì nó kiểm tra một chương trình khác.
Cụ thể với bash: một hàm chạy ngon lúc test nhưng chết dưới `set -euo pipefail` là
chuyện thường — `grep` không khớp trả về 1, và dưới `set -e` nó giết cả hàm. Trong
lần chạy nói trên, đúng lỗi đó khiến một scanner âm thầm chỉ thử một pattern trong
mười một, mà test vẫn xanh vì test không bật `set -e`.

Cũng chú ý phiên bản: macOS ship bash 3.2, không có `${v,,}` hay associative array.
Test dưới `/bin/bash`, đừng dưới bash 5 của Homebrew.

## Ba lớp bug hay lọt qua test tự viết

Đáng thêm case riêng cho từng lớp, vì chúng đều thuộc dạng "chạy được, làm sai việc":

**Phần tử cuối bị mất.** `printf '%s'` không có newline cuối → vòng `while read` bỏ
token cuối, mà token cuối thường là thứ quan trọng nhất (tên file, biến cuối). Luôn
có một case đặt thứ cần bắt ở vị trí **cuối cùng**.

**Trường rỗng làm lệch cột.** Tab là ký tự whitespace của IFS, nên `read` gộp hai tab
liền nhau — một trường rỗng ở giữa đẩy mọi trường sau sang trái. Dùng ký tự thay thế
(`-`) cho trường rỗng, và test số lượng bản ghi parse được.

**Biến môi trường đổi hành vi công cụ.** `GREP_OPTIONS`, `LC_ALL`, `IFS`, `PATH` đều
có thể làm một pipeline đúng thành sai. Nếu code phụ thuộc định dạng output của một
công cụ, hãy ép cờ tường minh (`grep -H`) **và** test dưới biến môi trường đối
nghịch.
