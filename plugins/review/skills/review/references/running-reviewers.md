# Chạy reviewer

## Trước tiên: hỏi

Không spawn reviewer mà chưa hỏi. Đưa ước lượng thật, không nói chung chung:

> Review `plugins/foo` (~1500 dòng) bằng hai model độc lập. Mức `xhigh` mất khoảng
> 30 phút mỗi bên. Chi phí đi theo kích thước context nhân số vòng lặp — reviewer
> đọc lại toàn bộ ngữ cảnh ở mỗi tool call, nên phạm vi hẹp rẻ hơn nhiều so với
> báo cáo ngắn. Chạy chứ?

Hỏi cả **effort** và **phạm vi**. Người dùng thường muốn hẹp hơn bạn định.

## Chọn hai reviewer

Mục tiêu là hai **góc nhìn khác nhau**, không phải hai lần cùng một góc nhìn:

| Cách tách | Khi nào |
|---|---|
| Khác model (`fable` vs mặc định) | Tốt nhất — điểm mù khác nhau thật sự |
| Cùng model, khác effort | Khi chỉ có một model; `max` vs `high` |
| Cùng model, khác trọng tâm prompt | Yếu nhất; chỉ dùng khi không còn cách nào |

Chạy **tuần tự**, không song song. Chạy song song thì bạn không thấy chi phí vòng
một trước khi mở vòng hai — và nếu vòng một đã đủ, vòng hai là lãng phí.

Không cho reviewer thứ hai xem kết quả của reviewer thứ nhất. Cả giá trị nằm ở chỗ
nó đi tới kết luận độc lập.

## Mẫu prompt

Ba phần in đậm là bắt buộc; thiếu chúng là lý do agent chạy tới khi bạn phải giục.

```
Review <phạm vi cụ thể> tại <commit>. Bỏ qua <những gì không thuộc phạm vi>.
Không sửa file nào.

<Mô tả hệ thống làm gì và hai ba mục tiêu thiết kế, kèm câu "hãy đánh giá phê phán
chứ đừng mặc nhiên chấp nhận">

<Nếu đã có vòng review trước: liệt kê những gì bên kia tìm ra và nói rõ "đừng cho
rằng các bản vá đó đúng — hãy kiểm chứng, và tìm xem chính chúng làm hỏng gì">

Ưu tiên theo thứ tự:
A. <vùng rủi ro cao nhất, thường là code mới nhất>
B. ...

**Điều kiện dừng: sau tối đa N tool call, dừng điều tra và viết báo cáo với những
gì đã có. Vùng nào chưa tới thì ghi một dòng, đừng đào tiếp.**

**Ghi phát hiện dần vào <file> ngay khi tìm ra, đừng dồn hết vào tin nhắn cuối.**

**Không chạy: <các lệnh chờ prompt UI — Touch ID, sudo, xác nhận tương tác>.
Chúng treo vô hạn.**

Với mỗi finding: file:dòng, cái gì hỏng, input tái hiện cụ thể, và **đã tái hiện
thật hay chỉ suy luận**. Xếp theo mức nghiêm trọng. Cái gì ổn thì nói ngắn gọn là
ổn — đừng độn.
```

Yêu cầu "đã tái hiện thật hay chỉ suy luận" đáng giá hơn vẻ ngoài: nó tách phát
hiện chắc chắn khỏi phỏng đoán, và cho bạn biết cái nào cần kiểm lại trước.

## Trong lúc chạy

Đừng poll bằng vòng `sleep` — harness tự báo khi xong. Nó không báo khi agent *im
lặng*; dùng `scripts/agent-health.sh` khi bạn nghi ngờ, hoặc `Monitor` với
`agent-health.sh --watch <id>` để được báo khi trạng thái đổi.

Nếu phải giục: một `SendMessage` yêu cầu "dừng điều tra và viết báo cáo ngay bây
giờ với những gì đã có". Biết rằng việc này có thể khiến nó **viết lại toàn bộ báo
cáo** — trong lần chạy sinh ra skill này, một cú giục làm reviewer chạy lại gần như
gấp đôi số request.

## Sau khi có kết quả

1. **Tái hiện từng finding.** Chạy đúng input reviewer đưa. Ghi lại cái nào đúng,
   cái nào không.
2. **Trình bày nguyên văn** — kể cả finding bạn không đồng ý, coi là ngoài phạm vi,
   hay đã biết. Chỉnh sửa duy nhất được phép: rút gọn đường dẫn tuyệt đối thành
   `file:dòng`, và sửa xuống dòng. Nói rõ là đã chỉnh.
3. **Ý kiến của bạn ở mục riêng**, sau đó, có nhãn rõ ràng.
4. **Dừng lại chờ người dùng quyết.** Kể cả khi trước đó họ đã nói "review xong thì
   sửa luôn" — họ cho phép sửa những vấn đề họ đã biết, không phải những vấn đề
   reviewer vừa tìm ra.

## Khi báo cáo cuối bị mất

Nếu reviewer chạy xong mà không phát ra gì: đừng chạy lại từ đầu. Với sub-agent,
`SendMessage` yêu cầu nó viết lại báo cáo — transcript vẫn còn, nó không phải điều
tra lại. Đó cũng là lý do phần "ghi dần ra file" nằm trong prompt: nó biến việc mất
tin nhắn cuối từ mất-30-phút thành bất tiện.
