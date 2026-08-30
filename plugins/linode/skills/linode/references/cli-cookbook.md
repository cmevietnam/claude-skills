# Công thức linode-cli

Tra cứu chuẩn vẫn là `linode-cli <group> <action> --help`. Đây là những thứ hay
dùng và những cái bẫy đã gặp thật.

Mọi ví dụ giả định project `cme`, env `staging`. Đổi tag cho khớp
`lingate whoami`.

## Nhìn account qua lăng kính project

```bash
linode-cli linodes list --tags cme --json | jq -r '.[] | "\(.id)\t\(.label)\t\(.status)"'
linode-cli linodes list --tags cme --text --no-headers --format 'id,label,tags'
lingate ls                                   # gộp cả loại dùng sổ sở hữu
```

Lọc chạy phía server nên rẻ. Ghép nhiều điều kiện được: `--tags cme --region sg-sin-2`.

## Compute

```bash
# tạo — hai tag luôn đi cùng nhau
linode-cli linodes create --tags cme --tags staging \
  --label cme-web-1 --region sg-sin-2 --type g6-standard-1 --image linode/ubuntu26.04

# đổi type (dừng máy, không đảo ngược ngay được)
linode-cli linodes resize 12345 --type g6-standard-2

# cài lại từ image — xoá sạch đĩa
opgate exec ROOT_PASS=op://Dev/cme/LINODE_ROOT_PASS -- \
  linode-cli linodes rebuild 12345 --image linode/ubuntu26.04 --root_pass "$ROOT_PASS"

linode-cli linodes ips-list 12345 --json | jq -r '.ipv4.public[].address'
```

## Volume, DNS, firewall

```bash
linode-cli volumes create --tags cme --tags staging --label cme-data --size 20 --region sg-sin-2
linode-cli volumes attach 555 --linode_id 12345      # hook kiểm tra CẢ hai đầu

linode-cli domains create --tags cme --tags staging --domain cme.example --type master --soa_email a@b.c
linode-cli domains records-create 22000001 --type A --name api --target 1.2.3.4 --ttl_sec 300

linode-cli firewalls create --tags cme --tags staging --label cme-fw \
  --rules.inbound_policy DROP --rules.outbound_policy ACCEPT
linode-cli firewalls device-create 999 --id 12345 --type linode
```

`domains records-create 22000001 …` — id đầu tiên là domain cha, và quyền sở hữu
được thừa kế từ đó; bản thân record không mang tag.

## LKE

```bash
linode-cli lke cluster-create --tags cme --tags staging \
  --label cme-k8s --region sg-sin-2 --k8s_version 1.35 \
  --node_pools.type g6-standard-1 --node_pools.count 2

linode-cli lke pools-list 580172 --json | jq -r '.[] | "\(.id)\t\(.count)\t\(.type)"'
linode-cli lke pool-update 580172 848275 --count 3
```

Node worker (`lke580172-…`) không mang tag riêng; muốn biết nó thuộc về ai thì nhìn
cluster. Đừng gắn tag tay cho chúng — recycle một cái là tag biến mất.

## Loại không gắn tag được

```bash
linode-cli vpcs create --label cme-vpc --region sg-sin-2 --json      # --json là bắt buộc
linode-cli databases mysql-create --label cme-db --region sg-sin-2 \
  --engine mysql/8 --type g6-nanode-1 --cluster_size 1 --json
```

`--json` để hook `PostToolUse` đọc được id và ghi `.linode/owned.json`. Nếu nó báo
không đọc được id thì ghi tay: `lingate own <group> <id> --env <env>`.

## Theo dõi tác vụ chạy nền

Resize, rebuild, migrate đều bất đồng bộ. Trạng thái nằm ở `events`:

```bash
linode-cli events list --json | jq -r '.[:5][] | "\(.action)\t\(.status)\t\(.entity.label // "")"'
linode-cli linodes view 12345 --text --no-headers --format 'status'
```

## Bẫy hay gặp

- **`update --tags` là PUT**, thay toàn bộ mảng tag chứ không thêm vào. Muốn thêm
  thì `lingate adopt`, đừng tự viết update.
- **Bảng mặc định bị truncate** và giấu cột. Dùng `--json`, hoặc `--no-truncation`
  với `--all-columns`.
- **Cảnh báo lệch version API** in ra ở mọi lệnh (`The API responded with version …`).
  Nó ở stderr; `--suppress-warnings` khi script hoá.
- **Phân trang**: `list` mặc định trả một trang. `--all-rows` khi cần hết.
- **`--raw-body`** cho endpoint mà CLI chưa dựng cờ; chỉ dùng với POST/PUT.
- **`images`** trộn cả image công khai của Linode và image riêng; lọc bằng
  `--is_public false` hoặc `--tags cme`.
