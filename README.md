# Trino Connect Doris Demo

在 QPS 上，Doris 的表现优于 Trino。我们需要同时使用这两个 OLAP。为了不改动上层架构，需要通过 Trino 查询 Doris。

有些项目选择从 Trino 迁移到 Doris，打通 Trino 查询 Doris 可以做到渐进式迁移。

为了满足这些需求，我们尝试做 Trino 到 Doris 的适配。

由于 Doris 兼容 MySQL 协议，因此我们可以复用 Trino-MySQL Connector。只需要进行一些配置和小修改即可。


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

mysql.force-aggregation-pushdown=true
mysql.force-topn-pushdown=true
mysql.datetime-column-size=23
```
具体配置项见 [Trino 文档](https://trino.io/docs/current/connector/mysql.html)


### 解读1
配置项 `insert.non-transactional-insert.enabled=true` 是因为 Trino 默认会用事务的方式写入数据到 Mysql，其流程是这样的：
1. create temp table 
2. insert data to temp table
2. copy temp table data to destination table with transaction

然而，问题在于 create temp table 步骤，因为 Doris 的建表语句与 Mysql 有所不同。因此，我们可以选择跳过事务写入，直接将数据插入到目标表中来写入数据。

### 解读2
配置项 `metadata.cache-ttl` 和 `metadata.cache-missing` 的作用是对 table metadata 做缓存，因为 Trino 要知道 Mysql Table 的每个 column 的类型，才好做类型转换。
配置缓存，Trino 就不用每次都去查询 column 类型了。

如果 doirs 的 table column 有变动，你可以选择等待缓存时间过期，或者直接清空缓存，在 Trino 中执行以下指令：


```sql
USE dorisdb.example_schema;
CALL system.flush_metadata_cache();
```



### 解读3
配置项 `statistics.enabled=false` 该配置项并没有出现在文档中，需要阅读 Trino 源码才能知道。

其背景是这样的，Trino 要通过查询 Mysql 的 INFORMATION_SCHEMA.STATISTICS 表获取 table 的静态信息，
例如 column 的最大最小值，条数等，这些信息用用于 Trino 的 cost based optimizations(基于代价的优化)。
而 Doris 中并没有这张 STATISTICS 表，所以每次查询都会报错，虽然不影响取数，但总是个问题。

所以在这个例子中，我们可以选择把这个配置项关闭，这样就不会查询 STATISTICS 信息。


## 定制化
除了通过修改配置让 Connector 能正常工作，我们还需要对 Connector 的做些修改, 才能全面支持 Doris

本次修改提交到了 [footprintanalytics/trino](https://github.com/footprintanalytics/trino) 

本仓库 plugin 目录已经包括了修改后的 jar
- `trino-mysql-400.jar`
- `trino-mysql-408.jar`

你也可以选择自行编译

### 识别 Doris 的 Datetime 类型
新增了个配置项 `mysql.datetime-column-size=23` 。

其背景是这样的，Trino 要通过查询 Mysql 的 INFORMATION_SCHEMA.COLUMNS 表获取 column 的类型，

计算 DATETIME 的 COLUMN_SIZE 是这样的逻辑

```sql
WHEN UPPER(DATA_TYPE) = 'DATETIME' 
    OR UPPER(DATA_TYPE) = 'TIMESTAMP' THEN 19 + (CASE
                                     WHEN DATETIME_PRECISION > 0
                                         THEN DATETIME_PRECISION + 1
                                     ELSE DATETIME_PRECISION END)
    AS COLUMN_SIZE,
```

因 Doris 返回的 DATETIME_PRECISION 是 null，导致 DATETIME 计算为 null。

我们做了修改，DATETIME COLUMN_SIZE 为 null 的情况下，改为读取 `mysql.datetime-column-size=23`

### 兼容 Top-N pushdown 和 Aggregation pushdown
默认情况下，如果对 String 类型的字段排序，是不会 pushdown 的。

Top-N 的实现
```java
@Override
public boolean supportsTopN(ConnectorSession session, JdbcTableHandle handle, List<JdbcSortItem> sortOrder)
{
    for (JdbcSortItem sortItem : sortOrder) {
        Type sortItemType = sortItem.getColumn().getColumnType();
        if (sortItemType instanceof CharType || sortItemType instanceof VarcharType) {
            // Remote database can be case insensitive.
            return false;
        }
    }
    return true;
}
```
Aggregation 的实现
```java
@Override
public boolean supportsAggregationPushdown(ConnectorSession session, JdbcTableHandle table, List<AggregateFunction> aggregates, Map<String, ColumnHandle> assignments, List<List<ColumnHandle>> groupingSets)
{
    // Remote database can be case insensitive.
    return preventTextualTypeAggregationPushdown(groupingSets);
}
```

都是因为 case insensitive，可能导致 pushdown 失效

我们添加了两个配置项，来强制 pushdown。
- `mysql.force-aggregation-pushdown=true`
- `mysql.force-topn-pushdown=true`

添加配置后，可以使用 `EXPLAIN` 测试效果
```sql
EXPLAIN
SELECT regionkey, count(*)
FROM nation
GROUP BY regionkey;
```
Aggregation pushdown 生效的情况下，EXPLAIN 结果里是看不到 Aggregate 算子的


**注意**，因为某些原因，Aggregation pushdown 不会在所有情况下生效，具体限制见[文档](https://trino.io/docs/current/optimizer/pushdown.html#limitations)

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

## 性能测试
分别测试以下三种组合：
* trino-iceberg
* trino-doris
* doris only 

数据集条数：19583572

数据集大小：
- store in iceberg ： 2.4 GB
- store in doris ： 955 MB (有压缩)

机器配置

|  集群   | version  | 配置  |
|  ----  | ----  |----  |
| trino  | 408 | 8c32g*3 |
| doris  | 1.2.2 | 16c64g*1 |

测试结果, 单位是 s：

| sql           | trino-iceberg | trino-doris | trino-doris-pushdown | doris |
|---------------|---------------|-------------|----------------------|-------|
| filter        | 5.33          | 3.07        | 2.714                | 1.82  |
| sum aggregate | 4.81          | 22.71       | 6.192                | 2.71  |
| inner join    | 2.03          | 5.27        | 6.124                | 1.15  |
| distinct      | 3.92          | 14.30       | 3.984                | 1.95  |


结论：
- 直接在 Doris 集群上查询是最快的。Doris 的原生存储格式在处理数据量较小的 table 时速度非常优秀。
- 在简单的 filter 场景下，trino-doris 组合比 trino-iceberg 更快。
- 在复杂计算场景下，trino-doris 组合的速度仍然比不过 trino-iceberg。经过 Explain ANALYZE 分析，原因是 Doris 的数据压缩率不够，aggregate 场景需要传输更多数据到 Trino，这消耗了时间。
- 优化后的 Connector trino-doris-pushdown 可以让更多的计算下推。虽然它不能支持所有场景，但综合查询效果已经相当不错了。应尽量避免全量数据的计算。

测试 SQL 明细：

filter 
```sql
select *
from trades
where collection_contract_address = '0xba6666b118f8303f990f3519df07e160227cce87'
order by block_timestamp desc
```
aggregate:

```sql
select sum(amount_raw), buyer_address
from trades
group by buyer_address
order by 1 desc
```

inner join:
```sql
select *
from trades as a
inner join price_5min as b
on a.amount_currency_contract_address = b.token_address
and a.chain = b."chain"
where a.collection_contract_address = '0xba6666b118f8303f990f3519df07e160227cce87'
and a.buyer_address = '0x02639771b23931e8428fc30323d5a5ab8be22b06'
```

distinct:
```sql
select distinct buyer_address from doris.prod_silver.nft_trades
```

## TODO
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

参考本仓库中的  Dockerfile

```shell
COPY plugin/trino-mysql-405.jar /usr/lib/trino/plugin/mysql/trino-mysql-405.jar
```




