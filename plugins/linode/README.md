# linode

Làm việc với Linode trong ranh giới tag của project: resource tạo ra luôn mang tag
project, và mọi thao tác ghi lên resource của project khác đều bị chặn.

Một account Linode phẳng — mọi project chung một chỗ. Plugin này dựng lại ranh giới
mà API không có, bằng hai trục tag: **project** (của ai) và **env** (môi trường
nào). `linode-cli` vẫn là công cụ chính; `lingate` chỉ lo phần `linode-cli` không
có khái niệm.

## Cài

```bash
claude plugin install linode@hieuvo-skills
```

Rồi ở mỗi repo, một lần:

```bash
lingate init cme --region sg-sin-2 --envs dev,staging,prod --protect prod
lingate orphans        # resource cũ chưa gắn tag
lingate doctor
```

Cần `linode-cli` đã `configure`. Không cần gì khác — hook và `lingate` chỉ dùng
bash, awk và chính `linode-cli`. Dùng `perl` (macOS có sẵn) để đặt deadline cho lời
gọi API, và dùng `jq` nếu có nhưng không bắt buộc.

## Ranh giới

Hook `PreToolUse(Bash)` xét mọi lệnh `linode-cli` và **fail closed**: API lỗi, id
lạ, action chưa biết, hay chính hook hỏng giữa chừng đều thành từ chối. Ngoại lệ
duy nhất nằm ngoài tầm với của nó — nếu cả hook chạy quá `timeout` trong
`hooks.json` thì Claude Code bỏ qua quyết định và lệnh đi tiếp; vì vậy mọi lời gọi
API trong một lần hook dùng chung một ngân sách (`LINGATE_BUDGET`, mặc định 11s,
mỗi lời gọi tối đa `LINGATE_DEADLINE` 8s) để kịp trả lời "từ chối" trước khi hết
giờ. Chi tiết: `skills/linode/references/guard-rules.md`.

- Đọc (`list`, `view`, …) — luôn cho qua.
- Tạo — bắt buộc `--tags <project>` và `--tags <env>`.
- Ghi lên resource của project khác — từ chối, không ngoại lệ.
- Ghi lên resource chưa gắn tag — từ chối, chỉ sang `lingate adopt`.
- Ghi lên resource khác môi trường — từ chối (CROSS-ENV).
- Resource phục vụ nhiều môi trường — từ chối, trừ khi project bật
  `allowSharedEnvs`; khi đó cho phép nhưng **luôn hỏi** nếu một trong các môi
  trường còn lại được bảo vệ.
- Ghi trong `protectedEnvs` — hỏi người dùng.
- Sửa hoặc xoá chính tag ranh giới (`tags create/delete`) — chặn hoặc hỏi.
- `--help` và các trang trợ giúp cục bộ — luôn cho qua, chúng không chạm API.
- Credential ra stdout (`kubeconfig-view`, `*-creds-view`, `--root_pass` viết
  thẳng) — hỏi hoặc từ chối, và chỉ sang skill `onepassword`.

Bảng luật đầy đủ: `skills/linode/references/guard-rules.md`.

Đây là thứ chặn sai sót thường gặp, không phải sandbox — một agent muốn né thì né
được. Giá trị của nó là chặn cái sai *có khả năng xảy ra* trước khi nó thành sự cố.

## Quyền sở hữu nằm ở đâu

| Loại | Nguồn sự thật |
|---|---|
| `linodes` `volumes` `nodebalancers` `domains` `lke` `firewalls` `images` | trường `tags` trên API |
| `databases` `vpcs` `object-storage` `placement` `stackscripts` `sshkeys` | `.linode/owned.json` trong repo |

Nhóm dưới không có trường `tags` trên API Linode, nên id được ghi sổ ngay lúc tạo
bởi hook `PostToolUse` (vì vậy create của nhóm này bắt buộc `--json`).

Cả `.linode/project.json` lẫn `.linode/owned.json` đều **commit vào git**.

## Cấu hình

`.linode/project.json`:

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

Bỏ `envs` (`lingate init --no-envs`) thì tắt hoàn toàn hàng rào cross-env.

`allowSharedEnvs` (`lingate init --shared-envs`) cho phép một resource phục vụ
nhiều môi trường — hợp lệ khi cố ý gộp để tiết kiệm, nhưng mọi lệnh ghi lên nó
đều phải xác nhận nếu môi trường còn lại được bảo vệ. `lingate doctor` liệt kê
chúng như nợ kỹ thuật: trạng thái đích vẫn là một resource một môi trường.

Biến môi trường:

| Biến | Mặc định | Việc |
|---|---|---|
| `LINODE_ENV` | `defaultEnv` | Môi trường của lệnh. Tiền tố ngay trên dòng lệnh (`LINODE_ENV=prod linode-cli …`) là cách duy nhất hook nhìn thấy được. |
| `LINGATE_TTL` | `60` | Giây cache kết quả tra tag tại `~/.cache/lingate`. Lệnh phá huỷ luôn bỏ qua cache. |
| `LINGATE_GUARD` | `on` | `off` tắt hàng rào. Việc của con người, không phải của agent. |
| `LINGATE_DEADLINE` | `8` | Giây tối đa cho **một** lời gọi API tra tag. |
| `LINGATE_BUDGET` | `11` | Giây tối đa cho **tất cả** lời gọi API của một lần hook — phải nhỏ hơn `timeout` 15s trong `hooks.json`. |

## Test

```bash
bash plugins/linode/scripts/test-guard.sh
```

162 assertion, chạy hoàn toàn offline: một `linode-cli` giả ở đầu `PATH` trả lời mọi
truy vấn quyền sở hữu từ một bảng cố định, nên không cần account, token hay mạng.
Mỗi lỗ hổng từng được tìm ra đều có một assertion giữ chỗ.
