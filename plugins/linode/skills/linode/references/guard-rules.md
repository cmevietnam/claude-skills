# Hook chặn gì, và vì sao

Hàng rào là `PreToolUse(Bash)` → `scripts/guard-linode.sh`.

## Fail closed tới đâu

Khi không xác minh được quyền sở hữu — API lỗi, id không tồn tại, action lạ, hoặc
chính script này gặp lỗi giữa chừng — câu trả lời là **từ chối**. Một cái chốt cửa
mà lúc nghi ngờ thì tự mở còn tệ hơn không có chốt.

Có đúng **một** trường hợp nó không tự quyết được, và cần nói thẳng: nếu toàn bộ
hook chạy quá `timeout` khai báo trong `hooks/hooks.json` (15 giây), Claude Code
huỷ hook và **bỏ qua quyết định** — lệnh đi tiếp theo luồng quyền bình thường.
Không có cách nào để một hook hết giờ trở thành "chặn". Vì vậy mọi lời gọi API
trong một lần hook dùng chung **một ngân sách** (`LINGATE_BUDGET`, mặc định 11
giây); mỗi lời gọi nhận phần còn lại, tối đa `LINGATE_DEADLINE` (8 giây), qua
`perl -e alarm` và `--no-retry`. Hết ngân sách thì `resolve_tags` thất bại và
guard **từ chối** trong khi vẫn còn thời gian để trả lời — dù lệnh có phải tra 3
resource (chủ + đích + cluster cha) đi nữa. Cửa sổ fail-open thu lại còn những sự
cố khiến chính bash treo, chứ không phải mạng chậm.

Nó không phải sandbox. Đây là thứ chặn sai sót thường gặp trước khi nó thành sự
cố, không phải thứ chống lại một tác nhân cố tình phá.

## Bảng luật

| Tình huống | Quyết định |
|---|---|
| Mọi lệnh đọc (`list`, `view`, `*-list`, `*-view`…) | cho qua |
| Đọc credential (`*-creds-view`, `kubeconfig-view`, `keys-list`, `*-ssl-cert`) mà không redirect/pipe | **hỏi** |
| Create loại gắn tag được, thiếu `--tags <project>` hoặc `--tags <env>` | **từ chối** |
| Create loại không gắn tag được, thiếu `--json` | **từ chối** (không ghi sổ được) |
| Ghi lên resource mang đúng tag project và đúng env | cho qua |
| Ghi lên resource mang tag project khác | **từ chối** |
| Ghi lên resource chưa mang tag nào | **từ chối**, chỉ sang `lingate adopt` |
| Ghi lên resource thuộc project này nhưng **khác env** | **từ chối** (CROSS-ENV) |
| Resource mang nhiều env tag, project **chưa** bật `allowSharedEnvs` | **từ chối** |
| Resource dùng chung env, env còn lại **được bảo vệ** | **hỏi** (mỗi lần) |
| Resource dùng chung env, env còn lại **không** được bảo vệ | cho qua |
| Resource thứ hai trên dòng lệnh (`--linode_id`, `--firewall_id`, `--id --type`, `--linodes`) không thuộc project/env | **từ chối** |
| Sổ sở hữu khai báo `"tag"` khác với project hiện tại | **từ chối** |
| Id của resource đích là biến shell hay JSON (`--linode_id $ID`) | **từ chối** (không đọc được thì không xác minh được) |
| `--tags $VAR` | **từ chối** |
| `linode-cli` đứng sau một wrapper hook **không biết** (`mystery-tool linode-cli …`) | **hỏi** |
| Create loại dùng sổ nằm chung lệnh Bash với một lời gọi `linode-cli` khác | **từ chối** (hook ghi sổ không biết id nào của cái nào) |
| Đọc credential rồi pipe vào lệnh vẫn in ra màn hình (`\| base64 -d`), hay chỉ redirect stderr | **hỏi** (chưa phải sink) |
| Ghi ở env nằm trong `protectedEnvs` | **hỏi** |
| `--tags` trên lệnh ghi làm rơi tag project hoặc tag env | **từ chối** |
| `--tags` gắn thêm một env tag thứ hai | **từ chối** (resource mơ hồ) |
| Bất kỳ lệnh nào có `--help`, hoặc trang trợ giúp cục bộ (`commands`, `env-vars`, `plugins`) | cho qua (không chạm API) |
| `tags create/delete` với label không phải tag project hoặc env | **từ chối** |
| `tags create --linodes/--volumes/…` (gắn tag thẳng vào resource) | **từ chối**, chỉ sang `lingate adopt` |
| `tags delete` chính tag project hoặc env của mình | **hỏi** (xoá tag gỡ nó khỏi mọi resource toàn account) |
| Create loại dùng sổ mà output bị pipe hoặc redirect | **từ chối** (hook ghi sổ không đọc được id) |
| Nhiều create loại dùng sổ trong cùng một lệnh Bash | **từ chối** (không biết id nào của cái nào) |
| `--root_pass` nhận giá trị viết thẳng | **từ chối** |
| Không tìm thấy `.linode/project.json` | **từ chối** |
| Không tra được tag (API lỗi, id lạ) | **từ chối** |
| Action không phân loại được là đọc hay ghi | **từ chối** |
| Ghi lên tài nguyên cấp account (`account`, `users`, `profile`…) | **từ chối** |
| `linode-cli configure`, `set-user`, `remove-user` | **hỏi** |
| `tags create/delete` với label không phải tag project hoặc env | **từ chối** |

## Một resource, một môi trường — và ngoại lệ có khai báo

Mặc định một resource chỉ được mang **một** env tag. Mang hai là mơ hồ, và tệ hơn:
nó biến mọi lệnh chạy ở staging thành một lệnh chạm được vào prod.

Thực tế đôi khi khác: một máy phục vụ cả hai môi trường để tiết kiệm chi phí. Đó
là lựa chọn hợp lệ, nhưng phải **nói ra**, trong `.linode/project.json`:

```json
{ "allowSharedEnvs": true }
```

Khi đã bật:

- Lệnh chạy ở env nằm trong tập env của resource → cho phép.
- Nếu resource còn phục vụ một env **được bảo vệ** khác (thường là `prod`) thì
  **mọi lần ghi đều hỏi**, kèm câu nhắc rằng thay đổi này chạm luôn vào prod.
  Chia sẻ giữa `dev` và `staging` không hỏi gì cả — không có gì để mất.
- Lệnh chạy ở env **không** nằm trong tập đó vẫn bị từ chối như thường.

`lingate doctor` liệt kê mọi resource đang dùng chung env và gọi đúng tên nó là
nợ kỹ thuật. Trạng thái đích vẫn là một resource một môi trường; cờ này chỉ làm
cho khoảng cách giữa hiện tại và đích trở nên nhìn thấy được, thay vì thành thói
quen vô hình.

## Env lấy từ đâu

Theo thứ tự: tiền tố `LINODE_ENV=…` ngay trên dòng lệnh → biến môi trường
`LINODE_ENV` → `defaultEnv` trong config.

Tiền tố trên dòng lệnh là cách duy nhất đáng tin: hook chạy trong process riêng và
không hề thừa hưởng biến môi trường của lệnh sắp chạy — nó đọc chữ `LINODE_ENV=`
trong chính văn bản của lệnh.

## Loại nào gắn tag được

Kiểm chứng trên `linode-cli` v5.67.0, không phải đọc từ tài liệu:

| Gắn tag được | Không gắn tag được |
|---|---|
| `linodes` `volumes` `nodebalancers` `domains` `lke` `firewalls` `images` | `databases` `vpcs` `object-storage` `placement` `stackscripts` `sshkeys` |

Nhóm bên phải dùng sổ `.linode/owned.json`.

## Cách hook đọc một dòng lệnh

- Dòng lệnh được đưa qua một **lexer shell thật**: `'...'`, `"..."` và `\` được
  xử lý đúng (nên `&&` trong một label không cắt lệnh làm đôi, `--tags="cme --tags
  staging"` là **một** tag); **xuống dòng** là ranh giới lệnh; `$( )` và backtick
  được mở ra **kể cả trong nháy kép**; target của redirect (`> file`) bị nuốt chứ
  không thành id; thân heredoc bị bỏ qua; `\` cuối dòng là nối dòng.
- `bash -c "..."`, `sh -lc`, `eval …`, `env -S "…"` được mở ra và soi lại như
  một dòng lệnh riêng.
- Một token `linode-cli`/`linode`/`lin` (so theo **basename**) chỉ tính là lời gọi
  khi nó ở chỗ thực sự chạy được: đầu đoạn, sau từ khoá shell (`do`, `then`, `!`,
  `{`, `time`), sau gán biến (`LINODE_ENV=prod`), hoặc sau một wrapper hook **biết
  arity cờ** của nó: `env`, `sudo`/`doas`, `command`, `exec`, `nohup`, `nice`,
  `stdbuf`, `timeout`, `xargs`, `watch`, `caffeinate`, và `opgate exec|run … --`.
  `sudo -u root`, `timeout 10`, `xargs -I{}` đều đáp đúng chỗ. `echo linode-cli`,
  `grep linode`, `cat linode-notes.txt` là dữ liệu → bỏ qua. Một head hook
  **không biết** mà phía sau có `linode-cli` → **hỏi**, vì không biết nó có chạy
  lệnh phía sau hay không.
- **Cờ phân giải như argparse**: tên đầy đủ khớp trước, rồi mới tới tiền tố không
  nhập nhằng. Nên `--domain` là field thật của `domains create` (không phải viết
  tắt của `--domains`), còn `--tag`, `--ta`, `--root_pas`, `--linode_i` vẫn được
  nhận đúng. Field lồng nhau lấy thành phần cuối: `--devices.linodes`,
  `--interfaces.vpc_id`, `--placement_group.id` đều trỏ tới resource thứ hai và
  bị soi như id chính.
- Thư mục làm việc lấy từ trường `cwd` của payload (nơi Bash tool thực sự chạy),
  và một `cd` trong lệnh dời nó cho các đoạn sau — `.linode/project.json` được tìm
  từ đó, không phải từ nơi Claude Code khởi động.
- Hook biết cờ toàn cục nào **không** ăn giá trị (`--json`, `--suppress-warnings`,
  `--pretty`, …) nên `linodes reboot --suppress-warnings 123` vẫn thấy id `123`,
  còn `volumes --format nodebalancers delete 555` không nhầm `nodebalancers`
  thành action. Cờ lạ bị coi là ăn giá trị — lệch về phía chặn nhầm, không phải
  phía cho lọt.
- **Id định vị theo thứ tự**: token không phải cờ đầu tiên sau lời gọi là group,
  kế đó là action, còn lại là positional. Với resource lồng nhau
  (`domains records-update <domainID> <recordID>`), id **đầu tiên** là chủ sở hữu.
- Node worker của LKE có label dạng `lke<clusterID>-…`; nếu nó không mang tag riêng
  thì hook lấy tag của cluster.
- Kết quả tra tag được cache 60 giây tại `~/.cache/lingate` (đổi bằng
  `LINGATE_TTL`). `lingate adopt` tự xoá cache của resource nó vừa sửa.
- **Lệnh phá huỷ bỏ qua cache.** `delete`, `rebuild`, `resize`, `recycle`,
  `restore`, `revoke`… luôn hỏi lại API. Cache là một canh bạc rằng không có gì
  đổi trong một phút vừa rồi; với những lệnh này thì canh bạc đó không đáng.
- Ngoài id chính, hook còn soi **resource thứ hai** mà lệnh nhắc tới:
  `--linode_id`, `--linodes`, `--firewall_id(s)`, `--volume_id`, `--vpc_id`,
  `--devices.linodes`, `--interfaces.vpc_id`, `--placement_group.id`, và cặp
  `--id`/`--type` của `firewalls device-create`. Gắn một volume của project vào
  một Linode của project khác cũng là ghi lên resource của họ. Giá trị không đọc
  được (`$ID`, danh sách JSON) → từ chối, không bỏ qua.
- **Sink tính theo từng đoạn.** Với lệnh đọc credential, stdout phải kết thúc ở
  một file (`> …`) hoặc ở `opgate` sau khi đi hết pipeline; `2>/dev/null`,
  `< file`, hay pipe vào một lệnh vẫn in ra màn hình đều **không** tính. Với create
  loại dùng sổ thì ngược lại: stdout **không được** đi vào file hay pipe, và lệnh
  phải đứng **một mình** trong lần gọi Bash — vì hook ghi sổ đọc id từ stdout của
  cả lần gọi.
- `ask` không kết thúc việc xét: hook đi hết mọi đoạn, và một `deny` ở đoạn sau
  thắng `ask` ở đoạn trước. Xác nhận một lệnh không bao giờ thả kèm một lệnh khác
  chưa được kiểm tra.

## Khi bị chặn

Lý do từ chối luôn kèm câu lệnh đúng. Ba trường hợp cần dừng lại và hỏi người dùng
thay vì tự xử lý:

- **"thuộc project khác"** — đây là câu trả lời "không". Đừng tìm đường vòng.
- **"chưa mang tag nào"** — cần một quyết định về quyền sở hữu, không phải một
  lệnh. Hỏi rồi mới `lingate adopt`.
- **"CROSS-ENV"** — hook không tự suy diễn ý định giữa hai môi trường. Xác nhận
  người dùng thật sự muốn env kia rồi thêm tiền tố `LINODE_ENV=`.

## Tắt hàng rào

`LINGATE_GUARD=off`. Đây là việc của con người, không phải của agent — nếu bạn
đang định dùng nó để đi vòng qua một lời từ chối thì lời từ chối ấy đúng.
