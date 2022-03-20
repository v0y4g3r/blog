---
title: "Notes on InfluxDB Storage Engine"
date: 2022-03-12T17:42:25+08:00
draft: false
toc: true
math: true
images:
tags: 
  - Database
---

> InfluxDB 的存储引擎经过多次修改，本文描述的系统结构基于 InfluxDB 截止 2022-02-24 的 `adf29dfedfc785620db0e104652544ce9f67cb6e` 版本。当前版本已经支持 TSI 索引结构。

![image.png](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-overview.svg)

{{% img-title %}}  InfluxDB 的存储系统 {{% /img-title %}} 

InfluxDB 的存储层有三个子系统：

- TSM：数据点的存储，可以高效地提供 SeriesKey 到时序数据值的插入和检索；
- TSI：时序数据的倒排索引，提供查询某个 measurement 下某个 tag 包含特定值的 SeriesID 的接口；
  - TSI 是 InfluxDB 查询引擎的核心，所谓的基数膨胀带来的问题也是出现在这一层。
  - 为了降低 TSI 的内存占用，InfluxDB 引入了一个额外的 SeriesID。
- Series 索引：提供根据 SeriesID 查找 SeriesKey 的接口等
  - `SeriesFile.CreateSeriesListIfNotExists`：创建 `SeriesKey`->`SeriesID` 的映射
  - `SeriesFile.SeriesKey`：根据 SeriesID 查找 SeriesKey

应该说 TSI 加上 SeriesIndex 才是 InfluxDB 完整的索引部分，但是这两者各自是一个类 LSMT 的数据结构，也有自己的 WAL、compaction/recover 策略等等，因此 InfluxDB 做了区分。

在 InfluxDB 查询数据时，首先根据用户的查询条件从 TSI 查找到符合条件的 SeriesID，然后从 SeriesIndex 查询对应的 SeriesKey，最后从 TSM 根据 SeriesKey 读取并合并所有的数据点。

> 值得额外说明的是，InfluxDB 采用了 Roaring Bitmap 作为压缩的 map 用来存储 SeriesID 等数据；此外用 Robin Hood Hash 用作磁盘上的持久化的 hashtable 的 hash 算法，读取时的 locality 比较好。本文所述的 磁盘文件上的 hash index 都是采用的 RHH。


## TSM

TSM 是 InfluxDB 存储时间线数据点的引擎。可以理解为一个 ` map<SeriesKey, list<DataPoint>>` 的数据库。为了提高时间点的写入吞吐，TSM 采用了类似于 LSMT 的数据结构。

InfluxDB 将每个时间段划分为一个 shard，每个 shard 对应底层的一个数据库文件，包括其自己的 WAL 和 TSM 文件。InfluxDB 文档中很多地方把这个 DB 的概念称为 RP（Retention Policy），本质上是因为 RP 决定了 DB 下面的 shard 如何过期清理，一个 DB 只会有一个 RP，因此 RP 实例就是 DB 实例。



![](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/tsm-overview.svg#crop=0&crop=0&crop=1&crop=1&height=588&id=p6Hzv&originHeight=2175&originWidth=1997&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=&width=540)
{{% img-title %}} TSM 文件总览 {{% /img-title %}} 


## TSI

TSI 提供的能力是 tag 到 series key 的索引，如开头所说，为了降低 TSI 的内存占用，InfluxDB 额外引入了 SeriesID 的概念，这样一来就将 TSI 分为 tag->id 和 id->key 两部分，本文分别称为 Index 和 Series。只有两部分加起来才是完整的 InfluxDB 的时序索引。

![influxdb-tsi-overview](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-tsi-overview.svg)
{{% img-title %}} TSI 索引存储全景 {{% /img-title %}} 

### Index 部分

TSI 主要维护的是一个持久化的 `map<TagName, map<TagValue, list<SeriesID>>>` 数据结构，类似于一个 LSMT 的 KV 系统。

TSI 提供的接口主要是：

- `Index.TagValueSeriesIDIterator`：根据 measurement、tag key、tag value 找到需要读取的 SeriesID
- `Index.CreateSeriesIfNotExists`：根据输入的 measurement、key 和 tag value 创建一个新的

和其他的 LSMT 一样，TSI 也有一个 WAL、Memtable、SST。

- WAL：`LogFile` 的磁盘部分（.tsl 文件）
- MemTable：`LogFile`的内存部分
- SST：`IndexFile`

TSI 本身也是 Shard 维度的，这样当旧的 shard 过期之后里面的 索引也会自动删除。

#### TSL 文件的格式

![image.png](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-tsl-layout.svg)
{{% img-title %}} TSL 文件的布局 {{% /img-title %}} 

TSL 文件是  LogFile 的磁盘表示，由一系列的 LogEntry 组成。当新的 SeriesKey 写入的时候，会在这个 TSL 文件的末尾 append 一个 log entry。每个 log entry 包括：

- flag：代表这个 entry 所执行的操作，可以是新增/删除 series、删除 measurement、删除 tag key、删除 tag value 之一
- series id：series key 的 ID
- name：series key 的 name
- key：series key 的 tag key
- value：series key 的 tag value
- checksum：校验和
- size：大小

当 InfluxDB 实例重启的时候，会通过重放这个 TSL 文件获得一份最新的 series key 数据。

#### TSI 文件的格式

![influxdb-tsi-layout](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-tsi-layout.svg)
{{% img-title %}} TSI 文件布局 {{% /img-title %}} 

TSI 文件分为三部分，分别是文件尾部的 tailer、measurement block 和 tag block 组成。

- 通过读取 trailer 的数据，可以找到 measurement 对应 的 measurement block 的 offset
- 通过 measurement block 中的 tag offset 可以找到 tag 对应的 tag block 。除此之外，measurement block 还记录了 measurement  的 cardinality 、SeriesID Set（bitmap）等信息。
- tag block 本质上是一个持久化的 hashmap

##### IndexFileTailer

![influxdb-tsi-index-trailer.svg](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-tsi-index-trailer.svg)

##### MeasurementBlocks

![influxdb-tsi-measurement-block.svg](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-tsi-measurement-block.svg)

MeasurementBlocks 有一系列的 MeasurementBlock、一个 HashIndex 和一个 MeasurementBlockTrailer 组成：

- MeasurementBlock 保存的是 measurement 的数据
- HashIndex 保存的是每一个 MeasurementBlock 在文件的偏移量
- MeasurementBlockTrailer 记录了在 MeasurementBlock 数据区的起始 offset 和 size、HashIndex 的起始 offset 和 size 以及 sketch、tsketch 的起始 offset 和 size 信息。 

##### TagBlocks

![influxdb-tsi-tag-block](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-tsi-tag-block.svg)

{{% img-title %}}Tag block 存储格式{{% /img-title %}} 

TagBlocks 保存的是某个 tag key 下面的所有 tag value 以及这个 tag value 对应的 series id 列表。TagBlock 通过一个多级的 map 去维护了这样的双重映射关系。

- 首先在 TagBlockTrailer 这个尾部的数据结构维护了 tag value section、tag key section、tag key array map 的地址；
- 通过 trailer 的 hash index offset 可以找到 tag key block 的 hash index （下图中的 1）；
- 遍历 hash index 可以找到所需要某个 tag key 的 tag key block entry （下图中的 2）；
- 通过 tag key block entry 的 tag hash index offset 可以找到 这个 key 对应的 tag value 的 hash index 部分的地址 （下图中的 3）；
- 遍历这个 tag value block 的 tag value hash index 可以找到符合条件的 tag value entry 的地址，从而读取到这个 tag value 的数据，包括 series id 等（下图中的 4）。

![influxdb-tsi-tag-lookup.png](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-tsi-tag-lookup.png)


#### 根据 Tag key 和 Tag value 查找

```latex
Index.TagValueSeriesIDIterator 						@tsdb/index/tsi1/index.go:999
\--- Partition.TagValueSeriesIDIterator 	@tsdb/index/tsi1/index.go:1010
    \--- IndexFile.TagValueSeriesIDSet 		@tsdb/index/tsi1/partition.go:805
        \--- TagBlock.DecodeTagValueElem	@tsdb/index/tsi1/index_file.go:335
              ^~ 这里的 tagblocks 在启动的时候就会从磁盘上的 IndexFile 读取到IndexFile.tblks 中来，
                  而 IndexFile 之外的变更保留在 LogFile 的内存索引中
```


#### Index Compaction

TSI 索引的 compaction 有两类：

- LogFile -> IndexFile: `LogFile.Compact`，即 level 0 到 level 1 的 compaction，把 TSL 文件压缩成 TSI 文件
- IndexFile leveled compaction: `IndexFiles.Compact`，即 level n 到 level n+1 的 compaction

### Series 索引

![influxdb-series-index-overview.svg](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-series-index-overview.svg)
{{% img-title %}} Series 索引全景图 {{% /img-title %}} 

Series 索引主要负责 SeriesKey 到 SeriesID 和 SeriesID 到 SeriesOffset 的映射，可以理解为一个持久化的 `map<SeriesID, SeriesKey>`。Series 索引也是 database 维度的。Series 索引分为三个部分：

- "WAL"：SeriesSegment
- "MemTable"：SeriesIndex 的内存部分
- "SST"：SeriesIndex 持久化到磁盘的部分（在启动的时候会通过 mmap 载入）

理解 Series 索引的核心在于理解 SeriesIndex 和 SeriesSegment 的交互。

SeriesIndex 相当于是 Memtable，SeriesSegment 相当于是 WAL。SeriesSegment 里面保存的都是具体针对 series 的操作（operation），只要在 recover 的时候把 SeriesSegment 里面的数据重放一遍就可以了（见`SeriesIndex.Recover`）。**为了减小 SeriesIndex 的内存占用，InfluxDB 做了 KV 分离**，真实的 value（即Series Key） 都是保存在 “WAL”（SeriesSegment） 中的，“memtable”（即 SeriesIndex） 中的 value 只是指向  SeriesSegment 当中一个地址的 offset。

和其他 LSMT 类似，SeriesIndex 也需要做 compact，compact 的逻辑就是 遍历 SeriesPartition 下面的所有的 segment 里面的所有 entry，把存活的 series 写到 series index 文件中。具体的 compact 逻辑是在`SeriesPartitionCompactor.compactIndexTo`中，为了实现 series 的删除，也在 compact 的时候判断是 series 是否已经被标记为 deleted。

> 为什么需要 SeriesID？如果直接在内存里面维护 SeriesKey 到 Series 的映射，则内存里面会多很多的 tag key 和 tag value 拼接而成的数据，而且这个数据会有大量的冗余。SeriesID 相当于合并了这部分冗余的数据。


#### SeriesIndex

![influxdb-series-index-file-layout.svg](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-series-index-file-layout.svg)
{{% img-title %}}SeriesIndex 的数据组成{{% /img-title %}} 

SeriesIndex 分为两部分，一部分是保存在内存上的：`SeriesIndex.keyIDMap`/`SeriesIndex.idOffsetMap`/`SeriesIndex.tombstones`，另一部分是保存在磁盘上的：`SeriesIndex.keyIDData` /`SeriesIndex.idOffsetData`。

SeriesIndex 磁盘文件里面的 series 数据可以理解为基线数据。在启动的时候，InfluxDB 会把磁盘上面的 Series Index 文件里面的内容加在到 `SeriesIndex.keyIdData`和 `SeriesIndex.idOffsetData`中（通过 mmap 的方式），这块文件里面的内容实际上就是一个持久化的 HashMap。InfluxDB 会定期地把 内存的数据（`SeriesIndex.keyIDMap`和 `SeriesIndex.idOffsetMap`等）和磁盘的基线数据合并形成一个新的基线数据。

#### SeriesSegment

![influxdb-series-segment-file-layout.svg](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-series-segment-file-layout.svg)
{{% img-title %}} SeriesSegment 的二进制格式 {{% /img-title %}} 

SeriesSegment 就是一组磁盘上的文件，由一个 header 和椅子列的 SeriesEntry 组成，每个 Entry 可能是一个 insert entry（代表 SeriesKey 的插入）或者 tombstone entry （代表 series key 的删除）。在启动的时候会通过 mmap 的方式把 segments 加载进来，每次创建新的 Series Key 的时候也会向这个 mmap 的文件的末尾去 append 一个新的 series entry。

如上介绍，SeriesIndex 内部维护的并不是 SeriesID 到 SeriesKey 的映射，真正的 SeriesKey 是保存在 WAL 即 SeriesSegment 上面的，因此 SeriesIndex 额外引入了一个 offset 去表明 SeriesKey 在 SeriesSegment 上的 地址。


#### SeriesOffset

![influxdb-series-offset.svg](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/influxdb-series-offset.svg)
{{% img-title %}} SeriesOffset 格式{{% /img-title %}} 
SeriesOffset 指向的是一个 series entry 在 series segments 中的地址，是一个 64 位值，由两部分组成，高 32 位（实际上只会有 16 位使用，足够寻址 2^16 个 segment)是 segment id ，低 32 位是 series entry 在此 id 的 series segment 中的偏移量。因此通过 SeriesOffset 可以唯一地找到 segment 以及其中 entry 的位置。

> Series Offset 的拼接和拆分见`JoinSeriesOffset`和 `SplitSeriesOffset`两个函数


#### 查找路径

- 根据 SeriesKey 查找 SeriesID：首先在内存的`SeriesIndex.keyIDMap`查找，如果没有则**遍历** SeriesSegment 下面的所有 SeriesEntry，找到 Key 匹配的 ID 返回
- 根据 SeriesID 查找 SeriesKey：`SeriesPartition.SeriesKey`。首先根据 series id 找到 series offset，然后根据 series offset 找到 series key。
  - 根据 id 找到 offset 首先也是从 内存的 `SeriesIndex.idOffsetMap`读取，如果没有就去 SeriesIndex 的磁盘部分读取（遍历 `SeriesIndex.idOffsetData`查找）
  - 根据 offset 找到 key：把 offset 分割为 SegmentID 和 pos 两部分，从 Segment ID 可以找到 磁盘上的 SeriesSegment 文件，接着这个 SeriesSegment 的 pos 位置的数据（Uvarint+string）就是对应的 series key。


### High Cardinality 问题是如何出现的

InfluxDB 最为人诟病的问题就是所谓的 high cardinality 问题，即当 InfluxDB 实例写入大量的不同 tag value 的时候，时间线数量会大幅膨胀。

考虑某个 measurement 有三个 tag: HostName, AZ, Region，分别代表一个服务器的机器名、可用区和 region。其中 HostName 可能出现 100 个值，AZ 可能 出现 20 个值，Region 可能出现 10 个值，那么这个 measurement 可能出现的总时间线数量（即所谓的 cardinality）为 $100 \times 20 \times 10=20000$，即所有 tag 值空间大小的笛卡尔积。

当时序数据的 cardinality 增长的时候，InfluxDB 内部的倒排索引会大幅膨胀。InfluxDB 历史上为了解决倒排索引膨胀的问题采取了多种策略，比如通过 SeriesID 降低倒排索引的大小，将[纯内存存储的倒排索引优化为内存+磁盘的索引](https://github.com/influxdata/influxdb/issues/7151)（即本文的 TSI 引擎）等等。但是这些手段都是延缓倒排出现性能瓶颈的时间。除此之外，Series Index 部分（即 SeriesID 到 SeriesKey 的正排索引）在大量时间线的情况下也会出现性能瓶颈。比如 Series 索引在做 compaction 的时候（`SeriesPartitionCompactor.Compact`）一方面会遍历 SeriesSegment 文件中的所有 entry 去 apply 到内存的 hashmap，再把内存中的数据写入到磁盘上的 SeriesIndex 文件中。假设 Series 数量很大，那么这个 compact 过程很有可能出现 OOM。

目前可以想到的一个简单的缓解办法是现在 RP 维度的 Series 索引变成 RP 下面的 Shard 维度的，当 Shard 过期之后会自动把相应的 Series 索引过期。

