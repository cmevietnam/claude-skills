# Secret reference `op://` và file `.env.op`

## Cú pháp

```
op://<vault>/<item>/<field>
op://<vault>/<item>/<section>/<field>
```

Quy ước của repo này: `op://Dev/<tên-project>/<TÊN_BIẾN>` — không dùng section, vì
một tầng nữa chỉ thêm chỗ để gõ sai mà không đổi được gì.

Vault, item và field có thể dùng tên hoặc ID. Tên dễ đọc hơn nhưng đổi tên item
trong 1Password sẽ làm hỏng mọi reference; ID thì bền nhưng không đọc được. Dùng tên,
và đừng đổi tên item.

Tên có khoảng trắng thì bọc reference trong nháy kép. Tốt hơn là đừng đặt tên item
có khoảng trắng.

## `.env.op`

```
# commit được — chỉ chứa reference, không chứa giá trị
DATABASE_URL=op://Dev/cme-api/DATABASE_URL
JWT_SECRET=op://Dev/cme-api/JWT_SECRET

# giá trị không bí mật cứ để thẳng
NODE_ENV=development
PORT=3000
```

`opgate list` cảnh báo nếu có dòng nào chứa giá trị literal trông như secret — đó là
lỗi thường gặp nhất khi mới chuyển sang, và nó biến một file lẽ ra commit được thành
một file rò rỉ.

`opgate` tìm `.env.op` ở thư mục hiện tại rồi tới gốc git repo. Dùng file khác thì
`-f`, hoặc đặt `OPGATE_ENV_FILE`.

## Lỗi thường gặp

**`could not resolve item`** — sai tên vault/item/field, hoặc item nằm ở vault khác.
Kiểm tra: `op item list --vault Dev`.

**`authorization timeout`** — phiên uỷ quyền của 1Password hết hạn. Unlock lại app
1Password rồi chạy lại.

**Biến rỗng trong process con** — reference đúng nhưng field không tồn tại trên item.
1Password trả chuỗi rỗng chứ không báo lỗi. Kiểm tra bằng
`op item get <item> --vault Dev --format json | jq -r '.fields[].label'` (chỉ in
**nhãn** field, không in giá trị).

**Biến không expand trong chính lệnh truyền cho `opgate run`** — `opgate run -- echo
$FOO` expand `$FOO` ở shell *ngoài*, trước khi secret tồn tại. Bọc trong subshell:
`opgate run -- sh -c 'echo "$FOO"'`. Lưu ý 1Password sẽ mask giá trị trong output.

**Giá trị hiện ra là `<concealed by 1Password>`** — đó là masking hoạt động đúng, không
phải lỗi. Process con nhận giá trị thật; chỉ output bị che. Đừng dùng `--no-masking`
để "gỡ" nó.

## Nhiều môi trường

Một item cho mỗi môi trường, đặt tên rõ ràng:

```
.env.op          -> op://Dev/cme-api/…
.env.staging.op  -> op://Dev/cme-api-staging/…
```

```bash
opgate run -f .env.staging.op -- npm run migrate
```

Secret production không nên nằm trong tầm với của một agent trên máy dev. Nếu cần
đưa vào CI thì dùng 1Password service account với scope đúng một vault — service
account không có Touch ID, nên đừng dùng nó trên máy cá nhân.
