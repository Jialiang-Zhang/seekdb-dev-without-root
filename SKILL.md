---
name: seekdb-dev-without-root
description: 在 Ubuntu / WSL 上不使用 sudo、不部署 obd，从源码编译 OceanBase seekdb，启动本地实例，运行 CTest 单元测试和 mysqltest 用例。用户要编译 seekdb、验证内核改动、跑 tools/deploy/mysql_test 用例或排查用例环境问题时使用。
---

# seekdb 无 root 编译与测试

## 功能

- 把 seekdb 源码仓库编译成可运行的 `seekdb` 二进制，宿主机没有 sudo 也能完成依赖准备。
- 启动一个独立的本地测试实例。
- 运行仓库内的 CTest 单元测试。
- 不安装 obd，直接用依赖包里的 `mysqltest` 跑 `tools/deploy/mysql_test/test_suite` 下的用例，并比对 `.result`。

## 输入

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `SEEKDB_SRC` | seekdb 源码目录（Linux 文件系统中的 LF 克隆） | `~/seekdb` |
| `SEEKDB_RUN` | 测试实例目录，会被清空重建 | `~/seekdb-run` |
| `SEEKDB_PORT` | 测试实例 SQL 端口 | `2881` |
| 并行度 | 编译 `-j`，按内存估算 | 见第 3 步 |

## 输出

- `$SEEKDB_SRC/build_release/src/observer/seekdb`
- 运行中的实例：`127.0.0.1:$SEEKDB_PORT`，用户 `root`（无密码）
- 每个用例的 PASS / FAIL 及失败时的 diff 文件

## 步骤

### 1. 准备源码

在 Linux 文件系统里克隆，不要直接用 Windows 盘上的工作区：Windows 克隆通常开启 `core.autocrlf`，CRLF 会让构建脚本和 `.result` 比对失败。

```bash
git -c core.autocrlf=false clone https://github.com/oceanbase/seekdb.git ~/seekdb
```

Windows 上未提交的修改可以 `git diff HEAD --binary > p.patch`，再在 WSL 里 `git apply p.patch`。

### 2. 无 sudo 补齐 rpm 解包工具

`deps/init/dep_create.sh` 用 `rpm2cpio | cpio -di` 解包依赖 RPM。宿主机缺这两个命令又没有 root 时，把 `scripts/` 下的纯 Python 实现放到 PATH 前面：

```bash
mkdir -p ~/bin
cp scripts/rpm2cpio.py ~/bin/rpm2cpio
cp scripts/cpio.py ~/bin/cpio
chmod +x ~/bin/rpm2cpio ~/bin/cpio
export PATH=~/bin:$PATH
```

- `rpm2cpio.py` 跳过 RPM lead 和两个 header，按魔数识别 gzip / xz / zstd / bzip2 负载并解压。
- `cpio.py` 只实现 `-i` 解包 newc 格式，处理目录、普通文件、软链接和硬链接组，拒绝 `..` 路径。

Rust 工具链用 rustup 装在用户目录即可：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none
source ~/.cargo/env
```

### 3. 初始化依赖并编译

```bash
cd $SEEKDB_SRC
bash build.sh init
bash build.sh release -DOB_USE_CCACHE=ON --make -j5
```

- 默认开启 unity build，一个编译任务约占 2–3 GB 内存。12 GB 内存配 `-j5` 比较稳；OOM 时先降 `-j`。
- `-DOB_USE_CCACHE=ON` 使用依赖包里的 ccache，来回切换版本对比性能时能省大量时间。
- 只改了少量文件时：`cmake --build build_release --parallel 5 --target seekdb`。

### 4. 启动测试实例

```bash
bash scripts/start_seekdb.sh
```

脚本会清空 `$SEEKDB_RUN`，用 `--nodaemon --base-dir` 启动，并轮询直到 SQL 可用。注意：

- Ubuntu 24.04 只有 `libaio.so.1t64`，脚本会在实例目录里建 `libaio.so.1` 软链接并设置 `LD_LIBRARY_PATH`。
- 启动时去掉 `http_proxy` 等变量并设置 `NO_PROXY=127.0.0.1,localhost`：AI 函数用例里的 Mock 服务在 127.0.0.1 上，走代理会失败；libcurl 不识别 `127.*` 这类通配写法。
- 在实例数据目录里启动：遥测文件写到当前目录的 `run/telemetry.json`。

### 5. 运行单元测试

```bash
cmake --build build_release --parallel 5 --target <测试目标>
ctest --test-dir build_release --output-on-failure -R '^(<测试名>)$'
```

`ctest --output-on-failure` 只在失败时打印 GTest 输出。想确认某个新用例确实执行了，直接运行测试二进制并用 `--gtest_filter`。

### 6. 不用 obd 运行 mysqltest

```bash
bash scripts/run_mysqltest.sh <suite> <case1> [case2 ...]
# 例：bash scripts/run_mysqltest.sh ai_function ai_model_endpoint_ddl
```

脚本按 obd 的约定准备环境：

- 工作目录是 `tools/deploy`，用例里的 `--exec python3 mysql_test/...` 相对路径才能找到。
- 导出 `OBMYSQL_MS0`、`OBMYSQL_PORT`、`OBMYSQL_USR`、`OBMYSQL_PWD`：用例里的 `connect (..., $OBMYSQL_MS0, ...)` 依赖它们。
- 先创建 `admin/admin` 用户并用它连接，与 obd 默认一致。
- 密码参数必须写成 `--password=admin`。写成 `--password admin` 时 mysqltest 会在后台等待终端输入，进程停在 `T` 状态。
- 标准输入重定向到 `/dev/null`。
- 部分用例通过 `ssh $host` / `scp` 把测试数据拷到实例所在机器（例如 `file_sql`）。本机运行时把 `scripts/testbin/` 加到 PATH 并设置 `OBSERVER_DIR=$SEEKDB_RUN/data`，`ssh`/`scp` 会退化成本地命令。

需要录制新用例的期望结果时，在 mysqltest 参数里加 `--record`，录完务必人工检查 `.result`。

### 7. 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| `bison version not match` | 构建脚本使用依赖包里的 bison 2.4.1，不要用系统 bison 生成解析器 |
| 语法改动后构建失败并提示 conflict | `gen_parser.sh` 对任何 conflict 直接失败；可先用系统 bison 对新旧 `.y` 各跑一次 `bison -v`，确认没有新增冲突 |
| 用例卡住不退出 | 检查是否把密码写成了 `--password admin` |
| AI 函数用例请求超时 | 实例继承了代理环境变量，按第 4 步重启实例 |
| 修改内表定义后不确定能否生成 | 在源码副本里运行 `src/share/inner_table/generate_inner_table_schema.py` |

## 示例

```bash
export SEEKDB_SRC=~/seekdb SEEKDB_RUN=~/seekdb-run
bash build.sh release -DOB_USE_CCACHE=ON --make -j5
bash scripts/start_seekdb.sh
bash scripts/run_mysqltest.sh ai_column ai_column_ddl ai_column_worker
# PASS ai_column/ai_column_ddl (1s)
# PASS ai_column/ai_column_worker (7s)
# suite=ai_column pass=2 fail=0
```
