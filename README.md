# Trino Connect Doris Demo

因为业务需要，Trino 要查询 Doris 的数据，因为 Doris 兼容 Mysql 协议，
所以我们可以复用 Trino-Mysql Connector，只是有些配置要修改一下才可行。


## Connector 配置

一份可行的配置如下：
```properties
connector.name=mysql
connection-url=jdbc:mysql://doris-fe:9030
connection-user=root
connection-password=

insert.non-transactional-insert.enabled=true
metadata.cache-ttl=10m
metadata.cache-missing=true
statistics.enabled=false
```
完整配置项见 [Trino 文档](https://trino.io/docs/current/connector/mysql.html)


### 解读1
配置项 `insert.non-transactional-insert.enabled` 改为 true，是因为 Trino 默认会用事务的方式写入数据到 Mysql，其流程是这样的：
1. create temp table 
2. insert data to temp table
2. copy temp table data to destination table with transaction

问题就出在 create temp table 这里，因为 Doris 的建表语句和 Mysql 还是有差别的。
所以我们可以选择跳过事务写入的方式，直接 insert data to destination table 的方式来写入数据。


### 解读2
配置项 `metadata.cache-ttl` 和 `metadata.cache-missing` 的作用是对 table metadata 做缓存，因为 Trino 要知道 Mysql Table 的每个 column 的类型，才好做类型转换。
配置缓存，Trino 就不用每次都去查询 column 类型了。

如果 doirs 的 table column 有变动，你可以选择等待缓存时间过期，或者直接清空缓存，在 Trino 中执行以下指令：


```sql
USE dorisdb.example_schema;
CALL system.flush_metadata_cache();
```



### 解读3
配置项 `statistics.enabled` 该配置项并没有出现在文档中，需要阅读 Trino 源码才能知道。

其背景是这样的，Trino 要通过查询 Mysql 的 INFORMATION_SCHEMA.STATISTICS 表获取 table 的静态信息，
例如 column 的最大最小值，条数等，这些信息用用于 Trino 的 cost based optimizations(基于代价的优化)。
而 Doris 中并没有这张 STATISTICS 表，所以每次查询都会报错，虽然不影响取数，但总是个问题。

所以在这个例子中，我们可以选择把这个配置项关闭，这样就不会查询 STATISTICS 信息了。




## 部署测试
使用 Docker Compose 启动 Trino 和 Doris

```shell
docker-compose up -d
```

Doris 的镜像启动方式[参考文档](https://doris.apache.org/zh-CN/docs/dev/install/construct-docker/run-docker-cluster#%E7%89%B9%E4%BE%8B%E8%AF%B4%E6%98%8E)，
注意 MacOS 用户要做个特殊设置，仔细看文档
> 特例说明
MacOS 由于内部实现容器的方式不同，在部署时宿主机直接修改 max_map_count 值可能无法成功，需要先创建以下容器：

`docker run -it --privileged --pid=host --name=change_count debian nsenter -t 1 -m -u -n -i sh`

> 容器创建成功执行以下命令：

`sysctl -w vm.max_map_count=2000000`

> 然后 exit 退出，创建 Doris Docker 集群。

## 测试 Doris
等服务都启动后，使用 DB工具连接 Doris，分别执行以下 SQL 命令测试 Doris

```sql
CREATE DATABASE IF NOT EXISTS dp;

CREATE TABLE dp.customer
(
 custKey INT,
 phone VARCHAR(100),
 name VARCHAR(100),
 nationkey INT NOT NULL DEFAULT "1" COMMENT "int column"
)
DISTRIBUTED BY HASH(custKey) BUCKETS 32
PROPERTIES (
    "replication_num" = "1"
);

SELECT * FROM dp.customer;
```

这样就完成了建表操作

## 测试 Trino + Doris
我们在 Trino 上配置 tpch 数据，方便我们做测试。

测试写入数据到 Doris
```sql
insert into "mysql-doris".dp.customer select custKey, phone, name,nationkey from tpch.sf1.customer limit 1000
```

测试查询数据到 Doris
```sql
select * from  "mysql-doris".dp.customer where custkey > 100000;
```

```sql
select count(*) from  "mysql-doris".dp.customer ;
```

## TODO

- 测试大量数据读取的情况
- 测试大量数据写入的情况

## 如何修改 Trino Mysql Connector
如果某些特性你无法通过配置绕过，可以考虑自己编译 Connector。

具体步骤：
1. Fork Trino 代码
2. 修改 Mysql Connector 逻辑
3. 编译，注意Trino 需要 Java 17.0.04 版本以上才能编译，可以使用 Docker 来编译

启动 Java JDK 容器
```shell

docker run -it --rm \
-v {trino_code_path}:/opt/trino \
-v ~/.m2:/root/.m2 \
--name build_java openjdk:20-rc-jdk-buster bash
```

执行编译
```shell
cd /opt/trino/plugin/trino-mysql
../../mvnw clean install -DskipTests
```

编译完成后，只需要将 trino-mysql/target/ 目录下的 trino-mysql-405.jar 提取出来，覆盖 Trino 的 Plugin 即可

