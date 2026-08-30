---
name: review
description: Chạy review đối kháng bằng nhiều model Claude độc lập, tái hiện từng finding trước khi tin, và biến input tấn công của reviewer thành test case. Dùng khi cần soát kỹ code quan trọng (bảo mật, xử lý secret, parser, guardrail), khi một reviewer vừa trả kết quả, hoặc khi một sub-agent im lặng và cần biết nó còn sống không.
---

# Review đối kháng

Quy trình soát code bằng model khác, cho những thứ mà sai một lần là đắt: xử lý
secret, parser, guardrail, bất cứ thứ gì có thể im lặng làm sai việc.

## Luật cứng: không tự ý chạy reviewer

Một vòng review `xhigh` trên ~1500 dòng tốn khoảng 30 phút và một phần đáng kể
quota. **Luôn hỏi trước khi spawn**, và hỏi cả effort lẫn phạm vi. Không bao giờ
khởi chạy reviewer chỉ vì thấy code có vẻ đáng soát.

Khi hỏi, đưa ước lượng thật: thời gian, số reviewer, và việc nó tiêu quota theo
*kích thước context nhân số vòng lặp*, không theo độ dài báo cáo.

## Vòng lặp

1. **Chốt phạm vi với người dùng.** Hẹp hơn bạn nghĩ. Ba agent 8 phút cho kết quả
   sớm hơn và giới hạn thiệt hại tốt hơn một agent 28 phút.
2. **Chạy hai reviewer độc lập** — khác model, hoặc khác effort. Không chia sẻ
   context, không cho bên này thấy kết quả bên kia. Xem `references/running-reviewers.md`.
3. **Tái hiện từng finding trước khi tin.** Đây là bước không được bỏ. Reviewer tự
   tin vẫn có thể sai.
4. **Trình bày nguyên văn**, rồi mới tới đánh giá của bạn ở mục tách riêng. Nén
   phán quyết của reviewer vào tóm tắt của mình là phá huỷ lý do đi hỏi.
5. **Người dùng quyết sửa gì.** Kể cả khi họ đã nói "review rồi sửa luôn" — một
   review làm lộ vấn đề mới thì lời cho phép cũ không còn phủ hết.
6. **Viết test từ chính input tấn công**, xem nó fail, rồi mới sửa. Xem
   `references/findings-to-tests.md`.
7. **Review lại** nếu đã sửa nhiều. Mỗi vòng ở đây đều tìm ra thứ vòng trước bỏ sót.

## Vì sao phải hai reviewer

Không phải để chắc chắn hơn. Là vì **điểm mù của reviewer này thường là phát hiện
chính của reviewer kia**. Trong lần chạy sinh ra skill này: một bên tìm ra biến môi
trường `GREP_OPTIONS=-h` khiến scanner in credential ra stdout, trong khi bên kia
kết luận chính đường đó "không thể lộ nội dung". Bên kia tìm ra lệnh build tự khoá
chết cơ chế xác thực của nó ở lần chạy thứ hai — bên đầu không thấy.

Nếu chỉ chạy được một, hãy nói rõ với người dùng rằng đó là một góc nhìn, không phải
một kết luận.

## Việc không được làm

- **Đừng tin finding chưa tái hiện.** Chạy lại. Ghi rõ cái nào tái hiện được, cái nào
  không — trong lần chạy nói trên có một finding về ký tự Unicode không tái hiện được.
- **Đừng nén báo cáo của reviewer** thành tóm tắt của mình rồi bắt tay sửa.
- **Đừng báo con số token mà agent tự trả về** như là chi phí — đó là kích thước
  context ở lượt cuối, không phải tổng tiêu thụ. Sai hai bậc độ lớn.
- **Đừng `Read` file `.output` của local agent** — nó là transcript JSONL đầy đủ,
  đọc vào là tràn context. Dùng `scripts/agent-health.sh`.

## Khi sub-agent im lặng

Im lặng có ba nghĩa, cần ba cách xử lý ngược nhau. Đừng chờ thêm — chẩn đoán:

```bash
scripts/agent-health.sh <task-id>
```

| Kết quả | Nghĩa | Làm gì |
|---|---|---|
| `WORKING` | File vẫn lớn lên | Chờ |
| `STALLED?` | Đứng yên vài phút, còn tiến trình claude | `SendMessage` giục — thường xong việc rồi mà kẹt ở tin nhắn cuối |
| `DEAD` | Không còn tiến trình nào | `TaskStop` rồi chạy lại |
| `DONE` | Có dòng exit trong output | Đọc kết quả, đừng giục |
| `IDLE` | Im lặng rất lâu (mặc định >30 phút) | Gần như chắc đã xong — xem kết quả agent trước, đừng giục |

Dấu `?` trong `STALLED?` là cố ý: không map được task id sang pid, nên "còn tiến
trình claude" chỉ nói *có thứ gì đó* đang chạy, không nói task này còn sống. Quá
ngưỡng `IDLE` thì tín hiệu đó vô nghĩa và script ngừng dựa vào nó.

Harness tự báo khi task **xong**, nên đừng poll bằng vòng `sleep`. Nó **không** báo
khi task *im lặng* — đó là khoảng trống, lấp bằng `Monitor` phát sự kiện khi
transcript ngừng lớn.

## Viết prompt cho reviewer

Mỗi prompt bắt buộc có ba thứ, nếu không nó sẽ chạy tới khi bạn phải giục:

- **Điều kiện dừng**: "sau tối đa N tool call, dừng và báo cáo những gì đã có; vùng
  nào chưa tới thì ghi một dòng".
- **Ghi kết quả dần ra file**, không dồn hết vào tin nhắn cuối. Mất một tin nhắn
  không được làm mất 30 phút công.
- **Danh sách lệnh cấm chạy**, kèm lý do — bất cứ thứ gì chờ prompt UI (Touch ID,
  sudo, xác nhận tương tác) sẽ treo vô hạn.

Mẫu đầy đủ trong `references/running-reviewers.md`.
