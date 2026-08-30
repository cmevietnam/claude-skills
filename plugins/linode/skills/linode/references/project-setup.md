# Dựng ranh giới cho một project

Làm một lần cho mỗi repo. Sau bước này mọi lệnh ghi đều tự động bị kiểm tra.

## 1. Khai báo project

Ở gốc repo:

```bash
lingate init cme --region sg-sin-2 --envs dev,staging,prod --protect prod
```

Sinh ra `.linode/project.json`:

```json
{
  "tag": "cme",
  "labelPrefix": "cme-",
  "defaultRegion": "sg-sin-2",
  "envs": ["dev", "staging", "prod"],
  "defaultEnv": "dev",
  "protectedEnvs": ["prod"],
  "allowSharedEnvs": false
}
```

- `tag` — ranh giới cứng. Mọi lệnh ghi đều đối chiếu với nó.
- `envs` — các môi trường hợp lệ. Bỏ trống (`--no-envs`) thì tắt hoàn toàn hàng
  rào cross-env; chỉ nên làm vậy với project một môi trường.
- `defaultEnv` — env khi dòng lệnh không nói gì. Đặt là env **ít nguy hiểm nhất**.
- `protectedEnvs` — env mà mọi lệnh ghi đều phải được người dùng bấm xác nhận.
- `allowSharedEnvs` — cho phép một resource phục vụ nhiều môi trường. Bật bằng
  `lingate init --shared-envs` khi cố ý gộp để tiết kiệm chi phí; mọi lệnh ghi lên
  resource dùng chung vẫn phải xác nhận nếu env còn lại được bảo vệ, và
  `lingate doctor` sẽ liệt kê chúng để không quên tách ra sau này.

**Commit cả thư mục `.linode/`.** Nó là hợp đồng chung của team, và review được
qua PR — khác hẳn một biến môi trường mà mỗi máy một kiểu.

## 2. Nhận các resource cũ về

Resource tạo trước khi có plugin thường chưa mang tag nào. Với hàng rào này,
"chưa tag" nghĩa là "không thuộc project nào" nên mọi lệnh ghi lên nó đều bị từ
chối — đó là chủ ý, không phải lỗi.

```bash
lingate orphans
```

In ra những resource chưa mang tag, ví dụ:

```
linodes        95747451     cme-postgres
lke            580172       cme-cluster
```

Node worker của LKE (`lke580172-848275-…`) **không** xuất hiện ở đây: chúng do
cluster sinh ra, quyền sở hữu lấy theo cluster.

Với từng cái, chạy dry-run trước:

```bash
lingate adopt lke 580172 --env prod
```

Nó chỉ in ra sẽ làm gì. **Hỏi người dùng xem resource đó có đúng là của project
này không** — tên gợi ý chứ không chứng minh được điều gì — rồi mới chạy thật:

```bash
lingate adopt lke 580172 --env prod --yes
lingate adopt linodes 95747451 --env prod --yes
```

`adopt` **cộng thêm** tag chứ không ghi đè: `linode-cli … update --tags` là một
PUT thay toàn bộ mảng, nên lệnh thật gửi lại đủ tag cũ kèm tag mới. Đó cũng là lý
do đừng tự viết lệnh update để gắn tag.

## 3. Loại resource không gắn tag được

VPC, Managed Database, Object Storage, Placement Group, StackScript và SSH key
không có trường `tags` trên API. Quyền sở hữu của chúng nằm ở `.linode/owned.json`:

```bash
lingate own vpcs 12345 --env staging --label cme-vpc
```

Khi tạo mới, chỉ cần thêm `--json` và hook `PostToolUse` tự ghi sổ:

```bash
linode-cli vpcs create --label cme-vpc --region sg-sin-2 --json
```

Sổ này cũng phải commit. Nếu nó lệch với thực tế thì hàng rào lệch theo — `lingate
ls` để đối chiếu, `lingate disown` để dọn những id đã xoá.

## 4. Kiểm tra

```bash
lingate doctor
```

Kiểm tra `linode-cli`, token, cấu hình project, danh sách env, sổ sở hữu, và trạng
thái hàng rào. Mọi mục hỏng đều in kèm câu lệnh sửa.
