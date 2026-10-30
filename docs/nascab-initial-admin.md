# NasCabOS 初始 super_admin：为什么没有设置向导，以及怎么把凭据捞出来

**症状**（2026-10-30 用户报告）：部署完成后打开 `/nascab/`，没有跳"设置账号密码"的向导，
直接就是登录页，要求输入账号密码——但没人告诉过账号密码是什么。

**结论**：安装是好的。向导在**两天前**就已经走完了，凭据只是没有任何地方显示出来。
headless 模式本该把凭据落盘的那一步被一个 `isDocker` 守卫跳过了，而登录页长得和
"缺一个向导"一模一样。

---

## 1. 机制：向导只会出现一次

`src/initHandler/initialSuperAdmin.js#ensureInitialSuperAdmin()` **每次启动都会跑**，
但它只在 `user` 表里没有任何 `super_admin` 时才创建账号：

```js
async ensureInitialSuperAdmin() {
  const knexMain = knexUtil.getInstance(dbUtil.DB_PATHS.MAIN_DB);
  const authService = require('../api/modules/auth/authService');
  const has = await authService.hasSuperAdmin({ knexMain });
  if (has) return { created: false };          // ← 有管理员就直接返回，什么都不做
  const question = 'init';
  for (let i = 0; i < 20; i++) {
    const username = generateCredential(6);    // 6 位随机
    const passwordPlain = generateCredential(6);
    const answer = generateCredential(16);
    try {
      await authService.createSuperAdmin({ knexMain },
        { username, password: toClientPasswordObfuscated(passwordPlain),
          question, answer, language: 'zh-CN' });
      await tableConfig.setConfigByKey(tableConfig.KEY_IS_INITIAL_ADMIN, '1', 0);
      return { created: true, username, password: passwordPlain };
    } catch (e) { if (e && e.message === 'auth.USERNAME_EXISTS') continue; throw e; }
  }
  throw new Error('auth.SUPER_ADMIN_CREATE_FAILED');
}
```

本机的记录：**2026-10-28 15:42:50** 生成了第一对凭据，并把 `config.is_initial_admin` 置 `'1'`。
此后每次启动都走 `return { created: false }` 那条路。

### 两个推论

- **设置向导永远不会再出现。** 只要 `user` 表里有 super_admin，创建逻辑就不执行。
- **删掉 `user` 行没有用。** 那只会让下次启动再生成一对新的随机凭据，同样不显示给你——
  只是把一个"看得见的问题"变成另一个"看不见的问题"。

---

## 2. 凭据为什么没被看见：`isDocker` 守卫

`initialSuperAdmin.js` 里的 `writeLinuxHeadlessAdminAccountFileIfNeeded()` 本该把凭据写到
`/app/nascab/data/nascabos_admin_account`（0600）。但它开头就是：

```js
const isInitialFlag = await tableConfig.getConfigByKey(tableConfig.KEY_IS_INITIAL_ADMIN, 0);
if (isInitialFlag === '1' && !packageJson.isDocker) return;   // ← 直接跳过
```

而 `package.json` 里是 `"isDocker": false`，于是这个文件从来不会被写出来。

**不要去改 `isDocker`。** 全仓共有 5 处依赖它：

- `libsPath/ffprobePath/index.js:26`
- `libsPath/ffmpegPath/index.js:27`
- `utils/mountPlatformUtil.js:6-11`
- `config/config.js:120`
- 上面这个守卫

为了看到一对凭据去改一个影响 ffmpeg/ffprobe 路径、挂载平台判断和配置默认值的全局开关，
代价和收益完全不成比例。

---

## 3. 三个能拿到凭据的地方

### (a) 日志 —— 最可靠，且会跟着密码变

`src/initHandler/initMain.js:113-121`：

```js
await this.ensureInitialSuperAdmin();
setTimeout(async () => {
  try {
    const info = await this.getInitialSuperAdminInfo();
    if ((info && info.isInitialAdmin && info.username && info.password)) {
      Logger.info(`Default admin in use; change soon. \nusername:${info.username} \npassword:${info.password}`);
    }
    await this.writeLinuxHeadlessAdminAccountFileIfNeeded();
  } catch {}
}, 10000);
```

启动 10 秒后打印。只要 `is_initial_admin='1'`，**每次重启都会打印**，
而且打印的是**解密后的当前密码**——所以有人改过密码，这里也会跟着变成新值。

```bash
grep -h "^password:" /var/log/nascab.out.log | sort -u     # 历史上去重后的所有密码
```

### (b) 手工补一个凭据文件

`/app/nascab/data/nascabos_admin_account`（0600），格式就是官方那个
`username:<u> password:<p>`。这个文件是我手工补的，**它不会自动更新**——
上游那个写文件的函数仍然被 `isDocker` 守卫挡着。要当"当前值快照"看，不要当真相源。

### (c) 现场从数据库解密 —— 任何时候都有效

密码不是哈希，是**可逆加密**：

- 格式：`enc:v1:<base64(iv ‖ ciphertext)>`
- 算法：`aes-256-cbc`
- 密钥：`sha256(process.env.SERVER_ID)`，其中 `SERVER_ID` 来自 `config.serverId`
- IV：base64 解码后的前 16 字节

对应 `src/utils/jwtUtil.js#encryptPassword()`：

```js
encryptPassword(password) {
  const serverId = process.env.SERVER_ID;
  if (!serverId) throw new Error('SERVER_ID_MISSING');
  const key = crypto.createHash('sha256').update(serverId).digest();
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv('aes-256-cbc', key, iv);
  const encrypted = Buffer.concat([cipher.update(String(password), 'utf8'), cipher.final()]);
  return `enc:v1:${Buffer.concat([iv, encrypted]).toString('base64')}`;
}
```

所以**任何时刻都能解出当前明文**。已封装成脚本：

```bash
bash scripts/nascab/recover-admin-credentials.sh --verify
```

手工版（不依赖脚本）：

```bash
sid=$(python3 -c "import sqlite3;print(sqlite3.connect(
  '/app/nascab/data/database/nascab_main.db').execute(
  \"select value from config where key='serverId'\").fetchone()[0])")
# 取 user.password，去掉 enc:v1: 前缀 → base64 解码 → 前 16 字节是 IV，其余是密文
openssl enc -d -aes-256-cbc -K "$(printf %s "$sid" | sha256sum | cut -d' ' -f1)" \
                             -iv <iv_hex> -in ct.bin
```

> `printf %s` 不能换成 `echo`——`echo` 会补一个换行，sha256 就完全不同了。
> Node 侧 `update(serverId)` 用的是 utf8 字符串本身，没有尾随换行。

---

## 4. 走不通的路（省得再试）

| 路径 | 状态 |
|---|---|
| `POST /api/auth/createSuperAdmin` | 路由在 `authRouter.js` 里是**注释掉的**，不能靠 API 重建管理员 |
| `GET /api/auth/recoverInfo` + `POST /api/auth/recoverPassword` | 走密保问答，但 `question` 固定是 `'init'`、`answer` 是另一个独立随机串，等于没有可用的恢复通道 |
| 删 `user` 行重启 | 会生成一对新的随机凭据，同样不显示 |
| 改 `package.json` 的 `isDocker` | 影响另外 4 处无关逻辑，见 §2 |

可用的登录接口：

```
POST /api/auth/login          body {"username","password"}
GET  /api/auth/hasSuperAdmin  探测是否已有管理员
```

成功返回 `{"success":true,"message":"登录成功","data":{...,"accessToken","refreshToken",...}}`。

---

## 5. 排查时实际用到的证据

```bash
# user 表只有一行，且就是 super_admin
sqlite3 /app/nascab/data/database/nascab_main.db \
  "select id,username,type,is_active from user;"
#  1|<username>|super_admin|1

# config 表里的两个关键键
sqlite3 ... "select key,value from config where key in ('is_initial_admin','serverId');"
#  is_initial_admin|1
#  serverId|<uuid>

# 密码从未被改过：日志里历史上去重只有一个值
grep -h "^password:" /var/log/nascab.out.log | sort -u      # 唯一一个值

# 解密结果与日志完全一致
bash scripts/nascab/recover-admin-credentials.sh --verify
```

> `sqlite3` 这个 node 模块在 nascab 的 `node_modules` 里**没有安装**，所以别写 node 脚本去读库；
> 用 Python 的 `sqlite3` 标准库读、`openssl` 解密，分工最干净。

---

## 6. 结论与建议

- 安装没有问题，服务是好的。
- 首次设置向导在 2026-10-28 15:42 就完成了，凭据是随机生成的 6+6 位。
- 拿到凭据后**第一件事应该是改掉用户名和密码**——应用自己也在提示
  "Default admin in use; change soon"，而这个 NAS 是对外暴露的。
- 想把这件事彻底修掉（让凭据每次都落盘），正确的做法是给上游提 issue/PR 改那个
  `isDocker` 守卫，而不是在本机改 `package.json`。
