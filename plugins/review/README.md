# review

Quy trình soát code bằng nhiều model Claude độc lập, cho những thứ mà sai một lần là
đắt: xử lý secret, parser, guardrail.

## Nó không tự chạy gì cả

Skill này **hỏi trước mỗi lần** chạy reviewer, kèm ước lượng thời gian và chi phí.
Nó không tự spawn agent chỉ vì thấy code đáng soát. Một vòng `xhigh` trên ~1500 dòng
tốn khoảng 30 phút.

Chỉ dùng model Claude — không phụ thuộc CLI bên ngoài.

## Vì sao hai reviewer

Không phải để chắc chắn hơn, mà vì **điểm mù của reviewer này thường là phát hiện
chính của reviewer kia**. Trong lần chạy sinh ra plugin này, hai model độc lập soát
cùng một đoạn code: một bên tìm ra biến môi trường khiến scanner in credential ra
stdout, bên kia kết luận chính đường đó không thể lộ nội dung. Bên kia tìm ra lệnh
build tự khoá chết cơ chế xác thực ở lần chạy thứ hai — bên đầu không thấy.

## Dùng

```bash
# chẩn đoán một sub-agent im lặng
scripts/agent-health.sh <task-id>
scripts/agent-health.sh --list

# theo dõi liên tục, dùng chung với Monitor
scripts/agent-health.sh --watch <task-id>
```

`agent-health.sh` phân loại `WORKING` / `STALLED` / `DEAD` và nói nên làm gì. Nó
**không bao giờ in nội dung transcript** — với local agent, file `.output` là
symlink tới transcript JSONL đầy đủ, đọc vào là tràn context. Script chỉ in kích
thước, số bản ghi, loại bản ghi cuối. Có test khẳng định tính chất đó.

## Test

```bash
bash scripts/test-agent-health.sh
```

Không cần agent, không cần mạng.

## Đọc thêm

- `skills/review/SKILL.md` — vòng lặp review và những việc không được làm
- `skills/review/references/running-reviewers.md` — mẫu prompt, chọn reviewer, khi bị treo
- `skills/review/references/findings-to-tests.md` — biến input tấn công thành test
