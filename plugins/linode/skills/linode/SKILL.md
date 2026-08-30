---
name: linode
description: Thao tác hạ tầng Linode bằng `linode-cli`, trong ranh giới tag của project và tag môi trường. Dùng khi cần tạo hoặc sửa Linode/volume/DNS/firewall/LKE, khi cần xem hạ tầng của project, khi gặp resource chưa gắn tag, khi một lệnh Linode bị hook chặn, hoặc khi lệnh cần root password / kubeconfig / credential.
---

# Linode trong ranh giới project và môi trường

Một account Linode phẳng: mọi project nằm chung một chỗ và nhìn thấy nhau. Thứ duy
nhất chia chúng ra là **tag**. Vì vậy mỗi resource ở đây mang hai tag — tag project
nói nó của ai, và tag env nói nó là môi trường nào — còn hook `PreToolUse` từ chối
mọi lệnh ghi không thoả cả hai. Vài loại (VPC, database, object storage…) API không
cho gắn tag; chúng dùng sổ sở hữu trong repo thay thế.

`linode-cli` vẫn là công cụ chính, không bị bọc lại. `lingate` chỉ lo phần
`linode-cli` không có khái niệm: project, môi trường, và sổ sở hữu.

## Luật quan trọng nhất

**Đọc thoải mái, ghi thì phải đúng cả project lẫn env.** Cụ thể:

1. Resource mới tạo **luôn** kèm `--tags <project>` và `--tags <env>`. Thiếu một
   trong hai là resource ra đời ngoài hàng rào, và từ đó không lệnh nào chạm được
   vào nó nữa.
2. **Không bao giờ ghi lên resource mang tag project khác.** Không ngoại lệ, kể cả
   khi người dùng nói "cứ sửa giúp" — hãy hỏi lại và để họ tự chạy.
3. **Cross-env là lỗi, không phải chi tiết.** Lệnh chạy ở env `staging` không được
   đụng vào resource tag `prod`. Muốn sang env khác thì nói thẳng ra ngay trên dòng
   lệnh: `LINODE_ENV=prod linode-cli …`, và hỏi người dùng trước.
4. **Một resource, một môi trường.** Trừ khi project bật `allowSharedEnvs` — khi đó
   một máy được phục vụ hai env để tiết kiệm, nhưng mọi lệnh ghi lên nó sẽ hỏi nếu
   env còn lại được bảo vệ. Đừng tự gắn thêm env tag thứ hai; dùng `lingate adopt`.

## Việc không được làm

- Chạy `linode-cli … create` mà quên `--tags`. Không có tag = không có chủ.
- `linode-cli <group> update <id> --tags x` để "đổi tag" — đây là PUT thay **toàn
  bộ** mảng tag. Muốn thêm tag thì `lingate adopt`, đừng tự viết lệnh update.
- Tự adopt resource chưa gắn tag. Nó có thể là của project khác. **Hỏi người dùng
  trước**, rồi mới `lingate adopt <group> <id> --env <env> --yes`.
- `--root_pass <mật khẩu viết thẳng>` → giá trị vào transcript, phải rotate ngay.
  Dùng `opgate exec`, xem `references/secrets.md`.
- In kubeconfig / DB credential / object-storage key ra stdout. Cho nó đi thẳng vào
  file đã git-ignore hoặc vào 1Password.
- Viết tắt tên cờ (`--tag` thay `--tags`). CLI chấp nhận và hook cũng hiểu, nhưng
  người đọc lại lệnh thì không — viết đủ.
- Đoán khi bị chặn. Hook luôn nói rõ lệnh đúng là gì — đọc rồi làm theo, đừng thử
  đường vòng.

## Chạy linode-cli

- Cú pháp `linode-cli <group> <action> [id...] [--flags]`. `linode-cli commands`
  liệt kê group; `linode-cli <group> <action> --help` là nguồn tra cứu chuẩn —
  dùng nó thay vì đoán tên flag.
- **Luôn `--json`** khi cần đọc kết quả bằng máy rồi ghép với `jq`; bảng mặc định
  cắt cột và truncate giá trị. `--text --no-headers --format 'id,label,tags'` khi
  chỉ cần vài cột.
- Lọc phía server ngay ở `list`: `--tags`, `--region`, `--label`, `--id`. Đây là
  cách nhìn account qua lăng kính project: `linode-cli linodes list --tags cme`.
- Region/type/image mặc định đã có trong `~/.config/linode-cli` nên khỏi truyền
  lại — nhưng tag thì không có mặc định, luôn phải truyền tay.
- Mỗi lệnh in một dòng cảnh báo lệch version API. Đó là tiếng ồn trên stderr, lọc
  bằng `--suppress-warnings` khi script hoá.

## Lệnh lingate

| Lệnh | Dùng khi |
|---|---|
| `lingate whoami` | Không chắc đang đứng ở project/env nào. Rẻ, cứ gọi trước khi ghi. |
| `lingate ls [group]` | Muốn biết project này đang có gì. |
| `lingate orphans` | Có resource chưa gắn tag; đây là danh sách ứng viên adopt. |
| `lingate adopt <g> <id> --env E` | Nhận một resource cũ về project. In dry-run trước; chỉ chạy thật khi thêm `--yes`. |
| `lingate own <g> <id> --env E` | Loại không gắn tag được (VPC, database, object storage…) — ghi vào sổ. |
| `lingate disown <g> <id>` | Resource đã xoá hoặc không còn thuộc project. |
| `lingate init <tag> --envs a,b,c` | Repo chưa có `.linode/project.json`. |
| `lingate doctor` | Có gì đó không chạy. In toàn bộ trạng thái và cách sửa. |

## Quy trình thường gặp

**Tạo resource mới** — tag project và tag env đi cùng nhau, luôn luôn:

```bash
lingate whoami                              # đang ở project/env nào
linode-cli linodes create --tags cme --tags staging \
  --label cme-web-1 --region sg-sin-2
```

**Thao tác trên môi trường khác** — nói rõ ngay trên dòng lệnh, và hỏi trước:

```bash
LINODE_ENV=prod linode-cli linodes reboot 95747451
```

**Gặp resource chưa gắn tag** — đừng tự nhận:

```bash
lingate orphans                             # nó là của ai chưa biết
lingate adopt linodes 95747451 --env prod   # dry-run, in ra sẽ làm gì
# hỏi người dùng, rồi mới:
lingate adopt linodes 95747451 --env prod --yes
```

**Tạo loại không gắn tag được** — thêm `--json` để sổ sở hữu tự ghi:

```bash
linode-cli vpcs create --label cme-vpc --region sg-sin-2 --json
# hook PostToolUse ghi id vào .linode/owned.json; nhớ commit file đó
```

**Lệnh bị chặn**: lý do từ chối đã nói chính xác phải làm gì. Nếu nó bảo resource
thuộc project khác thì dừng lại và báo người dùng — đó là câu trả lời "không", chứ
không phải một trở ngại cần vượt qua.

## Quy ước tag & label

Hai tag cho mỗi resource, khai báo trong `.linode/project.json` (commit vào git):

```
<tên-project>        cme, urgentc, gocova
<môi-trường>         dev, staging, prod
```

Label đặt theo `<project>-<vai trò>[-<số>]`: `cme-web-1`, `cme-postgres`. Node của
LKE do cluster tự sinh (`lke580172-…`) nên không mang tag riêng — quyền sở hữu của
nó lấy theo cluster, đừng gắn tag tay cho chúng.

## Đọc thêm

- `references/project-setup.md` — dựng `.linode/project.json` và nhận resource cũ về
- `references/guard-rules.md` — hook chặn gì, vì sao, và làm gì khi bị chặn
- `references/secrets.md` — root password, kubeconfig, credential đi qua 1Password
- `references/cli-cookbook.md` — công thức `linode-cli` cho việc hay làm
