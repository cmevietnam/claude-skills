# Secret trong công việc với Linode

Mọi thứ in ra terminal đều vào transcript của cuộc hội thoại và được gửi lên model
provider. Một credential đã lọt vào đó coi như đã lộ và phải rotate. Linode có bốn
chỗ dễ vấp, cả bốn đều có cách làm đúng.

Skill `onepassword` (lệnh `opgate`) là nơi lấy và cất secret. Xem `opgate list` để
biết project có sẵn biến gì.

## 1. Root password khi tạo hoặc rebuild Linode

Không bao giờ viết thẳng giá trị: nó vào transcript, vào lịch sử shell, và vào
bảng process cùng lúc. Hook từ chối luôn dạng đó.

```bash
opgate exec ROOT_PASS=op://Dev/cme/LINODE_ROOT_PASS -- \
  linode-cli linodes create --tags cme --tags staging \
    --label cme-web-1 --root_pass "$ROOT_PASS"
```

Chưa có giá trị trong vault thì thêm dòng `LINODE_ROOT_PASS=op://Dev/cme/LINODE_ROOT_PASS`
vào `.env.op`, rồi bảo người dùng chạy `opgate put cme LINODE_ROOT_PASS`. Đừng hỏi
mật khẩu qua chat — câu trả lời sẽ nằm trong transcript.

## 2. Kubeconfig của LKE

`lke kubeconfig-view` trả về kubeconfig base64, tức là credential đầy đủ vào
cluster. Cho nó đi thẳng ra file, đừng để qua stdout:

```bash
linode-cli lke kubeconfig-view 580172 --json \
  | jq -r '.[0].kubeconfig' | base64 -d > ~/.kube/cme-prod.yaml
chmod 600 ~/.kube/cme-prod.yaml
```

Hook chỉ hỏi khi lệnh **không** có redirect hay pipe — có nghĩa là bạn đang định
in nó ra màn hình.

## 3. Credential do Linode sinh ra

`object-storage keys-create`, `databases *-creds-view`, `*-creds-reset` đều trả về
giá trị dùng được ngay. Cất vào 1Password trong cùng một pipeline, đừng chép tay:

```bash
linode-cli object-storage keys-create --label cme --json \
  | jq -r .secret_key | opgate put cme LINODE_OBJ_SECRET
```

`object-storage keys-create` là ngoại lệ duy nhất được phép pipe: id và secret về
cùng một lượt, và ép id ra stdout để hook ghi sổ đồng nghĩa ép cả secret vào
transcript. Đổi lại, id **không** vào sổ tự động — ghi tay ngay sau đó:

```bash
linode-cli object-storage keys-list --json | jq -r '.[] | "\(.id)\t\(.label)"'
lingate own object-storage <id> --env staging
```

Mọi create khác của nhóm dùng sổ (VPC, database, placement group…) đều bị **từ
chối** nếu output bị pipe hay redirect, vì lúc đó quyền sở hữu sẽ mất mà không ai
biết. Chạy chúng trần với `--json`.

Muốn kiểm tra là đã có thì so bên trong process con, đừng in ra:

```bash
opgate run -- sh -c '[ -n "$LINODE_OBJ_SECRET" ] && echo present'
```

## 4. Token của chính linode-cli

`LINODE_CLI_TOKEN` nằm trong `~/.config/linode-cli`. Đừng `cat` file đó, đừng
`echo $LINODE_CLI_TOKEN`, đừng đưa vào lệnh nào có `--debug` (nó in cả header
`Authorization`). Cần đổi token thì để người dùng chạy `linode-cli configure` —
hook cũng chỉ hỏi chứ không tự cho qua.

Kiểm tra token còn dùng được mà không lộ gì:

```bash
lingate doctor
```

## Nếu lỡ lộ

Coi như đã lộ thật, kể cả khi chỉ hiện một lần:

- root password → `linode-cli linodes disk-reset-password …`
- object storage key → `object-storage keys-delete` rồi tạo key mới
- database credential → `databases <engine>-creds-reset <id>`
- API token → xoá ở `profile tokens-list` / tạo lại bằng `linode-cli configure`

Rồi cập nhật giá trị mới vào 1Password bằng `opgate put`.
